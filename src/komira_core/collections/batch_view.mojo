# =============================================================================
# BatchView[origin] + ColView[dtype, origin] -- typed borrow over a RecordBatch
# =============================================================================
#
# The
# unified-engine kernels (filter_apply, project_apply, agg_combine_apply)
# need a typed borrow-shape wrapper over a RecordBatch whose lifetime is
# tracked by a concrete origin -- NO wildcard, NO UnsafePointer in the
# public surface.
#
# Shape:
#
#     struct BatchView[origin: Origin[mut=False]]
#         var batch: Pointer[RecordBatch, origin]
#         fn n_rows(self) -> Int
#         fn col_i64(self, idx: Int) -> ColView[DType.int64, origin]
#         fn col_i32(self, idx: Int) -> ColView[DType.int32, origin]
#         fn col_f32(self, idx: Int) -> ColView[DType.float32, origin]
#         fn col_f64(self, idx: Int) -> ColView[DType.float64, origin]
#         fn col_bool(self, idx: Int) -> BoolColView[origin]
#
#     struct ColView[dtype: DType, origin: Origin[mut=False]]
#         var _batch: Pointer[RecordBatch, origin]
#         var _idx: Int
#         fn load[W](self, i: Int) -> SIMD[dtype, W]
#         fn validity_load[W](self, i: Int) raises -> SIMD[DType.bool, W]
#         fn has_validity(self) -> Bool
#         fn length(self) -> Int
#
# IMPLEMENTATION NOTE — origin coercion (Mojo 1.0.0b1):
#   RecordBatch.column_at(idx) returns `ref [self._columns._bytes]
#   Column`, a sub-origin of the parent batch's lifetime. Mojo 1.0.0b1
#   does NOT auto-coerce that sub-origin to the BatchView's parent
#   `Self.origin` parameter, so a naive `Pointer(to=col)` in ColView's
#   ctor fails type-resolution. We side-step the issue by having
#   ColView/BoolColView store `(Pointer[RecordBatch, Self.origin],
#   Int idx)` instead of `Pointer[Column, ...]` — the Column ref is
#   re-derived inside each `load[W]` / `validity_load[W]` call from
#   the parent batch pointer. The compiler tracks the parent batch's
#   lifetime end-to-end through `Self.origin`; the per-call
#   `column_at()` returns a sub-origin ref consumed locally within
#   that same call. Trade-off: one extra `column_at(idx)` array
#   lookup per SIMD load (~1 ns; @always_inline allows
#   LLVM to hoist the lookup out of inner loops when the same column
#   is read multiple times).
#
# Scope: i64 / i32 / f32 / f64 / bool primitives (plus the accessors
# below). Not covered here: LargeString/LargeBinary, all temporal types
# beyond the int-aliased ones, nested types (List/Struct/Map/Union), and
# Decimal256 typed wrappers.
#
# Encapsulation invariants:
# - No `UnsafePointer` in any public method signature.
# - All borrows are tracked via `Pointer[T, origin]` with a concrete
#   `origin: Origin[mut=False]` parameter.
# - The wrapped `RecordBatch` lifetime is bound by `origin`; the
#   BatchView and its ColView children cannot outlive the borrowed
#   RecordBatch.
# =============================================================================

from std.sys import size_of

from ..arrow.column import Column
from ..arrow.primitive_array import PrimitiveArray
from ..arrow.record_batch import RecordBatch
from ..arrow.schema import ArrowType
from .string_column_view import (
    BinaryColumnView,
    StringColumnView,
)
from .byte_view import ByteView
from .morsel_view import MorselView, NumericColView


# =============================================================================
# ColView[dtype, origin] -- primitive numeric column borrow
# =============================================================================


