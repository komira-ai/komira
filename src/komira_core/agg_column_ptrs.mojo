# =============================================================================
# TypedColumnPtrs -- classified per-agg value column pointers
# =============================================================================
#
# Stores three parallel typed pointer arrays (f64/i64/i32) with a per-lane
# kind code and column offset. Built once per batch via `from_batch_padded`.
#
# TypedColumnPtrs owns the lane storage AND does the Column classification,
# so no UnsafePointer appears in any constructor or public method parameter.
#
# PUBLIC API BOUNDARY:
#   TypedColumnPtrs.from_batch_padded() takes RecordBatch + AggExprArray
#   and returns a fully classified TypedColumnPtrs. No UnsafePointer in
#   any constructor or public method parameter. Internal hot-path methods
#   prefixed with `_` return UnsafePointer for zero-overhead row dispatch.
#
# SAFETY: UnsafePointer is used INTERNALLY in struct fields because:
#   1. Caching the base address avoids per-row Column->buffer->ptr
#      indirection in the 6M-row inner loop.
#   2. Mojo has no stored refs or Arc for cheap Column sharing.
#   The pointers borrow from Arrow column buffers (via RecordBatch).
#   Callers MUST keep the RecordBatch alive for this struct's lifetime.
#
# Value columns are classified into typed per-agg lanes once per batch.
# =============================================================================

# =============================================================================
# PARAMETERIZED ON THE BATCH ORIGIN
# =============================================================================
# The struct is parameterized on `batch_origin: Origin`, which is the origin
# of the source `RecordBatch` whose column buffers the typed pointers borrow
# from. All three pointer lists (_f64, _i64, _i32) carry `batch_origin` as
# their element's origin, anchoring them to a named, concrete lifetime.
#
# The fields store
#   List[UnsafePointer[Scalar[T], Self.batch_origin]]
# — a single, named origin shared across all pointers in the struct. A
# wildcard origin here would defeat ASAP-destruction tracking.
#
# Rust/C++ parity: DataFusion's `intern(cols: &[ArrayRef])` and DuckDB's
# `AddChunk(DataChunk& payload)` both use ONE parent lifetime for the
# whole column set. That's the same shape here.
#
# Origin inference at callsites: the `batch_origin` parameter is inferred
# from the `ref [batch_origin] batch: RecordBatch` argument to
# `from_batch_padded` via Mojo parameter inference. Local callers
# writing `var vp = TypedColumnPtrs.from_batch_padded(input_batch, ...)`
# do not need to spell the origin — the compiler resolves it from the
# first argument.
#
# Perf: origin parameters erase at codegen; no runtime impact.
# =============================================================================

from std.memory import UnsafePointer

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.schema import RecordBatch

