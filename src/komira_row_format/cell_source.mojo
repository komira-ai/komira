# =============================================================================
# komira_row_format.cell_source — orientation-parametric per-cell read abstraction.
#
# WHAT THIS IS
# ------------
# `ExpressionExecutor` (expression_executor.mojo) carries TWO walker shapes:
#
#   1. The COLUMN-VECTORIZED hot path (`*_from_view`): resolves whole typed
#      columns from a `BatchView` and runs the hand-staged SIMD `sel_kernels`
#      (`binary_select_col_lit[T, op]` / `binary_select_col_col`) over a
#      `RowSelectionVector`. This is the production columnar filter path and
#      is PERF-CRITICAL (NEON/AVX compare). The per-cell walker does NOT
#      touch it.
#
#   2. The PER-CELL SCALAR walker (`*_from_source[CS: CellSource]`):
#      a scalar `col <op> lit` / `col <op> col` / AND / OR recursion that reads
#      ONE cell at a time via the `CellSource` trait. The cell read is the ONLY
#      orientation-specific operation; the per-EXPR_* tag arms are shared.
#
# WHY A SEPARATE SCALAR WALKER (vs. forcing the column path through CellSource)
# ----------------------------------------------------------------------------
# The production walker does NOT read cells one at a time
# (`view.col_typed[DT](c)[r]`): the hot path is
# whole-column SIMD. A RowBlock is row-major, so a single column's cells are
# STRIDED across rows — it cannot present a contiguous `PrimitiveArray[T]` to
# the SIMD kernels. The orientations therefore diverge at the LOOP SHAPE
# (whole-column-SIMD vs per-cell-gather), not merely at the cell read. Routing
# the column path through a per-cell `read_f64(r, c)` would defeat the SIMD
# vectorization and regress the columnar path.
#
# Shape B is therefore realized as: the
# orientation-AGNOSTIC scalar walker is `_*_from_source[CS: CellSource]`; the
# `CS` conformer is bound at the dispatch seam. `ColumnCellSource` makes the
# scalar walker AVAILABLE to the column orientation (proving the abstraction is
# orientation-uniform), and `RowCellSource` is what the row path binds. The
# column hot path keeps its dedicated SIMD walker; the per-cell walker is the
# shared body the two orientations agree on.
#
# ENCAPSULATION
# -----------------------------------
# - NO UnsafePointer in any public signature. Cell reads land via
#   `BatchView`'s typed column accessors (ColumnCellSource) and
#   `RowBlock.read_fixed[DT]` (RowCellSource) — both internal-pointer-safe.
# - NO wildcard origins. ColumnCellSource carries `bo: Origin[mut=False]`;
#   RowCellSource carries `mo: Origin[mut=False]` over the borrowed RowBlock +
#   layout side-tables.
# - DType fast subset: I64 / F64 / I32 / F32 — the row path's fixed-cell subset.
#   String / Decimal / NULL-mask reads are NOT in the per-cell walker (the
#   column hot path retains them; the row path does not serve them
#   per cell either).
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_row_format.row_block import RowBlock