struct ColView[dtype: DType, origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, NumericColView
):
    """Typed borrow-view over a primitive numeric column.

    Parameters:
        dtype: The Arrow data type of the column (DType.int64,
            DType.int32, DType.float64, DType.float32, ...).
        origin: The Origin (immutable) under which the borrowed
            parent RecordBatch lives. The borrow is tracked by the
            compiler; ColView cannot outlive `origin`.

    `load[W]` / `validity_load[W]` / `has_validity()`
    surface mirrors the existing `PrimitiveArray[dtype]` methods, but
    operates directly through a typed `Column` ref re-derived per
    call (see module-doc IMPLEMENTATION NOTE for the sub-origin
    coercion rationale).
    """

    # NumericColView associated element DType -- the MorselView seam bound. Lets a
    # generic numeric reader `rebind` a `load[W]` result to its caller DType.
    comptime DT: DType = Self.dtype

    var _batch: Pointer[RecordBatch, Self.origin]
    var _idx: Int

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        idx: Int,
    ):
        """Borrow column `idx` from the RecordBatch under `Self.origin`.

        Constructed by `BatchView.col_*` accessors; not normally
        instantiated by callers directly.
        """
        self._batch = ptr
        self._idx = idx

    @always_inline
    def length(self) -> Int:
        """Logical row count of this column."""
        ref col = self._batch[].column_at(self._idx)
        return col._length

    @always_inline
    def has_validity(self) -> Bool:
        """True iff the column carries a validity bitmap (i.e. may
        contain nulls). False means every row is valid (no-null fast
        path)."""
        ref col = self._batch[].column_at(self._idx)
        return Bool(col._validity)

    @always_inline
    def load[W: Int](self, i: Int) -> SIMD[Self.dtype, W]:
        """SIMD bulk load: read `W` contiguous elements starting at
        logical index `i`.

        Mirrors `PrimitiveArray.load[W]`'s offset-aware shape. The
        byte offset into the underlying MmapAlignedBuffer is computed as
        `(column._offset + i) * size_of[Scalar[dtype]]()`.

        PANICS via underlying MmapAlignedBuffer.load_simd if the range
        `[i, i + W)` exceeds the column's allocated capacity.

        Parameters:
            W: The SIMD vector width (number of lanes).
        """
        comptime elem_size = size_of[Scalar[Self.dtype]]()
        ref col = self._batch[].column_at(self._idx)
        var byte_off = (col._offset + i) * elem_size
        return col._data.load_simd[Self.dtype, W](byte_off)

    def validity_load[W: Int](self, i: Int) raises -> SIMD[DType.bool, W]:
        """SIMD validity load: read `W` contiguous validity bits
        starting at logical index `i`.

        Returns a `SIMD[DType.bool, W]` where lane `j` is `True` iff
        element `i + j` is VALID (not null). For a column without a
        validity bitmap (no-nulls fast path), returns all-True (the
        constant splat folds away in comptime non-nullable
        specializations).

        Raises:
            On out-of-bounds (`i + W > self.length()`).
        """
        ref col = self._batch[].column_at(self._idx)
        if i < 0 or i + W > col._length:
            raise Error(
                "ColView.validity_load: range ["
                + String(i)
                + ", "
                + String(i + W)
                + ") out of bounds [0, "
                + String(col._length)
                + ")"
            )
        if not col._validity:
            return SIMD[DType.bool, W](fill=True)
        # Per-lane unpack from the LSB-first Arrow bitmap (the same
        # pattern `PrimitiveArray` uses).
        var out = SIMD[DType.bool, W](fill=False)
        ref bm = col._validity.value()
        var base = col._offset + i
        comptime for j in range(W):
            var bit_idx = base + j
            var byte_idx = bit_idx >> 3
            var bit_off = bit_idx & 7
            var byte = bm.buffer.read_u8_at(byte_idx)
            var lane_valid = ((byte >> UInt8(bit_off)) & UInt8(1)) == UInt8(1)
            out[j] = lane_valid
        return out

    @always_inline
    def is_null(self, row: Int) -> Bool:
        """True iff element `row` is SQL NULL (validity bit == 0).

        Scalar sibling of `validity_load[1]`. For a column with no validity
        bitmap (no-null fast path) always returns False. Used by the
        runtime-stage slow-path JOIN to honor SQL "NULL never matches" on
        nullable fixed keys."""
        ref col = self._batch[].column_at(self._idx)
        if not col._validity:
            return False
        ref bm = col._validity.value()
        var bit_idx = col._offset + row
        var byte_idx = bit_idx >> 3
        var bit_off = bit_idx & 7
        var byte = bm.buffer.read_u8_at(byte_idx)
        return ((byte >> UInt8(bit_off)) & UInt8(1)) == UInt8(0)

    # ---------------------------------------------------------------------
    # SIMD gather primitive
    # ---------------------------------------------------------------------
    #
    # `gather[W](indices, start)` reads W elements at row positions
    # `indices[start..start+W]`. Per-lane `load[1](idx_k)` inside a
    # `comptime for k in range(W)` block — @always_inline + comptime
    # unrolling lets LLVM emit native SIMD gather (`vgatherdps` /
    # `vpgatherdq` on AVX-512; per-lane scalar loads on NEON).
    #
    # Same pattern as the Parquet dictionary resolver (`resolve_int32`),
    # which emits vpgatherdq on AVX-512; NEON scalar lowers cleanly without
    # per-lane SIMD overhead.
    #
    # The `indices` parameter is a `PrimitiveArray[DType.int32]` of
    # LOGICAL row indices into this column. The column's `_offset`
    # slice semantic is honored automatically — `load[1]` adds the
    # offset before the byte-offset multiply.
    #
    # No bounds check (per-lane). Callers honor the contract that
    # all `indices[start..start+W]` values are in `[0, length())`.
    # The RowSelectionVector-producing filter stages guarantee this
    # by construction.

    @always_inline
    def gather[W: Int](
        self,
        indices: PrimitiveArray[DType.int32],
        start: Int,
    ) raises -> SIMD[Self.dtype, W]:
        """SIMD gather: read W elements at `rows[indices[start..start+W]]`.

        Comptime-unrolled per-lane load — LLVM emits native SIMD
        gather where supported (AVX-512 vpgatherdq / NEON per-lane).
        Honors column offset; lane order matches indices order.

        Parameters:
            W: SIMD vector width (lane count).
        """
        var lanes = SIMD[Self.dtype, W](0)
        comptime for k in range(W):
            var idx_k = Int(indices.get(start + k))
            lanes[k] = self.load[1](idx_k)[0]
        return lanes


# =============================================================================
# Decimal128CellView[origin] -- DECIMAL128 16-byte-cell lo/hi half borrow
# =============================================================================


struct Decimal128CellView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable
):
    """Typed borrow-view over one 64-bit half (lo or hi) of a DECIMAL128 column.

    Arrow Decimal128 is stored as a 16-byte little-endian two's-complement
    cell per row (`Decimal128Array.data` at `row * 16`). A plain
    `ColView[DType.uint64]`, whose `load[W](row)` reads at byte `row * 8`, has
    the WRONG STRIDE for a 16-byte cell (row 1 would read the HI half of row
    0), silently scrambling every DECIMAL128 dedup / group / compare.

    This view reads the correct half at byte `(col._offset + row) * 16 + half`
    where `half` is 0 (lo) or 8 (hi), matching `Decimal128Array.get_i128`'s
    `index * DECIMAL128_BYTE_WIDTH` layout, with the same `load[W](row)[0]`
    call shape as `ColView`."""

    var _batch: Pointer[RecordBatch, Self.origin]
    var _idx: Int
    var _half_byte: Int  # 0 for the low u64, 8 for the high u64.

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        idx: Int,
        half_byte: Int,
    ):
        self._batch = ptr
        self._idx = idx
        self._half_byte = half_byte

    @always_inline
    def length(self) -> Int:
        ref col = self._batch[].column_at(self._idx)
        return col._length

    @always_inline
    def load[W: Int](self, i: Int) -> SIMD[DType.uint64, W]:
        """Read this 64-bit half of the DECIMAL128 cell at logical row `i`.

        Byte offset = `(col._offset + i) * 16 + self._half_byte` — the 16-byte
        cell stride (NOT an 8-byte uint64 stride). For
        `W > 1` the lanes stride by 16 bytes per row (via per-lane loads), so a
        bulk read stays correct; the DECIMAL128 dedup/compare arms read `W == 1`.
        """
        ref col = self._batch[].column_at(self._idx)
        var lanes = SIMD[DType.uint64, W](0)
        comptime for k in range(W):
            var boff = (col._offset + i + k) * 16 + self._half_byte
            lanes[k] = col._data.load_simd[DType.uint64, 1](boff)[0]
        return lanes


# =============================================================================
# BoolColView[origin] -- bit-packed boolean column borrow
# =============================================================================