from komira_core.helpers.compiler_helpers import resolve_col_index
from komira_core.plan.logical_plan import AggExprArray


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a CONCRETE origin (Mojo no longer
    provides an `UnsafePointer[T, o]()` null constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (Mojo's non-null pointer design); `None` is
    # the all-zero (NULL) bit pattern. The origin `o` is the caller's
    # concrete origin (here `Self.batch_origin` — NOT a wildcard). These
    # NULL pointers are unused placeholder lane entries; the LANE_KIND tag
    # gates whether they are ever dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# Kind codes for dtype classification.
# Values are stable — hot loops compare against these constants directly.
comptime LANE_KIND_NONE: UInt8 = 0   # No value column (e.g. COUNT(*))
comptime LANE_KIND_F64: UInt8 = 1    # Float64 value column
comptime LANE_KIND_I32: UInt8 = 2    # Int32 value column
comptime LANE_KIND_I64: UInt8 = 3    # Int64 value column

# Agg-specific aliases.
# The aggregation hot loops use `AGG_KIND_*` constants — these are numerically
# identical to the generic `LANE_KIND_*` constants.
comptime AGG_KIND_COUNT: UInt8 = LANE_KIND_NONE  # 0
comptime AGG_KIND_F64: UInt8 = LANE_KIND_F64     # 1
comptime AGG_KIND_I32: UInt8 = LANE_KIND_I32     # 2
comptime AGG_KIND_I64: UInt8 = LANE_KIND_I64     # 3


# =============================================================================
# ValidityLanes — the per-lane VALIDITY channel
# =============================================================================
#
# The hot agg loops read value columns through a base pointer + row index.
# That is a VALUES-ONLY channel: an Arrow column's second buffer, the validity
# bitmap, has no way through it. Without this channel `COUNT(DISTINCT c)`
# would insert the DATA WORD OF A NULL ROW (unspecified in Arrow) into the
# distinct set as if it were a value.
#
# This is that input, in the shape the value pointers already have: one lane
# per agg slot, borrowed from the same parent batch under the same named
# origin, with no `UnsafePointer` in any public signature.
#
# ⚠ THE PRESENCE GATE IS `_validity`, NOT `_null_count > 0`. A stale zero in
#   `_null_count` over a bitmap that really does hold zeros would make this
#   channel report "no nulls" and hand back the old wrong answer; the reverse
#   error (a bitmap of all-ones) costs one predictable branch per row and
#   cannot change an answer. `ColView.is_null` — the canonical reader — gates
#   the same way, so the two cannot disagree about what a NULL is.
#
# ⚠ THE BIT INDEX IS `column._offset + row`, THE SAME `_offset` the VALUES
#   pointer is advanced by. A sliced column carries one offset for both
#   buffers; reading validity at a bare `row` on a sliced column silently
#   answers about a different row.
# =============================================================================


struct ValidityLanes[batch_origin: Origin](Movable):
    """Per-lane Arrow validity-bitmap borrows, parallel to a lane's values.

    Parameters:
        batch_origin: Origin of the source `RecordBatch` whose validity
            buffers these pointers borrow from — the same named origin the
            value pointers in `TypedColumnPtrs` carry, so the two channels
            cannot outlive each other or the batch.

    Ownership: the bitmap pointers are borrowed from the `RecordBatch` passed
    to the push methods. Callers MUST keep that batch alive for as long as
    this struct is in use — the standard "build at function top, keepalive at
    function end" pattern satisfies it, exactly as for `TypedColumnPtrs`.

    SAFETY: `UnsafePointer` is used in the private fields for the same reason
    the value channel does — one cached base address instead of a
    Column -> Optional -> Bitmap -> buffer chase per row. No `UnsafePointer`
    crosses this struct's public surface: the only reader is `is_null_at`,
    which takes two `Int`s and returns a `Bool`.
    """

    # SAFETY: raw bytes of each lane's Arrow validity bitmap, borrowed from a
    # RecordBatch whose origin is `Self.batch_origin`. A lane with no bitmap
    # stores the NULL sentinel and is gated by `_present[lane] == False`, so
    # the sentinel is never dereferenced.
    var _bits: List[UnsafePointer[UInt8, Self.batch_origin]]
    # Per-lane bit offset — the column's `_offset` (slice start).
    var _bit_offset: List[Int]
    # Per-lane: does this lane HAVE a validity bitmap at all?
    var _present: List[Bool]
    # True iff at least one lane has a bitmap. Lets a hot loop hoist the
    # whole check out when the input is non-nullable, which is the common case.
    var _any: Bool

    def __init__(out self):
        """Create an empty ValidityLanes with no lanes."""
        self._bits = List[UnsafePointer[UInt8, Self.batch_origin]]()
        self._bit_offset = List[Int]()
        self._present = List[Bool]()
        self._any = False

    def push_absent(mut self):
        """Add a lane with NO validity bitmap (a non-nullable column, or a
        lane with no value column at all such as `COUNT(*)`)."""
        self._bits.append(_null_ptr[UInt8, Self.batch_origin]())
        self._bit_offset.append(0)
        self._present.append(False)

    def push_column(mut self, batch: RecordBatch, col_index: Int) raises:
        """Add a lane borrowing column `col_index`'s validity bitmap.

        Falls back to `push_absent` when the column carries no bitmap. Takes
        the batch and an index rather than a Column or a pointer, so the
        buffer extraction stays inside this struct.
        """
        ref vp = batch.column_at(col_index)
        if not vp._validity:
            self.push_absent()
            return
        # SAFETY: the Bitmap's buffer is owned (transitively) by `batch`,
        # whose origin is `Self.batch_origin`. `view_ro()._unsafe_ptr()`
        # yields an immutable-origin `UnsafePointer[UInt8, ...]`; the
        # `unsafe_mut_cast` + `unsafe_origin_cast` tail re-tags it to the
        # struct's named parent origin so it can live in the field List —
        # the identical widening the value channel performs in
        # `from_batch_padded`, and NOT a wildcard (`Self.batch_origin` is a
        # concrete caller-supplied parameter).
        self._bits.append(
            vp._validity.value().buffer.view_ro()
                ._unsafe_ptr()
                .unsafe_mut_cast[Self.batch_origin.mut]()
                .unsafe_origin_cast[Self.batch_origin]()
        )
        self._bit_offset.append(vp._offset)
        self._present.append(True)
        self._any = True

    @staticmethod
    def from_batch_columns(
        batch: RecordBatch, col_indices: List[Int]
    ) raises -> ValidityLanes[Self.batch_origin]:
        """Build one lane per entry of `col_indices`. A NEGATIVE index means
        "this lane has no value column" and produces an absent lane.

        CALL SITE: spell the origin via
        `ValidityLanes[origin_of(batch)].from_batch_columns(batch, idxs)`.
        """
        var v = ValidityLanes[Self.batch_origin]()
        for i in range(len(col_indices)):
            if col_indices[i] < 0:
                v.push_absent()
            else:
                v.push_column(batch, col_indices[i])
        return v^

    @always_inline
    def __len__(self) -> Int:
        """Number of lanes."""
        return len(self._present)

    @always_inline
    def any_nullable(self) -> Bool:
        """True iff ANY lane carries a validity bitmap. A caller with a
        null-free input can branch on this once instead of per row."""
        return self._any

    @always_inline
    def lane_is_nullable(self, lane: Int) -> Bool:
        """True iff `lane` carries a validity bitmap."""
        return self._present[lane]

    @always_inline
    def is_null_at(self, lane: Int, row: Int) -> Bool:
        """True iff element `row` of `lane`'s column is SQL NULL.

        A lane with no bitmap is never null — that is the Arrow no-null fast
        path, not a guess. LSB-first bit order, offset-aware; the same unpack
        `ColView.is_null` and `PrimitiveArray.is_null` perform.
        """
        if not self._present[lane]:
            return False
        var bit_idx = self._bit_offset[lane] + row
        # SAFETY: `_present[lane]` is True, so `_bits[lane]` is a real bitmap
        # base borrowed from the still-live parent batch; `bit_idx >> 3` is
        # within the bitmap because the caller indexes rows of that same
        # column.
        var byte = (self._bits[lane] + (bit_idx >> 3))[]
        return ((byte >> UInt8(bit_idx & 7)) & UInt8(1)) == UInt8(0)


struct TypedColumnPtrs[batch_origin: Origin](Movable, Sized):
    """Per-lane classified typed base pointers for agg value columns.

    Stores three parallel Lists of typed UnsafePointers (f64/i64/i32) plus
    a per-lane kind code and column offset — all indexed by lane index.
    Non-matching types hold null sentinels.

    Built once per batch via `from_batch_padded`. Pointer extraction from
    Column objects is fully encapsulated — no UnsafePointer in any
    constructor or public method parameter.

    Parameters:
        batch_origin: Origin of the source RecordBatch whose column
            buffers these pointers borrow from. All three typed pointer
            lists share this single, named origin — every pointer in this
            struct borrows from the same parent batch, matching
            DataFusion's `&[ArrayRef]` and DuckDB's `DataChunk&` shape. A
            wildcard origin here would disable ASAP-destruction tracking.

    Ownership: the base pointers are borrowed from the `RecordBatch`
    passed to `from_batch_padded`. Callers MUST keep that batch alive
    for as long as any TypedColumnPtrs derived from it is in use. The
    standard pattern — build at function top, keepalive at function end —
    satisfies this.

    SAFETY: UnsafePointer is used in struct fields because:
    1. Caching the base address avoids per-row Column->buffer->ptr
       indirection in the 6M-row inner loop.
    2. Mojo has no stored refs or Arc for cheap Column sharing.
    """

    # SAFETY: These Lists store base pointers extracted from Arrow column
    # data buffers (MmapAlignedBuffer._unsafe_data_ptr().bitcast[T]()). They
    # borrow from the RecordBatch's column storage; all three lists share
    # `batch_origin`, the single parent origin of that batch. The
    # RecordBatch must outlive this TypedColumnPtrs. Null sentinels
    # (default UnsafePointer()) fill non-matching type slots.
    var _f64: List[UnsafePointer[Scalar[DType.float64], Self.batch_origin]]
    var _i64: List[UnsafePointer[Scalar[DType.int64], Self.batch_origin]]
    var _i32: List[UnsafePointer[Scalar[DType.int32], Self.batch_origin]]

    # Per-lane: kind code (LANE_KIND_*), column buffer offset.
    var _kind: List[UInt8]
    var _offset: List[Int]

    # THE VALIDITY CHANNEL.
    # Kept INSIDE this struct rather than beside it at every call site: the
    # value pointers and the validity bits describe the SAME lane of the SAME
    # column under the SAME parent origin, so a caller cannot carry one and
    # forget the other. A
    # consumer that stores a `TypedColumnPtrs` in dispatch State (the parallel
    # COUNT(DISTINCT) driver does) therefore gets validity into its workers
    # with no new State field and no new constructor parameter.
    var _valid: ValidityLanes[Self.batch_origin]

    def __init__(out self):
        """Create an empty TypedColumnPtrs with no lanes."""
        self._f64 = List[UnsafePointer[Scalar[DType.float64], Self.batch_origin]]()
        self._i64 = List[UnsafePointer[Scalar[DType.int64], Self.batch_origin]]()
        self._i32 = List[UnsafePointer[Scalar[DType.int32], Self.batch_origin]]()
        self._kind = List[UInt8]()
        self._offset = List[Int]()
        self._valid = ValidityLanes[Self.batch_origin]()

    def __init__(out self, capacity: Int):
        """Create a TypedColumnPtrs with pre-allocated capacity.

        Args:
            capacity: Expected number of lanes. Avoids reallocation during
                classify calls.
        """
        self._f64 = List[UnsafePointer[Scalar[DType.float64], Self.batch_origin]](capacity=capacity)
        self._i64 = List[UnsafePointer[Scalar[DType.int64], Self.batch_origin]](capacity=capacity)
        self._i32 = List[UnsafePointer[Scalar[DType.int32], Self.batch_origin]](capacity=capacity)
        self._kind = List[UInt8](capacity=capacity)
        self._offset = List[Int](capacity=capacity)
        self._valid = ValidityLanes[Self.batch_origin]()

    # =========================================================================
    # Construction from RecordBatch (public entry point)
    # =========================================================================

    @staticmethod
    def from_batch_padded(
        batch: RecordBatch,
        agg_exprs: AggExprArray,
        num_aggs: Int,
    ) raises -> TypedColumnPtrs[Self.batch_origin]:
        """Classify each agg lane into a typed bucket, padding with nulls.

        For each agg, this:
          1. Resolves the value column index from `agg_exprs[a].child`
             (or pushes a count-only lane if there's no child).
          2. Reads the Column's ArrowType and data buffer, extracts the
             typed pointer internally, and pushes it into the appropriate lane.

        No UnsafePointer crosses this method's boundary — all pointer
        extraction from Column buffers happens inside the classify
        dispatch.

        CALL SITE: spell the origin via `TypedColumnPtrs[origin_of(
        batch)].from_batch_padded(batch, ...)` or rely on inference
        when the struct parameter `batch_origin` is already bound
        (e.g. from a method return-type annotation).

        Aggregation result: `ptrs._f64_ptr(a)` is the base pointer for a
        Float64 value column at lane `a` iff `ptrs.kind_at(a) ==
        AGG_KIND_F64`; otherwise it is a null sentinel. The caller
        indexes by row: `(ptrs._f64_ptr(a) + ptrs.offset_at(a) + row)[]`.
        """
        var plan = TypedColumnPtrs[Self.batch_origin](num_aggs)

        for a in range(num_aggs):
            if agg_exprs[a].child:
                var vi = resolve_col_index(
                    agg_exprs[a].child.value(), batch.schema
                )
                # The column-dispatch/append logic is inlined here
                # (rather than hoisted into a `mut self` helper method)
                # because Mojo's aliasing checker rejects any mut-self call
                # whose argument carries the same origin as a field the
                # method writes. With the struct now parameterized on
                # `batch_origin`, both `plan` (mut receiver) and any
                # `ref vp = batch.column_at(vi)` would share `batch_origin`
                # — triggering the rejection. Inline classification
                # sidesteps the extra call boundary.
                ref vp = batch.column_at(vi)
                var vat = vp.arrow_type
                var offset = vp._offset
                # The validity lane is pushed on EVERY arm of
                # the classification below, so `_valid` is index-parallel with
                # `_kind` by construction rather than by three arms remembering
                # to. Pushed HERE, before the type dispatch, for exactly that
                # reason.
                plan._valid.push_column(batch, vi)
                # SAFETY: the MmapAlignedBuffer is owned (transitively) by
                # `batch`, which has origin `Self.batch_origin`. Re-tagging
                # the extracted pointer with `Self.batch_origin` via
                # `unsafe_origin_cast` is sound — the pointer lives as
                # long as the batch.
                # The Column data pointer is mutable-origin. `Self.batch_origin` on the other hand is
                # `Origin` (mut-polymorphic) — struct callers may pass
                # either a mut or immut origin depending on whether the
                # caller's `batch` parameter was declared with `mut` or not
                # (most `def` callers produce `ImmutOrigin`). We bridge by
                # first downgrading mut via `unsafe_mut_cast[is_mutable(
                # Self.batch_origin)]`, then `unsafe_origin_cast` to the
                # actual `Self.batch_origin`. This works for both sides of
                # the mut/immut split. SAFETY: the pointer lives as long
                # as the RecordBatch owns the buffer, which outlives the
                # TypedColumnPtrs.
                # Tight-origin typed read: `view_ro()._unsafe_ptr()` on a
                # uint8 buffer returns `UnsafePointer[UInt8, origin]`
                # directly; the per-arm `bitcast[Scalar[T]]` narrows to the
                # lane's scalar type. The widening tail
                # `.unsafe_mut_cast[Self.batch_origin.mut]()
                # .unsafe_origin_cast[Self.batch_origin]()` on each per-arm
                # append is required for
                # `List[UnsafePointer[..., Self.batch_origin]]` storage.
                var base_view = vp._data.view_ro()
                var base_u8 = base_view._unsafe_ptr()
                if vat == ArrowType.FLOAT64:
                    plan._kind.append(LANE_KIND_F64)
                    plan._offset.append(offset)
                    plan._f64.append(
                        base_u8.bitcast[Scalar[DType.float64]]()
                            .unsafe_mut_cast[Self.batch_origin.mut]()
                            .unsafe_origin_cast[Self.batch_origin]()
                    )
                    plan._i64.append(_null_ptr[Scalar[DType.int64], Self.batch_origin]())
                    plan._i32.append(_null_ptr[Scalar[DType.int32], Self.batch_origin]())
                elif vat == ArrowType.INT32:
                    plan._kind.append(LANE_KIND_I32)
                    plan._offset.append(offset)
                    plan._f64.append(_null_ptr[Scalar[DType.float64], Self.batch_origin]())
                    plan._i64.append(_null_ptr[Scalar[DType.int64], Self.batch_origin]())
                    plan._i32.append(
                        base_u8.bitcast[Scalar[DType.int32]]()
                            .unsafe_mut_cast[Self.batch_origin.mut]()
                            .unsafe_origin_cast[Self.batch_origin]()
                    )
                else:
                    # INT64 or any other int-family we treat as i64.
                    plan._kind.append(LANE_KIND_I64)
                    plan._offset.append(offset)
                    plan._f64.append(_null_ptr[Scalar[DType.float64], Self.batch_origin]())
                    plan._i64.append(
                        base_u8.bitcast[Scalar[DType.int64]]()
                            .unsafe_mut_cast[Self.batch_origin.mut]()
                            .unsafe_origin_cast[Self.batch_origin]()
                    )
                    plan._i32.append(_null_ptr[Scalar[DType.int32], Self.batch_origin]())
            else:
                # COUNT(*): no column.
                plan.classify_none()

        return plan^

    # =========================================================================
    # Classification methods
    # =========================================================================

    def classify_none(mut self):
        """Add a lane with no value column (e.g. COUNT(*)).

        This is safe to call from any context — it takes no pointers.
        """
        self._kind.append(LANE_KIND_NONE)
        self._offset.append(0)
        self._f64.append(_null_ptr[Scalar[DType.float64], Self.batch_origin]())
        self._i64.append(_null_ptr[Scalar[DType.int64], Self.batch_origin]())
        self._i32.append(_null_ptr[Scalar[DType.int32], Self.batch_origin]())
        # A lane with no value column (COUNT(*)) has no validity either — the
        # lane must still be PUSHED so `_valid` stays index-parallel with
        # `_kind`. A channel that silently shortens is worse than no channel:
        # every lane after it would read another column's bits.
        self._valid.push_absent()

    # =========================================================================
    # Safe accessors — bounds-checked, suitable for cold paths
    # =========================================================================

    @always_inline
    def __len__(self) -> Int:
        """Number of classified lanes."""
        return len(self._kind)

    @always_inline
    def kind_at(self, lane: Int) -> UInt8:
        """Read the dispatch kind for a given agg lane."""
        return self._kind[lane]

    @always_inline
    def offset_at(self, lane: Int) -> Int:
        """Column buffer offset to add to the base pointer for this lane."""
        return self._offset[lane]

    @always_inline
    def is_null_at(self, lane: Int, row: Int) -> Bool:
        """True iff element `row` of lane `lane`'s value column is SQL NULL.

        The companion of `_f64_ptr`/`_i64_ptr`/`_i32_ptr`: any
        loop that reads a lane's VALUE at `row` must ask this before treating
        that value as data. A lane over a non-nullable column answers False
        through one `List[Bool]` load and no bitmap read.
        """
        return self._valid.is_null_at(lane, row)

    @always_inline
    def any_nullable(self) -> Bool:
        """True iff ANY lane's value column carries a validity bitmap."""
        return self._valid.any_nullable()

    @always_inline
    def _f64_ptr(self, lane: Int) -> UnsafePointer[Scalar[DType.float64], Self.batch_origin]:
        """[MODULE-INTERNAL] Float64 base pointer for a lane. Null sentinel
        if the lane is not a Float64 value column."""
        return self._f64[lane]

    @always_inline
    def _i64_ptr(self, lane: Int) -> UnsafePointer[Scalar[DType.int64], Self.batch_origin]:
        """[MODULE-INTERNAL] Int64 base pointer for a lane."""
        return self._i64[lane]

    @always_inline
    def _i32_ptr(self, lane: Int) -> UnsafePointer[Scalar[DType.int32], Self.batch_origin]:
        """[MODULE-INTERNAL] Int32 base pointer for a lane."""
        return self._i32[lane]

    # =========================================================================
    # PERF-CRITICAL: raw backing-pointer extraction for hot loops
    # =========================================================================
    # The safe accessors above go through `List[T][lane]`, which compiles to
    # a bounds-checked load. At 6M rows * num_lanes dispatches, removing
    # those comparisons is material. Hot-loop callers should extract raw
    # pointers once outside the row loop:
    #
    #     var kind_p = val_ptrs._unsafe_kind_ptr()
    #     var f64_p  = val_ptrs._unsafe_f64_ptr()
    #     ...
    #     for row in range(num_rows):
    #         for a in range(num_lanes):
    #             var d = (kind_p + a)[]
    #             if d == AGG_KIND_F64:
    #                 ... ((f64_p + a)[] + row)[] ...
    #
    # The raw pointers are valid for as long as the TypedColumnPtrs is alive.
    # Callers MUST keepalive the TypedColumnPtrs (e.g. `_ = val_ptrs^`), not
    # just the raw pointers.
    #
    # The INNER element type of `_unsafe_f64_ptr` / `_unsafe_i64_ptr`
    # / `_unsafe_i32_ptr` is `UnsafePointer[Scalar[T], Self.batch_origin]`
    # (a named origin, not a wildcard). Downstream scatter / SIMD kernels
    # consume the inner origin via their own origin parameters.
    # =========================================================================

    @always_inline
    def _unsafe_kind_ptr(self) -> UnsafePointer[UInt8, origin_of(self._kind)]:
        """[MODULE-INTERNAL] Raw pointer to kind-code backing storage."""
        return self._kind.unsafe_ptr()

    @always_inline
    def _unsafe_f64_ptr(
        self,
    ) -> UnsafePointer[
        UnsafePointer[Scalar[DType.float64], Self.batch_origin],
        origin_of(self._f64),
    ]:
        """[MODULE-INTERNAL] Raw pointer to f64 pointer backing storage."""
        return self._f64.unsafe_ptr()

    @always_inline
    def _unsafe_i64_ptr(
        self,
    ) -> UnsafePointer[
        UnsafePointer[Scalar[DType.int64], Self.batch_origin],
        origin_of(self._i64),
    ]:
        """[MODULE-INTERNAL] Raw pointer to i64 pointer backing storage."""
        return self._i64.unsafe_ptr()

    @always_inline
    def _unsafe_i32_ptr(
        self,
    ) -> UnsafePointer[
        UnsafePointer[Scalar[DType.int32], Self.batch_origin],
        origin_of(self._i32),
    ]:
        """[MODULE-INTERNAL] Raw pointer to i32 pointer backing storage."""
        return self._i32.unsafe_ptr()

    @always_inline
    def _unsafe_offset_ptr(self) -> UnsafePointer[Int, origin_of(self._offset)]:
        """[MODULE-INTERNAL] Raw pointer to offset backing storage."""
        return self._offset.unsafe_ptr()