# DType tags for the per-cell fast subset. These mirror the row-streaming
# path's fixed-cell tags (DT_I64 / DT_F64 / DT_I32 / DT_F32)
# but live here so `cell_source` does not depend on the engine package.
comptime CELL_DT_I64: UInt8 = 0
comptime CELL_DT_F64: UInt8 = 1
comptime CELL_DT_I32: UInt8 = 2
comptime CELL_DT_F32: UInt8 = 3
# STRING cell tag for the per-cell walker's
# string-comparison arm. A STRING column reads via `CS.read_string(row,
# col_idx)`; the conformer resolves the logical col_idx to a heap String value
# (RowCellSource decodes the RowBlock var-string cell; ColumnCellSource reads
# `StringArray.get(row)`). This widens the per-cell walker beyond the numeric
# fast subset to cover the string-filter comparisons (==, !=, <, >, <=, >=).
comptime CELL_DT_STRING: UInt8 = 4
# BOOL cell tag for the per-cell
# walker. A BOOL column reads as a 1-byte cell (NOT bit-packed in the RowBlock
# fixed region) and widens to logical INT64 (0/1) for the numeric comparison
# arm — a `where(flag == 1)` / `where(flag)` predicate runs ROW-native. Date32
# / Date64 / Timestamp need NO new CELL_DT tag: they reuse CELL_DT_I32 (Date32
# i32 backing) / CELL_DT_I64 (Date64 + Timestamp i64 backing) — `read_i64`
# already widens i32 to i64, and a temporal literal comparand is encoded in the
# same backing-int domain, so the comparison is correct as backing-int order.
comptime CELL_DT_BOOL: UInt8 = 5
# Narrow + unsigned integer cell
# tags for the per-cell walker. SIGNED narrow (I8/I16) widen to logical INT64
# via `read_i64` (sign-extend). UNSIGNED (U8/U16/U32) widen to logical INT64 as
# well — their max value fits in Int64 positively, so a signed Int64 compare is
# CORRECT for these (4294967295 reads as +4294967295, not -1). U64 is the ONLY
# unsigned width that cannot widen to a signed Int64 (values > Int64.MAX wrap
# negative); it carries its own CELL_DT_U64 tag and a dedicated `read_u64`
# accessor + an unsigned comparison arm in the per-cell walker.
comptime CELL_DT_I16: UInt8 = 6
comptime CELL_DT_I8: UInt8 = 7
comptime CELL_DT_U8: UInt8 = 8
comptime CELL_DT_U16: UInt8 = 9
comptime CELL_DT_U32: UInt8 = 10
comptime CELL_DT_U64: UInt8 = 11
# DECIMAL128 cell tag. A DECIMAL128 column
# is a 16-byte fixed cell holding the raw SIGNED Int128 unscaled value. The
# per-cell walker reads it via `CS.read_i128` (full width) for the decimal
# comparison arm — `read_i64` would misread the 16-byte cell as its
# low-8-bytes i64 (silently wrong). The compare
# is scale-uniform (the gate enforces operand+literal same scale, matching the
# SORT/DISTINCT path's raw-int128 assumption), so the raw signed-int128 ordering
# IS the decimal ordering.
comptime CELL_DT_DECIMAL128: UInt8 = 12


# -----------------------------------------------------------------------------
# CellSource — the per-cell read trait.
# -----------------------------------------------------------------------------
#
# The walker resolves an EXPR_COL node's `col_idx` (the same logical column
# index the executor's `column_names` side-table is indexed by) to a typed
# scalar cell. The conformer owns the col_idx -> physical-location mapping:
#   - ColumnCellSource maps col_idx -> column NAME -> runtime batch position.
#   - RowCellSource maps col_idx -> (byte-offset, dtype-tag) within the row.
#
# All reads take a logical `col_idx` and a `row` (0-based within the source);
# the conformer is responsible for any name/offset resolution. Reads are
# `read self` — the walker never mutates the source.
# -----------------------------------------------------------------------------