struct BoolColView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable
):
    """Typed borrow-view over a bit-packed BooleanArray column.

    Boolean columns are bit-packed at the Arrow level (1 bit per
    element, LSB-first within each byte). This view exposes per-row
    `load_bit(i)` and per-W `load[W]` SIMD readers that unpack the
    bits into a `SIMD[DType.bool, W]` lane vector.

    Minimal: enough to host `ExprBool.eval[W]` column reads.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _idx: Int

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        idx: Int,
    ):
        """Borrow bool column `idx` from the RecordBatch under
        `Self.origin`. See ColView.__init__ for the sub-origin
        rationale."""
        self._batch = ptr
        self._idx = idx

    @always_inline
    def length(self) -> Int:
        ref col = self._batch[].column_at(self._idx)
        return col._length

    @always_inline
    def has_validity(self) -> Bool:
        ref col = self._batch[].column_at(self._idx)
        return Bool(col._validity)

    def load_bit(self, i: Int) raises -> Bool:
        """Read one boolean at logical index `i`. Returns True iff the
        bit is set (LSB-first within each bitmap byte)."""
        ref col = self._batch[].column_at(self._idx)
        if i < 0 or i >= col._length:
            raise Error(
                "BoolColView.load_bit: index "
                + String(i)
                + " out of bounds [0, "
                + String(col._length)
                + ")"
            )
        var abs_idx = col._offset + i
        var byte_i = abs_idx >> 3
        var bit_in_byte = abs_idx & 7
        var byte = col._data.read_u8_at(byte_i)
        return ((byte >> UInt8(bit_in_byte)) & UInt8(1)) == UInt8(1)

    def load[W: Int](self, i: Int) raises -> SIMD[DType.bool, W]:
        """SIMD bulk load: unpack `W` bits starting at logical index
        `i` into a `SIMD[DType.bool, W]` lane vector.

        Per-lane unpack from the LSB-first bitmap (the same pattern
        `PrimitiveArray` uses).

        Raises:
            On out-of-bounds (`i + W > self.length()`).
        """
        ref col = self._batch[].column_at(self._idx)
        if i < 0 or i + W > col._length:
            raise Error(
                "BoolColView.load: range ["
                + String(i)
                + ", "
                + String(i + W)
                + ") out of bounds [0, "
                + String(col._length)
                + ")"
            )
        var out = SIMD[DType.bool, W](fill=False)
        var base = col._offset + i
        comptime for j in range(W):
            var bit_idx = base + j
            var byte_idx = bit_idx >> 3
            var bit_off = bit_idx & 7
            var byte = col._data.read_u8_at(byte_idx)
            var lane_set = ((byte >> UInt8(bit_off)) & UInt8(1)) == UInt8(1)
            out[j] = lane_set
        return out

    def validity_load[W: Int](self, i: Int) raises -> SIMD[DType.bool, W]:
        """Validity load -- same shape as ColView.validity_load."""
        ref col = self._batch[].column_at(self._idx)
        if i < 0 or i + W > col._length:
            raise Error(
                "BoolColView.validity_load: range ["
                + String(i)
                + ", "
                + String(i + W)
                + ") out of bounds [0, "
                + String(col._length)
                + ")"
            )
        if not col._validity:
            return SIMD[DType.bool, W](fill=True)
        var out = SIMD[DType.bool, W](fill=False)
        ref bm = col._validity.value()
        var base = col._offset + i
        comptime for j in range(W):
            var bit_idx = base + j
            var byte_idx = bit_idx >> 3
            var bit_off = bit_idx & 7
            var byte = bm.buffer.read_u8_at(byte_idx)
            var lane_valid = ((byte >> UInt8(bit_off)) & UInt8(1)) == UInt8(1)
            out[j] = lane_valid
        return out


# =============================================================================
# BatchView[origin] -- typed borrow over a whole RecordBatch
# =============================================================================


struct BatchView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, MorselView
):
    """Typed borrow-shape wrapper over a RecordBatch.

    The typed-accessor surface that the unified-
    engine kernels (`filter_apply[E: ExprBool]`, `project_apply[E:
    ExprList]`, `agg_combine_apply[A: AggI64]`, ...) consume. The
    underlying RecordBatch's lifetime is bounded by `origin`; the
    BatchView cannot escape that lifetime.

    Parameters:
        origin: Origin[mut=False] under which the borrowed RecordBatch
            lives. The compiler tracks the lifetime; encapsulation is
            preserved.

    Per-column accessors return typed `ColView[dtype, origin]` /
    `BoolColView[origin]` wrappers that share the parent's origin.
    No UnsafePointer in the public surface.
    """

    var _batch: Pointer[RecordBatch, Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin] batch: RecordBatch,
    ):
        """Construct a BatchView borrowing `batch` under `Self.origin`.

        The canonical engine-seam idiom is `var bv = BatchView(batch)`
        with parametric origin inferred at the call site. A
        `BatchView.over(batch)` static-factory shape is not possible:
        Mojo 1.0.0b1 cannot infer the
        parent struct's `origin` parameter from a @staticmethod's
        ref-parameter alone (the "failed to infer parameter
        '_mlir_origin' of parent struct" diagnostic). The module-
        level free factory `batch_view_over` below provides the
        equivalent named entry point with full origin inference.
        """
        self._batch = Pointer(to=batch)

    @always_inline
    def n_rows(self) -> Int:
        """Number of rows in the wrapped RecordBatch."""
        return self._batch[].num_rows()

    @always_inline
    def num_columns(self) -> Int:
        """Number of columns in the wrapped RecordBatch."""
        return self._batch[].schema.num_columns()

    @always_inline
    def has_selection_mask(self) -> Bool:
        """True iff the wrapped batch carries a reader-
        deferred selection mask the fold MUST honor (else it over-aggregates
        the filtered-out rows)."""
        return self._batch[].has_selection_mask()

    @always_inline
    def selection_mask_get(self, row: Int) raises -> Bool:
        """Is `row` LIVE under the selection mask? True when
        no mask is set (identity — every row live)."""
        return self._batch[].selection_mask_get(row)

    @always_inline
    def col_is_null(self, idx: Int, row: Int) -> Bool:
        """Is cell (`idx`, `row`) NULL? Non-raising, offset-aware,
        DType-agnostic (reads only the validity bitmap, not the data).

        Returns False for a column with no validity bitmap (all-valid fast
        path). Callers in the join build/probe consult this per key column so a
        NULL join key matches NOTHING (SQL "NULL never matches"). Bitmap
        convention: bit=1 valid, so NULL == bit clear.
        """
        ref col = self._batch[].column_at(idx)
        if not col._validity:
            return False
        var bit_idx = col._offset + row
        ref bm = col._validity.value()
        var byte = bm.buffer.read_u8_at(bit_idx >> 3)
        return ((byte >> UInt8(bit_idx & 7)) & UInt8(1)) == UInt8(0)

    def col_any_null(self, idx: Int, n: Int) -> Bool:
        """Does column `idx` hold a NULL ANYWHERE in rows `[0, n)`?

        The RANGE form of `col_is_null`, and deliberately the SAME question
        asked of the same bytes: same validity bitmap, same `_offset` rebase,
        same "bit=1 valid" convention, same "no bitmap == no nulls" answer. The
        contract a caller may rely on is the equivalence —
        `col_any_null(idx, n)` is False iff `col_is_null(idx, r)` is False for
        every `r` in `[0, n)` — so a fast path gated on this cannot disagree
        with a slow path gated on the per-row form. (Rows past the validity
        bitmap's own `length` are clamped away rather than read out of bounds.
        That cannot narrow the answer for a real row: every producer sizes the
        bitmap to the column, and a sliced column's `_offset + length` stays
        inside its shared parent bitmap.)

        WHY IT EXISTS AT ALL, rather than a caller-side loop over `col_is_null`:
        cost. Grouped-aggregate fast
        folds decline on nullable group keys, and the useful question there is
        whether a null is PRESENT, not whether one is DECLARED possible — but a
        per-row `col_is_null` sweep to answer it is one byte load + shift per
        row per key column, which on a 6M-row group-by costs more than it saves.
        This walks the BITMAP: O(1) when the column carries no validity buffer
        (the common case), else one 64-bit load per 64 rows, with a partial head
        and tail walked by byte and then by bit. It never touches the data
        buffer, so its cost is independent of the column's width.
        """
        if n <= 0:
            return False
        ref col = self._batch[].column_at(idx)
        if not col._validity:
            return False
        ref bm = col._validity.value()
        var i = col._offset
        var hi = col._offset + n
        # A row past the bitmap's own length is not a row; clamp rather than
        # read out of bounds (`col_is_null` would too).
        if hi > bm.length:
            hi = bm.length
        # Head — bits up to the next byte boundary, so the wide lanes below are
        # byte-addressable.
        while i < hi and (i & 7) != 0:
            if not bm.test(i):
                return True
            i += 1
        # Body — 64 rows per load, then 8. Both lanes stay strictly inside
        # `[i, hi)`, so no trailing pad bit past `bm.length` is ever tested (the
        # pad is zero-filled and would read as a null).
        var all64 = UInt64(0xFFFFFFFFFFFFFFFF)
        while i + 64 <= hi:
            if bm.buffer.read_u64_le_at(i >> 3) != all64:
                return True
            i += 64
        while i + 8 <= hi:
            if bm.buffer.read_u8_at(i >> 3) != UInt8(0xFF):
                return True
            i += 8
        # Tail — the final partial byte.
        while i < hi:
            if not bm.test(i):
                return True
            i += 1
        return False

    # ---------------------------------------------------------------------
    # Per-DType typed accessors. Each returns a ColView[T, origin] that
    # shares this view's `origin` -- no widening, no wildcard.
    # ---------------------------------------------------------------------

    @always_inline
    def col_typed[
        dt: DType
    ](self, idx: Int) -> ColView[dt, Self.origin]:
        """Borrow column `idx` as a typed view at the COMPTIME DType `dt`.

        The comptime-parametric form of the per-DType `col_*` accessors —
        lets a monomorphized kernel (e.g. a single-int-key fold) pick
        its reader at comptime instead of a runtime `dtype_tag` branch. Same
        origin, no widening, no wildcard. Caller MUST have proven the column's
        storage DType matches `dt` (the col_* accessors carry the same
        precondition)."""
        return ColView[dt, Self.origin](self._batch, idx)

    @always_inline
    def col_i64(self, idx: Int) -> ColView[DType.int64, Self.origin]:
        """Borrow column `idx` as an Int64 typed view."""
        return ColView[DType.int64, Self.origin](self._batch, idx)

    @always_inline
    def col_i32(self, idx: Int) -> ColView[DType.int32, Self.origin]:
        """Borrow column `idx` as an Int32 typed view."""
        return ColView[DType.int32, Self.origin](self._batch, idx)

    @always_inline
    def col_date32(self, idx: Int) -> ColView[DType.int32, Self.origin]:
        """Borrow column `idx` as a Date32 typed view (Int32-aliased).

        Date32 in Arrow is days-since-epoch (UNIX), stored as Int32.
        The underlying storage is identical to col_i32; this method
        signals the SEMANTIC intent (date comparisons / arithmetic
        operate on days-since-epoch).
        """
        return ColView[DType.int32, Self.origin](self._batch, idx)

    @always_inline
    def col_f64(self, idx: Int) -> ColView[DType.float64, Self.origin]:
        """Borrow column `idx` as a Float64 typed view."""
        return ColView[DType.float64, Self.origin](self._batch, idx)

    @always_inline
    def col_f32(self, idx: Int) -> ColView[DType.float32, Self.origin]:
        """Borrow column `idx` as a Float32 typed view."""
        return ColView[DType.float32, Self.origin](self._batch, idx)

    @always_inline
    def col_bool(self, idx: Int) -> BoolColView[Self.origin]:
        """Borrow column `idx` as a Boolean (bit-packed) typed view."""
        return BoolColView[Self.origin](self._batch, idx)

    @always_inline
    def col_dtype(self, idx: Int) -> DType:
        """Return the storage DType of column `idx` from the batch schema.

        Lets a runtime-dispatched kernel (e.g. the Column UNTYPED
        hash-agg AVG path, whose single op_tag spans multiple numeric
        source DTypes) pick the correct typed `col_*` reader instead of
        bitcast-misreading the raw bytes. Read-only; no widening, no
        UnsafePointer in the surface (the DType is read via the parent
        batch's `schema.field_dtype`, an origin-tracked borrow)."""
        return self._batch[].schema.field_dtype(idx)

    # ---------------------------------------------------------------------
    # DType accessor expansion covering the fixed-width DType
    # combinations the untyped row and column paths need. Each accessor is
    # a straight pass-through
    # constructor over ColView[<dt>, origin]; @always_inline lets LLVM
    # inline the BatchView -> ColView -> column_at -> SIMD load chain.
    #
    # Coverage:
    #   - 8-bit:  i8 / u8         (small ints; Decimal mantissa cells)
    #   - 16-bit: i16 / u16       (small ints)
    #   - 32-bit: u32             (i32 / date32 / f32 already present)
    #   - 64-bit: u64 / date64    (i64 / f64 already present; date64 is
    #             int64-aliased ms-since-epoch in Arrow)
    #   - Timestamp_* (ns/us/ms/s) -- Arrow stores all as int64
    # Var-width STRING / BINARY views are `StringColumnView` /
    # `BinaryColumnView` (below).
    # ---------------------------------------------------------------------

    @always_inline
    def col_i8(self, idx: Int) -> ColView[DType.int8, Self.origin]:
        """Borrow column `idx` as an Int8 typed view."""
        return ColView[DType.int8, Self.origin](self._batch, idx)

    @always_inline
    def col_u8(self, idx: Int) -> ColView[DType.uint8, Self.origin]:
        """Borrow column `idx` as a UInt8 typed view."""
        return ColView[DType.uint8, Self.origin](self._batch, idx)

    @always_inline
    def col_i16(self, idx: Int) -> ColView[DType.int16, Self.origin]:
        """Borrow column `idx` as an Int16 typed view."""
        return ColView[DType.int16, Self.origin](self._batch, idx)

    @always_inline
    def col_u16(self, idx: Int) -> ColView[DType.uint16, Self.origin]:
        """Borrow column `idx` as a UInt16 typed view."""
        return ColView[DType.uint16, Self.origin](self._batch, idx)

    @always_inline
    def col_u32(self, idx: Int) -> ColView[DType.uint32, Self.origin]:
        """Borrow column `idx` as a UInt32 typed view."""
        return ColView[DType.uint32, Self.origin](self._batch, idx)

    @always_inline
    def col_u64(self, idx: Int) -> ColView[DType.uint64, Self.origin]:
        """Borrow column `idx` as a UInt64 typed view."""
        return ColView[DType.uint64, Self.origin](self._batch, idx)

    @always_inline
    def col_date64(self, idx: Int) -> ColView[DType.int64, Self.origin]:
        """Borrow column `idx` as a Date64 typed view (Int64-aliased).

        Date64 in Arrow is milliseconds-since-epoch (UNIX), stored as
        Int64. Underlying storage identical to col_i64; this method
        signals SEMANTIC intent. Mirrors col_date32's Date32 carve-out.
        """
        return ColView[DType.int64, Self.origin](self._batch, idx)

    @always_inline
    def col_timestamp_ns(self, idx: Int) -> ColView[DType.int64, Self.origin]:
        """Borrow column `idx` as a Timestamp(ns) typed view (Int64-aliased).

        Arrow Timestamp at all resolutions is Int64; the resolution is a
        schema-side concern. Accessor signals SEMANTIC intent (caller is
        reading a nanosecond-resolution timestamp).
        """
        return ColView[DType.int64, Self.origin](self._batch, idx)

    @always_inline
    def col_timestamp_us(self, idx: Int) -> ColView[DType.int64, Self.origin]:
        """Borrow column `idx` as a Timestamp(us) typed view (Int64-aliased)."""
        return ColView[DType.int64, Self.origin](self._batch, idx)

    @always_inline
    def col_timestamp_ms(self, idx: Int) -> ColView[DType.int64, Self.origin]:
        """Borrow column `idx` as a Timestamp(ms) typed view (Int64-aliased)."""
        return ColView[DType.int64, Self.origin](self._batch, idx)

    @always_inline
    def col_timestamp_s(self, idx: Int) -> ColView[DType.int64, Self.origin]:
        """Borrow column `idx` as a Timestamp(s) typed view (Int64-aliased)."""
        return ColView[DType.int64, Self.origin](self._batch, idx)

    @always_inline
    def col_decimal128_lo(
        self, idx: Int
    ) -> Decimal128CellView[Self.origin]:
        """Borrow column `idx` as the Decimal128 LOW 64 bits typed view.

        Arrow Decimal128 is a 16-byte LE cell per row. This returns the LOW
        u64 half; `col_decimal128_hi` returns the HIGH half. The view reads at
        the correct 16-byte cell stride (`row * 16 + 0`), matching
        `Decimal128Array.get_i128`'s `index * 16` layout.

        An 8-byte-stride `ColView[DType.uint64]` would mis-read row >= 1 (it
        lands on the HI half of the prior row), silently scrambling every
        DECIMAL128 distinct / group-by / join dedup for multi-row inputs.
        """
        return Decimal128CellView[Self.origin](self._batch, idx, 0)

    @always_inline
    def col_decimal128_hi(
        self, idx: Int
    ) -> Decimal128CellView[Self.origin]:
        """Borrow column `idx` as the Decimal128 HIGH 64 bits typed view
        (`row * 16 + 8`). See col_decimal128_lo for the stride rationale."""
        return Decimal128CellView[Self.origin](self._batch, idx, 8)

    # ---------------------------------------------------------------------
    # NUMERIC dictionary column
    # accessors. The producer (the Parquet decoder's numeric dict arms)
    # emits a NUMERIC DICTIONARY Column for an INT32/INT64 key col while the
    # batch SCHEMA reports the logical int dtype (so descriptor resolution is
    # unchanged). The agg consumer checks `col_is_numeric_dict(idx)` once per
    # (col, batch) and, if True, reads the per-row code + resolves the dict
    # value via these accessors instead of `col_i64`/`col_i32` (which would
    # bitcast-misread the codes as values). Byte-equivalent to the flat path
    # by construction (same resolved values).
    # ---------------------------------------------------------------------

    @always_inline
    def col_is_numeric_dict(self, idx: Int) -> Bool:
        """True iff column `idx` is a NUMERIC dictionary column (codes + flat
        numeric dict values)."""
        return self._batch[].column_at(idx).is_numeric_dict()

    @always_inline
    def col_dict_value_dtype(self, idx: Int) -> DType:
        """Value DType a numeric dictionary column's codes resolve to."""
        return self._batch[].column_at(idx).dict_value_dtype()

    @always_inline
    def col_dict_size(self, idx: Int) -> Int:
        """Number of distinct dictionary entries for a numeric dict col `idx`.
        Sizes a dense per-row-group code-indexed partial."""
        return self._batch[].column_at(idx).dict_size()

    @always_inline
    def col_dict_code_at(self, idx: Int, row: Int) -> Int:
        """Per-row dictionary CODE at (`idx`, `row`) for a numeric dict col."""
        return self._batch[].column_at(idx).dict_code_at(row)

    @always_inline
    def col_dict_code_width(self, idx: Int) -> Int:
        """Byte width of a numeric dict col's per-row CODES (4 = int32, 8 =
        int64). Lets a reader take 4-byte codes through
        `col_numeric_dict_codes_view` in one contiguous pass."""
        return self._batch[].column_at(idx).dict_index_byte_width()

    @always_inline
    def col_elem_offset(self, idx: Int) -> Int:
        """Column `idx`'s ELEMENT slice offset (`Column.offset()`): row `r` of a
        view over the column's whole buffer lives at element `offset + r`."""
        return self._batch[].column_at(idx).offset()

    def col_numeric_dict_codes_view(self, idx: Int) -> ByteView[Self.origin]:
        """Borrow a NUMERIC dict col's per-row CODES buffer — the WHOLE `_data`
        buffer, so row `r`'s code is element `col_elem_offset(idx) + r` of
        width `col_dict_code_width(idx)` — as a byte-backed `ByteView` (origin =
        the BATCH). Precondition: `col_is_numeric_dict(idx)`. The numeric twin
        of `col_string_dict_codes_view` (the codes live in `_data` either way)."""
        # SAFETY: see `col_string_dict_codes_view` — the same confined re-label
        # of the column's sub-origin onto the enclosing batch origin.
        var v = self._batch[].column_at(idx).numeric_dict_codes_view()
        return ByteView[Self.origin](
            v._unsafe_ptr().unsafe_origin_cast[Self.origin](), v.len()
        )

    @always_inline
    def col_dict_value_i64(self, idx: Int, code: Int) -> Int64:
        """Resolve numeric dict `code` to its Int64 value (int32/int64 dict)."""
        return self._batch[].column_at(idx).dict_value_i64(code)

    @always_inline
    def col_dict_value_f64(self, idx: Int, code: Int) -> Float64:
        """Resolve numeric dict `code` to its Float64 value (f32/f64 dict)."""
        return self._batch[].column_at(idx).dict_value_f64(code)

    # ---------------------------------------------------------------------
    # DICTIONARY layout-split probes + the
    # STRING-dict CODE accessor family. PARALLEL to the numeric-dict family
    # above (a distinct accessor surface, NOT an overload). `arrow_type ==
    # DICTIONARY` is ONE tag over TWO physical layouts; operators MUST branch
    # on `col_is_numeric_dict(idx)` / `col_is_string_dict(idx)`, never the
    # bare tag. The string-dict accessors expose int32 codes + the raw dict
    # payload (offsets + UTF-8 bytes) as byte-backed views WITHOUT building a
    # StringArray/StringDictionaryArray, which is not safe to build on a
    # worker thread; the reconstruction stays on the serial post-barrier
    # drain. Predicates over dictionary codes compute over these views.
    # ---------------------------------------------------------------------

    @always_inline
    def col_is_dictionary(self, idx: Int) -> Bool:
        """True iff column `idx` carries the DICTIONARY tag (either layout).
        Callers MUST further probe `col_is_numeric_dict` / `col_is_string_dict`
        to pick the physical layout — never act on this tag alone."""
        return self._batch[].column_at(idx).is_dictionary()

    @always_inline
    def col_is_string_dict(self, idx: Int) -> Bool:
        """True iff column `idx` is a STRING dictionary column (int32 codes +
        packed UTF-8 dict bytes addressed by offsets). The complement of
        `col_is_numeric_dict` within the DICTIONARY tag."""
        return self._batch[].column_at(idx).is_string_dict()

    @always_inline
    def col_string_dict_code_at(self, idx: Int, row: Int) -> Int:
        """Per-row int32 dictionary CODE at (`idx`, `row`) for a string dict
        col. Precondition: `col_is_string_dict(idx)` is True."""
        return self._batch[].column_at(idx).string_dict_code_at(row)

    def col_string_dict_codes_view(
        self, idx: Int
    ) -> ByteView[Self.origin]:
        """Borrow column `idx`'s per-row int32 CODES buffer as a byte-backed
        `ByteView` (origin = the BATCH). Codes are int32; read code at `row`
        via `view.get_typed[Int32](col_offset + row)`. Precondition:
        `col_is_string_dict(idx)` is True. NO StringArray constructed —
        worker-safe (codes + raw bytes only)."""
        # `column_at(idx)` returns a sub-origin of `Self.origin`; the inferred
        # view rides that sub-origin. Re-label onto `Self.origin` (the batch
        # owns the column slab, so the sub-origin is bounded by it).
        # SAFETY: module-private `_unsafe_ptr` escape (BatchView is under
        # komira_core/collections/); the cast widens a
        # sub-origin to its enclosing batch origin — both ASAP-tracked, no
        # wildcard. Mirrors ColumnNativeBatch's `values_view_native` re-cast.
        var v = self._batch[].column_at(idx).string_dict_codes_view()
        return ByteView[Self.origin](
            v._unsafe_ptr().unsafe_origin_cast[Self.origin](), v.len()
        )

    def col_string_dict_offsets_view(
        self, idx: Int
    ) raises -> ByteView[Self.origin]:
        """Borrow column `idx`'s dict-string int32 OFFSETS buffer (`_dict_size
        + 1` entries) as a byte-backed `ByteView` (origin = the BATCH). Dict
        entry `e`'s UTF-8 bytes span `[offsets[e], offsets[e+1])`. Raises if
        the column is not a string dict. NO StringArray constructed."""
        # SAFETY: see `col_string_dict_codes_view`.
        var v = self._batch[].column_at(idx).string_dict_offsets_view()
        return ByteView[Self.origin](
            v._unsafe_ptr().unsafe_origin_cast[Self.origin](), v.len()
        )

    def col_string_dict_bytes_view(
        self, idx: Int
    ) raises -> ByteView[Self.origin]:
        """Borrow column `idx`'s packed dict-string UTF-8 BYTES buffer
        (`_dict_data`) as a byte-backed `ByteView` (origin = the BATCH). Raises
        if the column is not a string dict. NO StringArray / StringDictionary-
        Array constructed — worker-safe."""
        # SAFETY: see `col_string_dict_codes_view`.
        var v = self._batch[].column_at(idx).string_dict_bytes_view()
        return ByteView[Self.origin](
            v._unsafe_ptr().unsafe_origin_cast[Self.origin](), v.len()
        )

    def col_string_dict_value_at(
        self, idx: Int, code: Int
    ) raises -> ByteView[Self.origin]:
        """Resolve column `idx`'s dict entry
        `code` -> its UTF-8 bytes as a batch-origin `ByteView`, WITHOUT
        constructing a StringArray (worker-safe dict-native resolve). Thin
        seam over `Column.string_dict_value_at`. Raises if the column is not a
        string dict. Precondition: `col_is_string_dict(idx)` is True."""
        # SAFETY: see `col_string_dict_codes_view`.
        var v = self._batch[].column_at(idx).string_dict_value_at(code)
        return ByteView[Self.origin](
            v._unsafe_ptr().unsafe_origin_cast[Self.origin](), v.len()
        )

    # ---------------------------------------------------------------------
    # The single generic fixed-width
    # scalar read primitive (`col_scalar[dt]`). Replaces the per-operator
    # hand-rolled `comptime if K == int64 / int32 / float64 / float32 ...
    # else: col_i64` ladders whose `else: col_i64` branch SILENTLY corrupts
    # any unhandled DType (an F64 key read via col_i64 returns the float's
    # BIT pattern as an Int64; I8/I16 over-read 8 bytes of a narrow column;
    # decimal128/STRING are structurally impossible).
    #
    # The whole point of this primitive is the ABSENCE of an i64
    # else-fallthrough: an unhandled fixed-width DType is a `constrained`
    # COMPILE ERROR, not a silent wrong read. That single property
    # structurally prevents the join-key i64-channel corruption
    # class.
    #
    # Coverage: the FULL fixed-width matrix — i8/16/32/64, u8/16/32/64,
    # f32/f64, bool, date32 (i32-aliased), date64/timestamp (i64-aliased).
    # STRING is variable-width and NOT in col_scalar — it stays on the
    # `col_str` sidecar. DECIMAL128 is 16 B (2x u64) and does NOT fit the
    # single-`Scalar[dt]` channel — it rides the `col_decimal128_{lo,hi}`
    # split-u64 accessors.
    #
    # The per-DType branch folds away at comptime (the column is
    # monomorphized per DType); @always_inline lets LLVM inline the
    # BatchView -> ColView -> column_at -> SIMD load chain.
    # ---------------------------------------------------------------------

    @always_inline
    def col_scalar[dt: DType](self, idx: Int, row: Int) raises -> Scalar[dt]:
        """Read the scalar value of fixed-width DType `dt` at `row` from
        column `idx`. THE generic dtype-dispatching read primitive — the
        single replacement for the per-operator `comptime if dt==X ... else
        col_i64` read ladders.

        CRITICAL: there is NO i64 else-fallthrough. An unhandled DType is a
        `constrained[False]` COMPILE ERROR (not a silent i64 read) — this is
        the property that structurally prevents the join-key corruption
        class. STRING (variable-width) and DECIMAL128 (16 B) are NOT served
        here; callers use `col_str` / `col_decimal128_{lo,hi}` respectively.

        `raises` because the bit-packed `bool` arm goes through
        `BoolColView.load` (bounds-checked, raising); every numeric arm is
        itself non-raising. Join/agg/sort batch-read bodies are already
        `raises`, so this is drop-in there.

        Parameters:
            dt: The fixed-width DType to read (comptime).
        """

        comptime if dt == DType.int64:
            return rebind[Scalar[dt]](self.col_i64(idx).load[1](row)[0])
        elif dt == DType.uint64:
            return rebind[Scalar[dt]](self.col_u64(idx).load[1](row)[0])
        elif dt == DType.int32:
            return rebind[Scalar[dt]](self.col_i32(idx).load[1](row)[0])
        elif dt == DType.uint32:
            return rebind[Scalar[dt]](self.col_u32(idx).load[1](row)[0])
        elif dt == DType.int16:
            return rebind[Scalar[dt]](self.col_i16(idx).load[1](row)[0])
        elif dt == DType.uint16:
            return rebind[Scalar[dt]](self.col_u16(idx).load[1](row)[0])
        elif dt == DType.int8:
            return rebind[Scalar[dt]](self.col_i8(idx).load[1](row)[0])
        elif dt == DType.uint8:
            return rebind[Scalar[dt]](self.col_u8(idx).load[1](row)[0])
        elif dt == DType.float64:
            return rebind[Scalar[dt]](self.col_f64(idx).load[1](row)[0])
        elif dt == DType.float32:
            return rebind[Scalar[dt]](self.col_f32(idx).load[1](row)[0])
        elif dt == DType.bool:
            # Bool columns are bit-packed (BoolColView); read one bit and
            # widen to the bool Scalar.
            var bits = self.col_bool(idx).load[1](row)
            return rebind[Scalar[dt]](bits[0])
        else:
            comptime assert False, ( "col_scalar: unhandled DType — STRING uses col_str," " DECIMAL128 uses col_decimal128_{lo,hi}; every other" " fixed-width DType must be added to this ladder. NO" " silent i64 fallthrough." )

    @always_inline
    def col_scalar_nonraising[dt: DType](self, idx: Int, row: Int) -> Scalar[dt]:
        """Non-raising sibling of `col_scalar[dt]` over the fixed-width NUMERIC
        matrix.

        Identical no-fallthrough discipline as `col_scalar`: an unhandled DType
        is a `constrained[False]` COMPILE ERROR — NEVER a silent `col_i64`
        misread. The single difference is that `bool` is NOT served here (the
        bit-packed `BoolColView.load` path is bounds-checked / `raises`, and a
        non-raising read cannot host it). The per-operator read helpers
        (`_distinct_read_key_scalar`, `_read_sort_scalar`, the agg group-key /
        aggregand reads) are non-raising `fn` threaded through non-raising trait
        surfaces (`DistinctKeyColumn` / `SortKeyColumn` / `AggColumn`), so they
        consume THIS primitive rather than the raising `col_scalar`. A `bool`
        key/sort-key/aggregand becomes a COMPILE ERROR (a safe decline to the
        untyped path), never silent corruption.

        Covers: i8/16/32/64, u8/16/32/64, f32/f64 (+ date32 via i32, date64 /
        timestamp via i64 — all storage-aliased). STRING uses `col_str`;
        DECIMAL128 uses `col_decimal128_{lo,hi}`; bool uses `col_scalar` (raising)
        or `col_bool` directly.

        Parameters:
            dt: The fixed-width numeric DType to read (comptime).
        """

        comptime if dt == DType.int64:
            return rebind[Scalar[dt]](self.col_i64(idx).load[1](row)[0])
        elif dt == DType.uint64:
            return rebind[Scalar[dt]](self.col_u64(idx).load[1](row)[0])
        elif dt == DType.int32:
            return rebind[Scalar[dt]](self.col_i32(idx).load[1](row)[0])
        elif dt == DType.uint32:
            return rebind[Scalar[dt]](self.col_u32(idx).load[1](row)[0])
        elif dt == DType.int16:
            return rebind[Scalar[dt]](self.col_i16(idx).load[1](row)[0])
        elif dt == DType.uint16:
            return rebind[Scalar[dt]](self.col_u16(idx).load[1](row)[0])
        elif dt == DType.int8:
            return rebind[Scalar[dt]](self.col_i8(idx).load[1](row)[0])
        elif dt == DType.uint8:
            return rebind[Scalar[dt]](self.col_u8(idx).load[1](row)[0])
        elif dt == DType.float64:
            return rebind[Scalar[dt]](self.col_f64(idx).load[1](row)[0])
        elif dt == DType.float32:
            return rebind[Scalar[dt]](self.col_f32(idx).load[1](row)[0])
        else:
            comptime assert False, ( "col_scalar_nonraising: unhandled DType — bool uses the" " raising col_scalar / col_bool; STRING uses col_str;" " DECIMAL128 uses col_decimal128_{lo,hi}. NO silent i64" " fallthrough." )

    @always_inline
    def col_scalar_simd[dt: DType, W: Int](self, idx: Int, i: Int) -> SIMD[dt, W]:
        """SIMD-W non-raising sibling of `col_scalar_nonraising[dt]` — read W
        contiguous values of fixed-width numeric DType `dt` from column `idx`
        starting at row `i`.

        Same no-fallthrough discipline (unhandled DType = COMPILE ERROR, no silent
        `col_i64`). Hosts the TOP-N SIMD reject read (`_read_sort_simd`). Bool not
        served (bit-packed). Caller guarantees `i + W <= n_rows`.

        Parameters:
            dt: The fixed-width numeric DType (comptime).
            W: SIMD vector width (comptime).
        """

        comptime if dt == DType.int64:
            return rebind[SIMD[dt, W]](self.col_i64(idx).load[W](i))
        elif dt == DType.uint64:
            return rebind[SIMD[dt, W]](self.col_u64(idx).load[W](i))
        elif dt == DType.int32:
            return rebind[SIMD[dt, W]](self.col_i32(idx).load[W](i))
        elif dt == DType.uint32:
            return rebind[SIMD[dt, W]](self.col_u32(idx).load[W](i))
        elif dt == DType.int16:
            return rebind[SIMD[dt, W]](self.col_i16(idx).load[W](i))
        elif dt == DType.uint16:
            return rebind[SIMD[dt, W]](self.col_u16(idx).load[W](i))
        elif dt == DType.int8:
            return rebind[SIMD[dt, W]](self.col_i8(idx).load[W](i))
        elif dt == DType.uint8:
            return rebind[SIMD[dt, W]](self.col_u8(idx).load[W](i))
        elif dt == DType.float64:
            return rebind[SIMD[dt, W]](self.col_f64(idx).load[W](i))
        elif dt == DType.float32:
            return rebind[SIMD[dt, W]](self.col_f32(idx).load[W](i))
        else:
            comptime assert False, ( "col_scalar_simd: unhandled DType — bool / STRING /" " DECIMAL128 are not served by the SIMD numeric read. NO" " silent i64 fallthrough." )

    # ---------------------------------------------------------------------
    # Variable-length
    # STRING / BINARY typed accessors. The two views share the storage
    # shape (offset+length pair per row); the distinction is semantic
    # (UTF-8 validation vs arbitrary bytes).
    # ---------------------------------------------------------------------

    @always_inline
    def col_str(self, idx: Int) -> StringColumnView[Self.origin]:
        """Borrow column `idx` as a variable-length STRING typed view.

        Returns a `StringColumnView[Self.origin]` that exposes
        `length() / get(row) / offset_at(row) / n_data_bytes()` -- the
        offset+length arithmetic that `ColView[DType.uint8, _]` cannot
        expose because the offsets buffer is held on the parent Column.

        The untyped column and row paths (including row-format varlen
        encode/decode) consume this view.
        """
        return StringColumnView[Self.origin](self._batch, idx)

    @always_inline
    def col_binary(self, idx: Int) -> BinaryColumnView[Self.origin]:
        """Borrow column `idx` as a variable-length BINARY typed view.

        Mirror of `col_str` for arbitrary-byte (NOT UTF-8 validated)
        columns. Same storage shape; semantic distinction only.
        """
        return BinaryColumnView[Self.origin](self._batch, idx)


# =============================================================================
# Module-level factory -- equivalent of `BatchView.over(batch)`
# =============================================================================


# =============================================================================
# scalar_arrow_type[dt] -- the matching output-schema synthesis primitive
# =============================================================================
#
# Mirror of `col_scalar[dt]` for the
# OUTPUT schema: maps a fixed-width DType to its `ArrowType` so a typed
# operator's drain schema is correct for the full matrix, replacing the
# per-operator `_key_arrow_type` / `_agg_arrow_type` / `_distinct_key_arrow_type`
# / `_sort_arrow_type` copies whose `else: INT64` silently synthesizes the
# WRONG output type. Same no-fallthrough discipline as col_scalar: an
# unhandled fixed-width DType is a `constrained` COMPILE ERROR.
#
# NOTE on date/timestamp: these are storage-aliased to i32/i64 at the DType
# level (DType carries no date/ts distinction), so a date32 key reported via
# `scalar_arrow_type[int32]` emits INT32, not DATE32. The semantic date/ts
# ArrowType is a schema-side concern threaded separately by callers that
# carry the source field's ArrowType; this primitive synthesizes the
# STORAGE ArrowType for the common numeric case. STRING/DECIMAL128 are not
# served here (variable / 16-byte — handled by their own paths).


@always_inline
def scalar_arrow_type[dt: DType]() -> ArrowType:
    """Map a fixed-width DType to its storage `ArrowType` for an output
    schema. No i64 else-fallthrough — an unhandled DType is a compile error.
    """

    comptime if dt == DType.int64:
        return ArrowType.INT64
    elif dt == DType.uint64:
        return ArrowType.UINT64
    elif dt == DType.int32:
        return ArrowType.INT32
    elif dt == DType.uint32:
        return ArrowType.UINT32
    elif dt == DType.int16:
        return ArrowType.INT16
    elif dt == DType.uint16:
        return ArrowType.UINT16
    elif dt == DType.int8:
        return ArrowType.INT8
    elif dt == DType.uint8:
        return ArrowType.UINT8
    elif dt == DType.float64:
        return ArrowType.FLOAT64
    elif dt == DType.float32:
        return ArrowType.FLOAT32
    elif dt == DType.bool:
        return ArrowType.BOOL
    else:
        comptime assert False, ( "scalar_arrow_type: unhandled DType — STRING/DECIMAL128 and" " any other type must be mapped on their own path. NO silent" " INT64 fallthrough." )


@always_inline
def batch_view_over[
    o: Origin[mut=False]
](ref [o] batch: RecordBatch) -> BatchView[o]:
    """Module-level factory: the `BatchView.over(batch)` entry point.

    Free function rather than a struct @staticmethod because Mojo 1.0.0b1
    cannot infer the parent struct's `origin` parameter from a
    @staticmethod's ref-parameter (verified empirically: the
    @staticmethod form fails to invoke with "failed to infer
    parameter '_mlir_origin' of parent struct"). The free function
    is the documented workaround pattern and produces byte-identical
    codegen to the equivalent direct ctor call.

    Usage at the engine seam:
        var bv = batch_view_over(batch)
        for var i in range(0, bv.n_rows(), W):
            var lane = bv.col_i64(0).load[W](i)
            ...
    """
    return BatchView[o](batch)