trait CellSource:
    """Orientation-parametric per-cell read abstraction (Shape B).

    Conformers: `ColumnCellSource` (reads a `BatchView`), `RowCellSource`
    (reads a `RowBlock` + runtime layout). The per-EXPR_* walker arms in
    `ExpressionExecutor._*_from_source` call these and nothing else for cell
    access, so the per-tag logic is orientation-uniform.

    `col_idx` is the LOGICAL column index carried on EXPR_COL nodes (indexed
    into `ExpressionExecutor.column_names`); the conformer resolves it to a
    physical cell. `row` is the 0-based row index within the source.
    """

    def num_rows(self) -> Int:
        """Total rows available in this source."""
        ...

    def read_i64(self, row: Int, col_idx: Int) raises -> Int64:
        """Read a logical-INT64 cell. Conformers widen narrower int storage
        (signed sign-extend; U8/U16/U32 zero-extend into the positive Int64
        range — their max fits, so a downstream signed Int64 compare is
        correct). U64 must NOT be read through this path (values > Int64.MAX
        wrap negative) — use `read_u64` + the walker's unsigned arm."""
        ...

    def read_u64(self, row: Int, col_idx: Int) raises -> UInt64:
        """Read a logical-UINT64 cell. Used by the per-cell
        walker's UNSIGNED comparison arm for a U64 column, where a signed
        Int64 compare would be incorrect for values above Int64.MAX. Narrower
        unsigned storage (U8/U16/U32) zero-extends; signed storage is read as
        its unsigned bit pattern (only reached for genuinely-unsigned cols)."""
        ...

    def read_i128(self, row: Int, col_idx: Int) raises -> SIMD[DType.int128, 1]:
        """Read a DECIMAL128 cell's raw SIGNED Int128 unscaled value. The DECIMAL128 cell is a 16-byte fixed cell; reading it as
        an i64 (low 8 bytes) would be silently wrong. `RowCellSource` reads
        the full 16-byte cell via `RowBlock.read_fixed[int128]`; `ColumnCellSource`
        gathers from the Decimal128Array. Used by the per-cell walker's
        EXPR_*_DECIMAL128 comparison arm. The unscaled int128 is paired with the
        column's scale (`decimal_scale_of`) so the walker runs a scale-aware
        compare (matching the column oracle `_compare_decimal128`)."""
        ...

    def decimal_scale_of(self, col_idx: Int) raises -> Int:
        """The DECIMAL scale of the logical column `col_idx`. Paired with `read_i128` so the
        per-cell walker can rescale a mixed-scale comparison (col `d` @ scale 2
        vs literal/col @ a different scale) to the higher scale before the int128
        compare — matching the column oracle `_compare_decimal128`. Same-scale
        comparisons read equal scales here and hit the fast path.
        `RowCellSource` reads its `col_scales` side-table; `ColumnCellSource`
        reads the column's Arrow decimal scale. Used by the walker's
        EXPR_*_DECIMAL128 comparison arm (`_eval_decimal_scale_from_source`)."""
        ...

    def read_f64(self, row: Int, col_idx: Int) raises -> Float64:
        """Read a logical-FLOAT64 cell. Conformers widen int storage to f64."""
        ...

    def read_i32(self, row: Int, col_idx: Int) raises -> Int32:
        """Read an INT32 cell."""
        ...

    def read_f32(self, row: Int, col_idx: Int) raises -> Float32:
        """Read a FLOAT32 cell."""
        ...

    def read_string(self, row: Int, col_idx: Int) raises -> String:
        """Read a STRING cell as a heap `String`.

        Conformers resolve the logical col_idx to the underlying string
        storage: `RowCellSource` decodes the RowBlock var-string descriptor
        cell, `ColumnCellSource` reads `StringArray.get(row)`. Used by the
        per-cell walker's string-comparison arm."""
        ...

    def is_null(self, row: Int, col_idx: Int) raises -> Bool:
        """True iff the logical-column cell at (`row`, `col_idx`) is NULL
        (IS NULL / IS NOT NULL).

        `RowCellSource` reads the FORM-ii row validity bitmap (one bit per
        logical column; bit=1 means NULL); a non-nullable layout (no validity
        region) reports every cell present. `ColumnCellSource` is the
        orientation-uniformity proof conformer (NOT a production column path —
        the column engine serves STRING IS NULL via the dedicated
        EXPR_IS_NULL_STRING SIMD arm), so it resolves nullity for STRING
        columns only and raises otherwise. Used by the per-cell walker's
        EXPR_IS_NULL_CELL / EXPR_IS_NOT_NULL_CELL arms."""
        ...

    def has_validity(self) -> Bool:
        """True iff this source carries a validity region (some cell MAY be
        NULL); False iff the layout is non-nullable (every cell present).

        `select_filter_from_source` gates its 3VL
        null-skip guard on this so the non-nullable hot path is byte-identical
        (no per-row `is_null` call when no operand column can be NULL).
        `RowCellSource` returns its `has_validity` field. `ColumnCellSource`
        returns False (proof conformer — its IS NULL serving is the 3VL-correct
        unary EXPR_IS_NULL_CELL arm, and it never binds a production comparison
        filter; the column engine's production filter is the SIMD `*_from_view`
        walker, not this per-cell walker)."""
        ...


# -----------------------------------------------------------------------------
# ColumnCellSource — BatchView conformer (Path 2 availability).
# -----------------------------------------------------------------------------


struct ColumnCellSource[bo: Origin[mut=False]](CellSource):
    """`CellSource` over a `BatchView[bo]`.

    Resolves `col_idx` -> column NAME (via the parallel `column_names`
    borrowed from the executor) -> runtime batch position, then reads one
    typed scalar. The name resolution mirrors the column hot path's
    `batch.column_by_name(name)` lookup so the same projection-reorder
    robustness holds.

    This conformer exists so the per-cell scalar walker is AVAILABLE to the
    column orientation (proving Shape B is orientation-uniform). Path 2's
    PRODUCTION filter path remains the dedicated SIMD `*_from_view` walker —
    this conformer is NOT on Path 2's perf-critical path.
    """

    var view: BatchView[Self.bo]
    # Borrowed parallel column-name table (col_idx -> name). Held by value as
    # a List[String] copy is avoided: the executor passes a ref-resolved name
    # per read instead. To keep the conformer self-contained we carry an owned
    # copy of the names (constructed once at the dispatch seam; cold).
    var column_names: List[String]

    def __init__(
        out self, view: BatchView[Self.bo], var column_names: List[String]
    ):
        self.view = view
        self.column_names = column_names^

    @always_inline
    def num_rows(self) -> Int:
        ref batch = self.view._batch[]
        return batch.num_rows()

    @always_inline
    def read_i64(self, row: Int, col_idx: Int) raises -> Int64:
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_primitive_int64(rt)
        return col.load[1](row)[0]

    @always_inline
    def read_u64(self, row: Int, col_idx: Int) raises -> UInt64:
        # ColumnCellSource is the orientation-uniformity proof, NOT a
        # perf/production path (Path 2 uses the SIMD `*_from_view` walker).
        # There is no uint64 RecordBatch accessor today, so read the i64 array
        # and reinterpret the bit pattern as unsigned (correct for the stored
        # value). Production U64 unsigned filter runs the ROW path
        # (RowCellSource.read_u64).
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_primitive_int64(rt)
        return col.load[1](row)[0].cast[DType.uint64]()

    @always_inline
    def read_i128(self, row: Int, col_idx: Int) raises -> SIMD[DType.int128, 1]:
        # Gather the DECIMAL128 cell's raw i128 unscaled value
        # via the Decimal128Array accessor. ColumnCellSource is the
        # orientation-uniformity proof conformer (production decimal filters run
        # the column SIMD `_eval_bool_from_view` arm); this resolves the i128 for
        # the shared per-cell walker body.
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_decimal128(rt)
        return col.get_i128(row)

    @always_inline
    def decimal_scale_of(self, col_idx: Int) raises -> Int:
        # Mixed-scale: the DECIMAL128 column's scale comes
        # from the Decimal128Array. ColumnCellSource is the orientation-
        # uniformity proof conformer (production decimal filters run the column
        # SIMD `_eval_bool_from_view` arm); this resolves the scale for the
        # shared per-cell walker body.
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_decimal128(rt)
        return col.scale

    @always_inline
    def read_f64(self, row: Int, col_idx: Int) raises -> Float64:
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_primitive_float64(rt)
        return col.load[1](row)[0]

    @always_inline
    def read_i32(self, row: Int, col_idx: Int) raises -> Int32:
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_primitive_int32(rt)
        return col.load[1](row)[0]

    @always_inline
    def read_f32(self, row: Int, col_idx: Int) raises -> Float32:
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_primitive_float32(rt)
        return col.load[1](row)[0]

    def read_string(self, row: Int, col_idx: Int) raises -> String:
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var col = batch.column_as_string(rt)
        return col.get(row)

    def is_null(self, row: Int, col_idx: Int) raises -> Bool:
        # Orientation-uniformity proof conformer only. The production column
        # filter path serves STRING IS NULL via the dedicated SIMD
        # EXPR_IS_NULL_STRING arm in `_eval_bool_from_view`; numeric IS NULL is
        # not yet served column-side (raises in lower_untyped_expr). To keep
        # this proof conformer correct for the served case, resolve STRING
        # nullity via StringArray.is_null; other dtypes raise (never reached on
        # the column path — IS NULL routes to the row path in production).
        ref batch = self.view._batch[]
        var name = self.column_names[col_idx]
        var rt = batch.column_by_name(name)
        var at = batch.column_arrow_type(rt)
        if at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
            return batch.column_as_string(rt).is_null(row)
        raise Error(
            "ColumnCellSource.is_null: only STRING is supported on this"
            " orientation-proof conformer (col_idx="
            + String(col_idx)
            + "); production IS NULL routes to the row path (RowCellSource)"
        )

    @always_inline
    def has_validity(self) -> Bool:
        # The proof conformer reports no validity
        # region, so `select_filter_from_source` skips the 3VL null-skip guard
        # for a ColumnCellSource (it never binds a production comparison filter;
        # Path 2's production filter is the SIMD `*_from_view` walker). This
        # keeps the proof conformer's behavior unchanged — its `is_null` raises
        # for non-STRING, so the guard must NOT call it on numeric predicates.
        return False


# -----------------------------------------------------------------------------
# RowCellSource — RowBlock conformer (Path 4).
# -----------------------------------------------------------------------------


struct RowCellSource[mo: Origin[mut=False]](CellSource):
    """`CellSource` over a borrowed `RowBlock` + runtime layout side-tables.

    Resolves `col_idx` -> (byte-offset within the fixed-cell row, DType tag)
    via the parallel `col_offsets` / `col_dtypes` lists, then reads one typed
    cell via `RowBlock.read_fixed[DT]`. The (offset, dtype) tables are the
    same shape the row path's `RowStreamSpec` resolves at lowering time, so it
    can thread a RowStreamSpec's resolved offsets straight into this conformer.

    `mo` pins the borrowed RowBlock's lifetime to the caller's frame; the
    offset/dtype tables are owned by-value (cheap POD lists, constructed once
    at the dispatch seam).
    """

    var block: Pointer[RowBlock, Self.mo]
    var col_offsets: List[Int]
    var col_dtypes: List[UInt8]
    # Mixed-scale: per-logical-column
    # DECIMAL scale, parallel to `col_dtypes`. Threaded from the scan schema
    # through the running layout into the walker payload. A non-decimal column's
    # entry is unused (the decimal arm only reads it for DECIMAL128 operands).
    # When empty (a layout with no decimal columns) `decimal_scale_of` reports 0
    # — the same-scale fast path (same-scale and non-decimal predicates never reach it).
    var col_scales: List[Int]
    # F10 IS NULL / IS NOT NULL: the FORM-ii row validity bitmap
    # layout for the borrowed block. When `_has_validity` is False the block
    # carries no validity region and every cell is present; when True,
    # `validity_offset` is the byte offset of the per-row validity bitmap
    # within the fixed cells (== RowLayout.validity_offset of the block's
    # layout). `is_null` resolves a logical column's null bit from it.
    # (Field is `_has_validity`, not `has_validity`, to avoid colliding with the
    # `has_validity()` CellSource trait method.)
    var _has_validity: Bool
    var validity_offset: Int

    def __init__(
        out self,
        ref [Self.mo] block: RowBlock,
        var col_offsets: List[Int],
        var col_dtypes: List[UInt8],
        var col_scales: List[Int] = List[Int](),
        has_validity: Bool = False,
        validity_offset: Int = 0,
    ):
        self.block = Pointer(to=block)
        self.col_offsets = col_offsets^
        self.col_dtypes = col_dtypes^
        self.col_scales = col_scales^
        self._has_validity = has_validity
        self.validity_offset = validity_offset

    @always_inline
    def num_rows(self) -> Int:
        return self.block[].n_rows

    @always_inline
    def read_i64(self, row: Int, col_idx: Int) raises -> Int64:
        var off = self.col_offsets[col_idx]
        var dt = self.col_dtypes[col_idx]
        # Widen narrower int storage to logical INT64 (mirrors the column
        # walker's EXPR_COL i64 widening — a logical-i64 read may land on an
        # i32-stored column). Date32 arrives as CELL_DT_I32 (i32
        # backing); Date64 / Timestamp arrive as CELL_DT_I64 (i64 backing,
        # default arm). BOOL is a 1-byte cell widened to 0/1.
        if dt == CELL_DT_I32:
            return Int64(self.block[].read_fixed[DType.int32](row, off))
        if dt == CELL_DT_BOOL:
            return Int64(self.block[].read_fixed[DType.uint8](row, off))
        # Narrow SIGNED ints sign-extend; narrow UNSIGNED ints
        # (U8/U16/U32) zero-extend into the positive Int64 range (their max
        # fits, so a downstream signed Int64 compare is correct). U64 is NOT
        # served here (see read_u64).
        if dt == CELL_DT_I16:
            return Int64(self.block[].read_fixed[DType.int16](row, off))
        if dt == CELL_DT_I8:
            return Int64(self.block[].read_fixed[DType.int8](row, off))
        if dt == CELL_DT_U8:
            return Int64(self.block[].read_fixed[DType.uint8](row, off))
        if dt == CELL_DT_U16:
            return Int64(self.block[].read_fixed[DType.uint16](row, off))
        if dt == CELL_DT_U32:
            return Int64(self.block[].read_fixed[DType.uint32](row, off))
        return self.block[].read_fixed[DType.int64](row, off)

    @always_inline
    def read_u64(self, row: Int, col_idx: Int) raises -> UInt64:
        var off = self.col_offsets[col_idx]
        var dt = self.col_dtypes[col_idx]
        # Zero-extend narrower unsigned storage; a U64 cell reads
        # at full width. (Narrow signed cells are not expected here — the
        # walker routes them through read_i64.)
        if dt == CELL_DT_U8 or dt == CELL_DT_BOOL:
            return UInt64(self.block[].read_fixed[DType.uint8](row, off))
        if dt == CELL_DT_U16:
            return UInt64(self.block[].read_fixed[DType.uint16](row, off))
        if dt == CELL_DT_U32:
            return UInt64(self.block[].read_fixed[DType.uint32](row, off))
        return self.block[].read_fixed[DType.uint64](row, off)

    @always_inline
    def read_i128(self, row: Int, col_idx: Int) raises -> SIMD[DType.int128, 1]:
        # Read the full 16-byte DECIMAL128 cell as a signed
        # Int128 (the raw unscaled value). read_i64 would read only the low 8
        # bytes of this cell (silently wrong); the decimal compare
        # arm routes through read_i128 for the full width. Mirrors the SORT path's
        # `read_fixed[DType.int128]`.
        var off = self.col_offsets[col_idx]
        return self.block[].read_fixed[DType.int128](row, off)

    @always_inline
    def decimal_scale_of(self, col_idx: Int) raises -> Int:
        # Mixed-scale: the column's DECIMAL scale from the
        # threaded `col_scales` side-table. The walker pairs this with read_i128
        # to run the scale-aware compare (col `d` @ scale 2 vs literal/col @ a
        # different scale rescales to the higher scale before the int128 compare,
        # matching the column oracle `_compare_decimal128`). A layout with no
        # decimal columns carries an empty `col_scales` and reports 0 (never
        # reached — the decimal arm only fires for DECIMAL128 operands).
        if col_idx < len(self.col_scales):
            return self.col_scales[col_idx]
        return 0

    @always_inline
    def read_f64(self, row: Int, col_idx: Int) raises -> Float64:
        var off = self.col_offsets[col_idx]
        var dt = self.col_dtypes[col_idx]
        # Widen int / f32 storage to logical FLOAT64 (mirrors the column
        # walker's EXPR_COL f64 widening).
        if dt == CELL_DT_I64:
            return Float64(self.block[].read_fixed[DType.int64](row, off))
        if dt == CELL_DT_I32:
            return Float64(self.block[].read_fixed[DType.int32](row, off))
        if dt == CELL_DT_F32:
            return Float64(self.block[].read_fixed[DType.float32](row, off))
        if dt == CELL_DT_BOOL or dt == CELL_DT_U8:
            return Float64(self.block[].read_fixed[DType.uint8](row, off))
        if dt == CELL_DT_I16:
            return Float64(self.block[].read_fixed[DType.int16](row, off))
        if dt == CELL_DT_I8:
            return Float64(self.block[].read_fixed[DType.int8](row, off))
        if dt == CELL_DT_U16:
            return Float64(self.block[].read_fixed[DType.uint16](row, off))
        if dt == CELL_DT_U32:
            return Float64(self.block[].read_fixed[DType.uint32](row, off))
        if dt == CELL_DT_U64:
            return Float64(self.block[].read_fixed[DType.uint64](row, off))
        return self.block[].read_fixed[DType.float64](row, off)

    @always_inline
    def read_i32(self, row: Int, col_idx: Int) raises -> Int32:
        var off = self.col_offsets[col_idx]
        return self.block[].read_fixed[DType.int32](row, off)

    @always_inline
    def read_f32(self, row: Int, col_idx: Int) raises -> Float32:
        var off = self.col_offsets[col_idx]
        return self.block[].read_fixed[DType.float32](row, off)

    def read_string(self, row: Int, col_idx: Int) raises -> String:
        # Decode the var-string descriptor cell at this
        # column's row offset. `read_var_string_at` reads the 8-byte
        # (offset, length) descriptor from the fixed region and copies the
        # payload bytes from the RowBlock var-storage blob.
        var off = self.col_offsets[col_idx]
        var bytes = self.block[].read_var_string_at(row, off)
        var s = String(StringSlice(unsafe_from_utf8=Span(bytes)))
        return s^

    @always_inline
    def is_null(self, row: Int, col_idx: Int) raises -> Bool:
        # F10: read the FORM-ii validity bitmap. A non-nullable
        # layout (no validity region) reports every cell present. `is_cell_null`
        # indexes the per-row bitmap by LOGICAL column index (bit=1 => NULL).
        if not self._has_validity:
            return False
        return self.block[].is_cell_null(row, self.validity_offset, col_idx)

    @always_inline
    def has_validity(self) -> Bool:
        # Expose the block's nullability so
        # `select_filter_from_source` can gate its 3VL null-skip guard. When
        # False (non-nullable layout), the guard is skipped entirely and the
        # filter is byte-identical to the pre-3VL hot path.
        return self._has_validity
