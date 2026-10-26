# =============================================================================
# AggCommitPlan -- the per-row accumulator dispatch shared by every agg path
# =============================================================================
#
# The "update every accumulator for this row" step of hash aggregation. A
# per-row loop `for a in range(num_aggs): if type_code == ... elif ...`
# mispredicts, because the value type varies across aggregates (48M
# mispredicts per pass over 6M rows of 8 aggregates). Instead the aggregates
# are classified ONCE per batch into four typed buckets (count-only / f64 /
# i64 / i32), and each commit runs one tight sub-loop per bucket with no
# per-row type dispatch -- the shape of a columnar accumulator's
# `update_batch`, which dispatches by aggregate type once per batch.
#
# The commit forms: `commit_row` (one row into a FlatHashAggregator entry),
# `commit_row_ph` (one row into a PerfectHashAggregator slot), and the
# loop-transposed `commit_batch`, `commit_batch_partitioned` and
# `commit_batch_indexed` (bodies in agg_commit_batch.mojo).
#
# Storage: ten per-bucket views alias exactly two backing heap blocks
# (`_int_root` and `_ptr_root`); ten blocks (one per bucket) would undo the
# measured layout win. The view pointers never leave this package: they are
# written by `build_agg_commit_plan*` and read by the commits.
#
# Invariants (tests/test_agg_commit_view_bounds.mojo and
# tests/test_agg_commit_double_free.mojo hold them):
#   I1. Every view lies inside its backing root (bounds-safe).
#   I2. No two views overlap (disjoint slices).
#   I3. View slices tile the root exactly (no gap, no slack).
#   I4. Move semantics transfer root ownership; no double-free.
#   I5. Bucket counters (n_count, n_f64, n_i64, n_i32) start at zero and
#       never exceed `num_aggs` (the build-time capacity).
# =============================================================================

from std.collections import Array
from std.memory import UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab

from .flat_hash_agg import FlatHashAggregator, EntryHandle
from .flat_hash_agg_perfect import PerfectHashAggregator
from .partitioned_flat_hash_agg import PartitionedFlatHashAggregator
from komira_column_kernels.compiler_helpers import resolve_col_index

from komira_physical_plan.physical_plan import AggSinkData
from komira_plan_expr.agg_expr import AGG_COUNT
from komira_agg_api.agg_layout import (
    AggLayout,
    MAX_AGGS,
    ACC_TAG_INVALID,
    ACC_COUNT_STAR,
    ACC_SUM_COUNT_MIN_MAX_F64,
)
from komira_op_agg_state.accumulator_set import (
    AosRowThunk,
    resolve_row_thunk,
)


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin, to fill the inactive
    slots of the plan's validity-pointer array.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer; `None` is the all-zero NULL bit pattern. The origin `o`
    # is the caller's (here `Self.batch_origin`). The slots are gated by
    # `n_count_validity` and never read while NULL.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# Rows per chunk of the chunk-major batch commits (agg_commit_batch.mojo):
# 256 entry pointers are 2 KB, which fits in L1 beside the per-bucket
# thunk tables.
comptime COMMIT_CHUNK: Int = 256


@always_inline
def _thunk_call[
    o: Origin[mut=True]
](
    thunk: AosRowThunk,
    entry_ptr: UnsafePointer[UInt8, o],
    entry_stride: Int,
    slot_off: Int,
    value: Float64,
):
    """Run a resolved row thunk on the entry at `entry_ptr`."""
    # SAFETY: `entry_ptr` points at a whole entry (`entry_stride` bytes) of
    # an aggregator the caller borrows mutably, with that buffer's origin;
    # the span lives for this call only.
    thunk.call(
        Span[UInt8, o](unsafe_ptr=entry_ptr, length=entry_stride),
        slot_off,
        value,
    )


# =============================================================================
# AggCommitPlan -- classified per-agg commit vectors
# =============================================================================
#
# Four parallel arrays per type bucket: each bucket stores a flat list of
# (agg_idx, col_ptr, offset) triples, and the commit walks each bucket in
# turn. Because a bucket holds only one type, the per-row loop has no
# branches on type.
#
# Lifetime: the plan owns its storage. The column pointers point into the
# input RecordBatch and carry its origin, so the batch outlives every use.
# =============================================================================


struct AggCommitPlan[batch_origin: ImmOrigin](Movable):
    """Pre-classified per-agg commit vectors (one bucket per value type).

    Built once per batch, then driven by `commit_row` / `commit_batch*` for
    the batch's rows. Each bucket holds only one type of agg, so the
    per-row sub-loops are branch-free straight-line code.

    Parametric on `batch_origin`: the value-column pointers (`_f64_ptrs` /
    `_i64_ptrs` / `_i32_ptrs`) and the validity-bitmap pointers
    (`count_validity_ptrs`) alias INTO the input RecordBatch's column
    buffers and carry the batch's origin, so the compiler keeps the batch
    alive through the plan. (With a wildcard origin the batch could be
    destroyed while a commit still read its buffers.) The aggregator entry
    pointers are resolved afresh from the aggregator in each commit and
    carry its origin.

    Storage: two heap blocks -- one Int block of `7 * num_aggs` Ints
    (seven bucket sub-arrays of length `num_aggs` each) and one pointer
    block of `3 * num_aggs` type-erased pointer slots. Layout:
    `[count_idxs][f64_idxs][f64_offs][i64_idxs][i64_offs][i32_idxs][i32_offs]`
    then the pointer alloc is just
    `[f64_ptrs ..][i64_ptrs ..][i32_ptrs ..]` cast to bytes and re-cast on
    access.
    """

    # Bucket counts (written at build time, read per row).
    # SAFETY I5: monotonically non-decreasing via `_push_*` helpers; never
    # exceed the `num_aggs` capacity fixed at construction time. The
    # per-row commit loops use these as range bounds; if they exceeded
    # `num_aggs`, the corresponding `_idxs`/`_ptrs`/`_offs` view would
    # overrun its slice.
    var n_count: Int
    var n_f64: Int
    var n_i64: Int
    var n_i32: Int
    # Validity-aware bucket for SQL-standard `COUNT(col)` over a nullable
    # column. `build_agg_commit_plan*` routes an agg here when
    # `agg.func == AGG_COUNT && agg.child && col._null_count > 0`; otherwise
    # the i32/i64/f64 buckets apply (their thunks increment count
    # unconditionally, which is correct ONLY for non-null columns or
    # COUNT(*)).
    # Its commits increment the count slot only when the validity bit is
    # set.
    var n_count_validity: Int

    # -------------------------------------------------------------------------
    # `num_aggs` stride (per-bucket capacity, fixed at construction time).
    # Each of the 7 Int views and 3 pointer views has length `_num_aggs`
    # slots. Views are derived on demand via `_int_view_ptr(j)` /
    # `_f64_ptrs` / `_i64_ptrs` / `_i32_ptrs` using this stride.
    # -------------------------------------------------------------------------
    var _num_aggs: Int

    # -------------------------------------------------------------------------
    # The per-bucket views are private `@always_inline` accessors that
    # derive pointers from the two Slab roots below; no pointer is stored
    # as a field.
    #
    # SAFETY (invariants I1 / I2 / I3):
    #   - Each accessor returns a pointer inside `[root, root + stride)`.
    #   - Views are pairwise disjoint by construction (adjacent slices).
    #   - Views tile the root exactly (verified by view_bounds tests).
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # Per-slot row-thunk dispatch (a monomorphic kernel per tag).
    # -------------------------------------------------------------------------
    #
    # PERF-CRITICAL: `agg._update_agg(entry, agg_idx, value)` loads
    # `agg._layout.tags[agg_idx]` per call and dispatches on it per row;
    # with narrow slots that dispatch outweighed the 16B-vs-32B memory
    # savings. Instead each slot's tag is resolved to a row thunk at plan
    # time (`bind_layout`), with the byte offset of the slot
    # within an entry (`aggs_offset + layout.offsets[agg_idx]`), both in
    # parallel per-bucket InlineArrays; `commit_row` then calls the
    # pre-bound thunk with no per-row tag work.
    #
    # Per-bucket parallel arrays (same ordering as `*_agg_idxs`):
    #   - `*_thunks[j]`       -- the kernel of the j-th agg in this bucket
    #   - `*_slot_offsets[j]` -- byte offset of that slot within an entry
    #
    # For COUNT(*) slots the thunk is the count-only kernel and the value
    # column is irrelevant; the slot offset is still stored because the
    # slot lives inside an entry.
    #
    # Storage: `InlineArray[T, MAX_AGGS]` (NOT `List[T]`): the elements
    # live inline in `AggCommitPlan` itself, with no separate heap buffer
    # whose lifetime the compiler would have to chain through the plan.
    # MAX_AGGS is the same cap AggLayout uses.
    # Only the first `n_count` / `n_f64` / `n_i64` / `n_i32` entries are
    # meaningful; the remainder are zero-/default-initialised.
    # -------------------------------------------------------------------------
    var count_thunks: Array[AosRowThunk, MAX_AGGS]
    var count_slot_offsets: Array[Int, MAX_AGGS]
    var f64_thunks: Array[AosRowThunk, MAX_AGGS]
    var f64_slot_offsets: Array[Int, MAX_AGGS]
    var i64_thunks: Array[AosRowThunk, MAX_AGGS]
    var i64_slot_offsets: Array[Int, MAX_AGGS]
    var i32_thunks: Array[AosRowThunk, MAX_AGGS]
    var i32_slot_offsets: Array[Int, MAX_AGGS]

    # -------------------------------------------------------------------------
    # Per-slot AccTag, parallel to the *_thunks / *_slot_offsets arrays
    # above. Populated by `bind_layout` (the same `layout.slot_tag(a)` it
    # computes to resolve the thunk).
    #
    # PURPOSE: devirtualize the batch commits' inner loops. The stored
    # thunk is an indirect call the compiler cannot inline (for COUNT(*)
    # it hides a 1-cycle `count += 1`); with the tag, `commit_batch*`
    # hoists a per-SLOT tag check out of the row loop and runs an inlined
    # loop for the dominant tags, keeping the thunk for rare ones. Only the
    # first `n_*` entries are meaningful; the rest are ACC_TAG_INVALID.
    # -------------------------------------------------------------------------
    var count_tags: Array[UInt8, MAX_AGGS]
    var f64_tags: Array[UInt8, MAX_AGGS]
    var i64_tags: Array[UInt8, MAX_AGGS]
    var i32_tags: Array[UInt8, MAX_AGGS]

    # -------------------------------------------------------------------------
    # Per-bucket parallel arrays of the `_count_with_validity` bucket, in
    # the InlineArray pattern of the four type buckets.
    #
    # `count_validity_idxs[j]`        — agg_idx for the j-th validity-count
    #                                   slot (used by the
    #                                   `_layout_bound == False` fallback
    #                                   that calls `agg._update_count_only`
    #                                   conditionally on the bit).
    # `count_validity_ptrs[j]`        — pointer to the validity bitmap's
    #                                   underlying byte buffer (Bitmap's
    #                                   MmapAlignedBuffer base).
    # `count_validity_bit_offsets[j]` — `column._offset` (the column's
    #                                   logical-bit offset into the bitmap;
    #                                   for sliced columns this is non-zero).
    #                                   Per-row bit index is
    #                                   `bit_offsets[j] + row`.
    # `count_validity_slot_offsets[j]`— byte offset of the count slot within
    #                                   an entry (= `aggs_offset +
    #                                   layout.slot_offset(agg_idx)`).
    #                                   Set by `bind_layout`.
    #
    # MAX_AGGS mirrors the four type buckets. UnsafePointer is Copyable,
    # so the InlineArray holds the pointers inline.
    # -------------------------------------------------------------------------
    var count_validity_idxs: Array[Int, MAX_AGGS]
    # Validity-bitmap pointers alias the batch's column validity buffers
    # and carry `batch_origin`.
    var count_validity_ptrs: Array[
        UnsafePointer[UInt8, Self.batch_origin], MAX_AGGS
    ]
    var count_validity_bit_offsets: Array[Int, MAX_AGGS]
    var count_validity_slot_offsets: Array[Int, MAX_AGGS]
    # Resolved row thunk for the count slot, as `count_thunks` in the
    # COUNT(*) bucket: the count-only kernel for 8B count slots, the
    # sum+count or quartet kernel when COUNT(col) lands in a wider slot
    # under a layout that mixes SUM+COUNT. The value passed is 0.0: the
    # output of COUNT(col) reads only the count field, and adding 0.0 to
    # the sum changes it only when the sum is NaN.
    var count_validity_thunks: Array[AosRowThunk, MAX_AGGS]

    # True once `bind_layout` has been called. When False, the commits fall
    # back to `agg._update_agg` dispatch (a per-row tag check), which is
    # correct whether the layout is quartet or narrow; a caller that calls
    # `bind_layout` opts in to the fast path.
    var _layout_bound: Bool

    # -------------------------------------------------------------------------
    # PERF-CRITICAL owning root allocations. Exactly TWO heap allocations
    # -- `Slab[Int]` for 7 * num_aggs Int slots, `Slab[UInt8]` for
    # 3 * num_aggs * 8 UInt8 slots -- tile the 7 Int + 3 pointer views.
    # The view accessors return typed pointers into the Slabs, carrying
    # each Slab's origin.
    #
    # SAFETY (invariant I4):
    #   - Heap ownership lives in each Slab's backing `List[UInt8]`.
    #     Slab.__del__ runs after this struct's __del__, which then
    #     auto-frees the bytes. No explicit `free()` call required.
    #   - Move semantics: auto-synth transfers List[UInt8] to dst. No
    #     double-free path exists by construction.
    # -------------------------------------------------------------------------
    var _int_root: Slab[Int]
    var _ptr_root: Slab[UInt8]  # type-erased 8-byte pointer slots

    def __init__(out self, num_aggs: Int):
        """Allocate the Int and pointer blocks in exactly two heap calls.

        The Slab constructor allocates each byte-backed buffer once;
        `set_len_unchecked` makes the slots logically "live" so view
        accessors treat every slot as in-range. For POD T (Int, UInt8)
        `set_len_unchecked` is a pure length bump; no destructors run.
        """
        self.n_count = 0
        self.n_f64 = 0
        self.n_i64 = 0
        self.n_i32 = 0
        self.n_count_validity = 0
        self._num_aggs = num_aggs

        self._int_root = Slab[Int].create(7 * num_aggs)
        if num_aggs > 0:
            self._int_root.set_len_unchecked(7 * num_aggs)

        self._ptr_root = Slab[UInt8].create(3 * num_aggs * 8)
        if num_aggs > 0:
            self._ptr_root.set_len_unchecked(3 * num_aggs * 8)

        # Per-bucket thunk + slot-offset storage, inline. `_push_*` write
        # at index `n_*` and bump the counter; `bind_layout` overwrites
        # the entries with the resolved per-slot thunks once the layout is
        # known. The count-only fill is a harmless default: slots beyond
        # `n_count` / `n_f64` / ... are never read (the commit loops are
        # range-bounded by the bucket counters).
        self.count_thunks = Array[AosRowThunk, MAX_AGGS](
            fill=AosRowThunk(ACC_COUNT_STAR)
        )
        self.count_slot_offsets = Array[Int, MAX_AGGS](fill=0)
        self.f64_thunks = Array[AosRowThunk, MAX_AGGS](
            fill=AosRowThunk(ACC_COUNT_STAR)
        )
        self.f64_slot_offsets = Array[Int, MAX_AGGS](fill=0)
        self.i64_thunks = Array[AosRowThunk, MAX_AGGS](
            fill=AosRowThunk(ACC_COUNT_STAR)
        )
        self.i64_slot_offsets = Array[Int, MAX_AGGS](fill=0)
        self.i32_thunks = Array[AosRowThunk, MAX_AGGS](
            fill=AosRowThunk(ACC_COUNT_STAR)
        )
        self.i32_slot_offsets = Array[Int, MAX_AGGS](fill=0)
        # Per-slot tag arrays. The ACC_TAG_INVALID default is never read:
        # the `_layout_bound == False` path uses `_update_agg` dispatch,
        # and bind_layout sets every tag before arming `_layout_bound`.
        self.count_tags = Array[UInt8, MAX_AGGS](fill=ACC_TAG_INVALID)
        self.f64_tags = Array[UInt8, MAX_AGGS](fill=ACC_TAG_INVALID)
        self.i64_tags = Array[UInt8, MAX_AGGS](fill=ACC_TAG_INVALID)
        self.i32_tags = Array[UInt8, MAX_AGGS](fill=ACC_TAG_INVALID)
        # Validity-aware count(col) bucket. The default fill is harmless:
        # the commit loops are range-bounded by `n_count_validity`.
        self.count_validity_idxs = Array[Int, MAX_AGGS](fill=0)
        self.count_validity_ptrs = Array[
            UnsafePointer[UInt8, Self.batch_origin], MAX_AGGS
        ](fill=_null_ptr[UInt8, Self.batch_origin]())
        self.count_validity_bit_offsets = Array[Int, MAX_AGGS](fill=0)
        self.count_validity_slot_offsets = Array[Int, MAX_AGGS](fill=0)
        self.count_validity_thunks = Array[AosRowThunk, MAX_AGGS](
            fill=AosRowThunk(ACC_COUNT_STAR)
        )
        self._layout_bound = False

    # =========================================================================
    # Private view accessors
    # =========================================================================
    # SAFETY per accessor: the returned pointer carries the origin of the
    # Slab it points into (mutable when the plan is borrowed mutably, as in
    # `_push_*`), and offset arithmetic uses the `_num_aggs` stride fixed
    # at construction.

    @always_inline
    def _int_view_ptr(
        ref self, j: Int
    ) -> UnsafePointer[Int, origin_of(self._int_root)]:
        """Return a pointer to the start of the j-th Int view slice.

        j in 0..7 selects count_agg_idxs / f64_agg_idxs / f64_offsets /
        i64_agg_idxs / i64_offsets / i32_agg_idxs / i32_offsets in that
        order. Returned pointer is `_int_root + j * num_aggs`.
        """
        return self._int_root._unsafe_ptr() + j * self._num_aggs

    # The stored value-column pointers (the INNER pointer in each slot)
    # alias the input batch's column buffers and are typed
    # `[Scalar[T], Self.batch_origin]`; the OUTER pointer indexes the
    # plan's own `_ptr_root` Slab and carries its origin.
    @always_inline
    def _f64_ptrs(
        ref self,
    ) -> UnsafePointer[
        UnsafePointer[Scalar[DType.float64], Self.batch_origin],
        origin_of(self._ptr_root),
    ]:
        """Return a pointer to the start of the f64_ptrs view slice."""
        return (self._ptr_root._unsafe_ptr() + 0 * self._num_aggs * 8).bitcast[
            UnsafePointer[Scalar[DType.float64], Self.batch_origin]
        ]()

    @always_inline
    def _i64_ptrs(
        ref self,
    ) -> UnsafePointer[
        UnsafePointer[Scalar[DType.int64], Self.batch_origin],
        origin_of(self._ptr_root),
    ]:
        """Return a pointer to the start of the i64_ptrs view slice."""
        return (self._ptr_root._unsafe_ptr() + 1 * self._num_aggs * 8).bitcast[
            UnsafePointer[Scalar[DType.int64], Self.batch_origin]
        ]()

    @always_inline
    def _i32_ptrs(
        ref self,
    ) -> UnsafePointer[
        UnsafePointer[Scalar[DType.int32], Self.batch_origin],
        origin_of(self._ptr_root),
    ]:
        """Return a pointer to the start of the i32_ptrs view slice."""
        return (self._ptr_root._unsafe_ptr() + 2 * self._num_aggs * 8).bitcast[
            UnsafePointer[Scalar[DType.int32], Self.batch_origin]
        ]()

    @always_inline
    def _push_count(mut self, agg_idx: Int):
        (self._int_view_ptr(0) + self.n_count)[] = agg_idx  # count_agg_idxs
        # Default thunk + slot_offset at the next bucket index;
        # `bind_layout` overwrites them with the resolved values.
        debug_assert(
            self.n_count < MAX_AGGS,
            "AggCommitPlan.count bucket exceeds MAX_AGGS",
        )
        self.count_thunks[self.n_count] = AosRowThunk(ACC_COUNT_STAR)
        self.count_slot_offsets[self.n_count] = 0
        self.n_count += 1

    @always_inline
    def _push_f64(
        mut self,
        agg_idx: Int,
        ptr: UnsafePointer[Scalar[DType.float64], Self.batch_origin],
        offset: Int,
    ):
        (self._int_view_ptr(1) + self.n_f64)[] = agg_idx  # f64_agg_idxs
        (self._f64_ptrs() + self.n_f64)[] = ptr
        (self._int_view_ptr(2) + self.n_f64)[] = offset  # f64_offsets
        debug_assert(
            self.n_f64 < MAX_AGGS,
            "AggCommitPlan.f64 bucket exceeds MAX_AGGS",
        )
        self.f64_thunks[self.n_f64] = AosRowThunk(ACC_SUM_COUNT_MIN_MAX_F64)
        self.f64_slot_offsets[self.n_f64] = 0
        self.n_f64 += 1

    @always_inline
    def _push_i64(
        mut self,
        agg_idx: Int,
        ptr: UnsafePointer[Scalar[DType.int64], Self.batch_origin],
        offset: Int,
    ):
        (self._int_view_ptr(3) + self.n_i64)[] = agg_idx  # i64_agg_idxs
        (self._i64_ptrs() + self.n_i64)[] = ptr
        (self._int_view_ptr(4) + self.n_i64)[] = offset  # i64_offsets
        debug_assert(
            self.n_i64 < MAX_AGGS,
            "AggCommitPlan.i64 bucket exceeds MAX_AGGS",
        )
        self.i64_thunks[self.n_i64] = AosRowThunk(ACC_SUM_COUNT_MIN_MAX_F64)
        self.i64_slot_offsets[self.n_i64] = 0
        self.n_i64 += 1

    @always_inline
    def _push_i32(
        mut self,
        agg_idx: Int,
        ptr: UnsafePointer[Scalar[DType.int32], Self.batch_origin],
        offset: Int,
    ):
        (self._int_view_ptr(5) + self.n_i32)[] = agg_idx  # i32_agg_idxs
        (self._i32_ptrs() + self.n_i32)[] = ptr
        (self._int_view_ptr(6) + self.n_i32)[] = offset  # i32_offsets
        debug_assert(
            self.n_i32 < MAX_AGGS,
            "AggCommitPlan.i32 bucket exceeds MAX_AGGS",
        )
        self.i32_thunks[self.n_i32] = AosRowThunk(ACC_SUM_COUNT_MIN_MAX_F64)
        self.i32_slot_offsets[self.n_i32] = 0
        self.n_i32 += 1

    @always_inline
    def _push_count_with_validity(
        mut self,
        agg_idx: Int,
        validity_ptr: UnsafePointer[UInt8, Self.batch_origin],
        validity_bit_offset: Int,
    ):
        """Record a `count(col)` agg whose source column has nulls
        (`col._null_count > 0`).

        Per-row commit loops consult the validity bitmap and increment the
        count slot only when the bit is set. The slot offset within an
        entry is filled in by `bind_layout`, as for the four type
        buckets.

        Args:
            agg_idx: Aggregate index in the AggSinkData.agg_exprs list.
            validity_ptr: Pointer to the validity bitmap's underlying byte
                buffer, with the batch's origin.
            validity_bit_offset: The column's `_offset` field — the
                logical-bit offset into the bitmap where this column's
                rows start. For non-sliced columns this is 0.
        """
        debug_assert(
            self.n_count_validity < MAX_AGGS,
            "AggCommitPlan.count_validity bucket exceeds MAX_AGGS",
        )
        self.count_validity_idxs[self.n_count_validity] = agg_idx
        self.count_validity_ptrs[self.n_count_validity] = validity_ptr
        self.count_validity_bit_offsets[self.n_count_validity] = (
            validity_bit_offset
        )
        # slot_offset filled in by bind_layout once the AggLayout is known.
        self.count_validity_slot_offsets[self.n_count_validity] = 0
        self.n_count_validity += 1

    def bind_layout(
        mut self,
        layout: AggLayout,
        aggs_offset: Int,
    ):
        """Plan-time wiring: resolve per-slot row thunks.

        Walks every bucket populated by `_push_*` and, for each entry's
        agg_idx, looks up the layout tag, resolves it to the monomorphic
        row thunk (`resolve_row_thunk`), and computes the byte offset of
        that slot within an entry (`aggs_offset + layout.offsets[agg_idx]`).

        Must be called AFTER the plan is fully built (all `_push_*` calls
        complete) and BEFORE the first `commit_row` call.

        Until `bind_layout` runs, `_layout_bound` is False and the commits
        use the per-row `_update_agg` fallback, never the defaults that
        `_push_*` stored.

        Args:
            layout: The AggLayout chosen by `layout_for_funcs` /
                `AggLayout.with_layout`, carrying per-slot tags + offsets.
            aggs_offset: The entry-base-to-first-agg-slot byte offset.
                Matches `FlatHashAggregator._aggs_offset`
                (= _HASH_BYTES + num_keys * 8).
        """
        var count_idxs = self._int_view_ptr(0)
        var f64_idxs = self._int_view_ptr(1)
        var i64_idxs = self._int_view_ptr(3)
        var i32_idxs = self._int_view_ptr(5)
        for j in range(self.n_count):
            var a = (count_idxs + j)[]
            var tag = layout.slot_tag(a)
            self.count_thunks[j] = resolve_row_thunk(tag)
            self.count_tags[j] = tag  # devirtualization selector
            self.count_slot_offsets[j] = aggs_offset + layout.slot_offset(a)
        for j in range(self.n_f64):
            var a = (f64_idxs + j)[]
            var tag = layout.slot_tag(a)
            self.f64_thunks[j] = resolve_row_thunk(tag)
            self.f64_tags[j] = tag  # devirtualization selector
            self.f64_slot_offsets[j] = aggs_offset + layout.slot_offset(a)
        for j in range(self.n_i64):
            var a = (i64_idxs + j)[]
            var tag = layout.slot_tag(a)
            self.i64_thunks[j] = resolve_row_thunk(tag)
            self.i64_tags[j] = tag  # devirtualization selector
            self.i64_slot_offsets[j] = aggs_offset + layout.slot_offset(a)
        for j in range(self.n_i32):
            var a = (i32_idxs + j)[]
            var tag = layout.slot_tag(a)
            self.i32_thunks[j] = resolve_row_thunk(tag)
            self.i32_tags[j] = tag  # devirtualization selector
            self.i32_slot_offsets[j] = aggs_offset + layout.slot_offset(a)
        # Bind the validity-count bucket. The resolved layout for
        # COUNT(col) may pick:
        #   - ACC_COUNT_STAR / ACC_COUNT_NONNULL (8B count-only): count at
        #     slot+0.
        #   - ACC_SUM_COUNT_F64 (16B [sum:f64][count:i64]): count at
        #     slot+8; the sum side reads `value` (0.0 is passed).
        #   - ACC_SUM_COUNT_MIN_MAX_F64 (32B quartet): count at slot+8;
        #     sum/min/max read `value` (0.0 is passed; the output of
        #     COUNT(col) reads only the count field).
        # Storing the resolved thunk keeps slot-shape semantics out of
        # the per-row loops (they just dispatch on bit-set).
        for j in range(self.n_count_validity):
            var a = self.count_validity_idxs[j]
            var tag = layout.slot_tag(a)
            self.count_validity_thunks[j] = resolve_row_thunk(tag)
            self.count_validity_slot_offsets[j] = (
                aggs_offset + layout.slot_offset(a)
            )
        # Arm the thunk dispatch path.
        self._layout_bound = True

    @always_inline
    def commit_row_ph(
        self,
        mut agg: PerfectHashAggregator,
        key: Int64,
        row: Int,
    ):
        """Same as commit_row, but drives a PerfectHashAggregator by key
        (Int64) instead of a FlatHashAggregator by entry pointer.

        Used by the DictLowCard / PerfectHashComposite paths where the
        composite dict index IS the group id, so there's no HT probe.
        """
        var count_idxs = self._int_view_ptr(0)
        var f64_idxs = self._int_view_ptr(1)
        var f64_offs = self._int_view_ptr(2)
        var i64_idxs = self._int_view_ptr(3)
        var i64_offs = self._int_view_ptr(4)
        var i32_idxs = self._int_view_ptr(5)
        var i32_offs = self._int_view_ptr(6)
        var f64_ptrs = self._f64_ptrs()
        var i64_ptrs = self._i64_ptrs()
        var i32_ptrs = self._i32_ptrs()

        for j in range(self.n_count):
            agg.update_count_only(key, (count_idxs + j)[])
        for j in range(self.n_f64):
            var val = ((f64_ptrs + j)[] + (f64_offs + j)[] + row)[]
            agg.update(key, (f64_idxs + j)[], val)
        for j in range(self.n_i64):
            var raw = ((i64_ptrs + j)[] + (i64_offs + j)[] + row)[]
            agg.update(key, (i64_idxs + j)[], Float64(Int(raw)))
        for j in range(self.n_i32):
            var raw = ((i32_ptrs + j)[] + (i32_offs + j)[] + row)[]
            agg.update(key, (i32_idxs + j)[], Float64(Int(raw)))
        # Validity-aware count(col): increment only when the bit is set
        # (SQL-standard count(col) semantics).
        for j in range(self.n_count_validity):
            var bit_idx = self.count_validity_bit_offsets[j] + row
            var byte_v = (
                self.count_validity_ptrs[j] + (bit_idx >> 3)
            )[]
            var bit_set = (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1)
            if bit_set:
                agg.update_count_only(key, self.count_validity_idxs[j])

    @always_inline
    def commit_row(
        self,
        mut agg: FlatHashAggregator,
        entry: EntryHandle,
        row: Int,
    ):
        """Update every accumulator for a single row.

        PERF-CRITICAL: per-slot monomorphic thunk dispatch. Each bucket
        entry stores a pre-resolved `AosRowThunk` and the slot's byte
        offset. The per-row hot path is:
          1. Read the raw value from the column (scalar gather).
          2. Load the thunk + slot_offset from the plan's cache-hot storage.
          3. Call the monomorphic kernel -- no tag check, no
             `agg._layout.tags[agg_idx]` load from the aggregator.

        The kernel writes only the fields its slot carries (quartet /
        16B sum+count / 8B sum-only / 8B count-only). The entry pointer is
        resolved afresh from `agg` by the handle's entry index.

        CONTRACT: call `bind_layout(agg._layout, agg._aggs_offset)` on the
        plan before the first `commit_row` to enable the thunk dispatch.
        Without it, commit_row falls back to `agg._update_agg` dispatch,
        which is correct (the runtime tag check routes to the right
        accumulator variant).
        """
        var count_idxs = self._int_view_ptr(0)
        var f64_idxs = self._int_view_ptr(1)
        var f64_offs = self._int_view_ptr(2)
        var i64_idxs = self._int_view_ptr(3)
        var i64_offs = self._int_view_ptr(4)
        var i32_idxs = self._int_view_ptr(5)
        var i32_offs = self._int_view_ptr(6)
        var f64_ptrs = self._f64_ptrs()
        var i64_ptrs = self._i64_ptrs()
        var i32_ptrs = self._i32_ptrs()

        if not self._layout_bound:
            # Correctness-safe fallback: `_update_agg` dispatch.
            for j in range(self.n_count):
                agg._update_count_only(entry, (count_idxs + j)[])
            for j in range(self.n_f64):
                var val = ((f64_ptrs + j)[] + (f64_offs + j)[] + row)[]
                agg._update_agg(entry, (f64_idxs + j)[], val)
            for j in range(self.n_i64):
                var raw = ((i64_ptrs + j)[] + (i64_offs + j)[] + row)[]
                agg._update_agg(
                    entry, (i64_idxs + j)[], Float64(Int(raw))
                )
            for j in range(self.n_i32):
                var raw = ((i32_ptrs + j)[] + (i32_offs + j)[] + row)[]
                agg._update_agg(
                    entry, (i32_idxs + j)[], Float64(Int(raw))
                )
            # Validity-aware count(col).
            for j in range(self.n_count_validity):
                var bit_idx = self.count_validity_bit_offsets[j] + row
                var byte_v = (
                    self.count_validity_ptrs[j] + (bit_idx >> 3)
                )[]
                if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                    agg._update_count_only(entry, self.count_validity_idxs[j])
            return

        # Resolve the entry pointer afresh from `agg` by the handle's
        # entry index (one load). `agg` is borrowed mutably for the call,
        # and the pointer carries the origin of `agg._entries`, so the
        # compiler keeps the buffer alive across every write below.
        var entry_ptr = agg._entry_ptr_by_idx(Int(entry._entry_idx))
        var entry_stride = agg._entry_stride

        # count-only bucket -- COUNT(*): the kernel ignores `value`. One
        # indirect call per COUNT agg per row.
        for j in range(self.n_count):
            var thunk = self.count_thunks[j]
            var slot_off = self.count_slot_offsets[j]
            _thunk_call(thunk, entry_ptr, entry_stride, slot_off, Float64(0.0))
        # f64 bucket -- pass the value straight through to the thunk.
        for j in range(self.n_f64):
            var val = ((f64_ptrs + j)[] + (f64_offs + j)[] + row)[]
            var thunk = self.f64_thunks[j]
            var slot_off = self.f64_slot_offsets[j]
            _thunk_call(thunk, entry_ptr, entry_stride, slot_off, val)
        # i64 bucket -- widen to Float64 at the call site.
        for j in range(self.n_i64):
            var raw = ((i64_ptrs + j)[] + (i64_offs + j)[] + row)[]
            var thunk = self.i64_thunks[j]
            var slot_off = self.i64_slot_offsets[j]
            _thunk_call(thunk, entry_ptr, entry_stride, slot_off, Float64(Int(raw)))
        # i32 bucket -- widen to Float64 at the call site.
        for j in range(self.n_i32):
            var raw = ((i32_ptrs + j)[] + (i32_offs + j)[] + row)[]
            var thunk = self.i32_thunks[j]
            var slot_off = self.i32_slot_offsets[j]
            _thunk_call(thunk, entry_ptr, entry_stride, slot_off, Float64(Int(raw)))
        # Validity-aware count(col): the resolved row thunk runs only when
        # the validity bit is set, so every slot shape (8B / 16B / 32B) is
        # handled by its kernel and NULLs are skipped.
        for j in range(self.n_count_validity):
            var bit_idx = self.count_validity_bit_offsets[j] + row
            var byte_v = (
                self.count_validity_ptrs[j] + (bit_idx >> 3)
            )[]
            if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                var thunk = self.count_validity_thunks[j]
                var slot_off = self.count_validity_slot_offsets[j]
                _thunk_call(thunk, entry_ptr, entry_stride, slot_off, Float64(0.0))

    # =========================================================================
    # Loop-transposed batch commits (bodies in agg_commit_batch.mojo)
    # =========================================================================

    def commit_batch[
        o_entries: Origin
    ](
        self,
        mut agg: FlatHashAggregator,
        entries: Span[EntryHandle, o_entries],
    ):
        """Batch commit: outer loop over accumulators, inner loop over rows.

        PERF-CRITICAL: each inner loop is a tight gather-scatter with no
        type dispatch per row; see agg_commit_batch.mojo.

        Args:
            agg: The aggregator owning the entry storage.
            entries: One EntryHandle per row of the plan's batch, each
                produced by a find_or_create_* call on `agg` with no resize
                since (the probe phase pre-sizes `agg`).
        """
        from .agg_commit_batch import _commit_batch_impl
        _commit_batch_impl(self, agg, entries.unsafe_ptr(), len(entries))

    def commit_batch_partitioned[
        o_ids: Origin, o_entries: Origin
    ](
        self,
        mut pagg: PartitionedFlatHashAggregator,
        partition_ids: Span[UInt8, o_ids],
        entries: Span[EntryHandle, o_entries],
    ):
        """Batch commit for a PartitionedFlatHashAggregator: as
        `commit_batch`, but row `r`'s entry lives in sub-table
        `partition_ids[r]`.

        Args:
            pagg: The partitioned aggregator owning the sub-table storage.
            partition_ids: One partition index per row (NUM_PARTITIONS is
                at most 256, so a UInt8 holds any index); at least
                `len(entries)` of them.
            entries: One EntryHandle per row, into the sub-table its
                partition id names, with no resize of any sub-table since.
        """
        debug_assert(
            len(partition_ids) >= len(entries),
            "commit_batch_partitioned: fewer partition ids than entries",
        )
        from .agg_commit_batch import _commit_batch_partitioned_impl
        _commit_batch_partitioned_impl(
            self, pagg, partition_ids.unsafe_ptr(), entries.unsafe_ptr(), len(entries)
        )

    def commit_batch_indexed[
        o_entries: Origin, o_rows: Origin
    ](
        self,
        mut agg: FlatHashAggregator,
        entries: Span[EntryHandle, o_entries],
        row_indices: Span[Int32, o_rows],
    ):
        """Indexed batch commit: commits the rows `row_indices` names, each
        into `agg` through `entries[row]`.

        Args:
            agg: The sub-table aggregator, loop-invariant for the call.
            entries: Per-row EntryHandles of the plan's batch, indexed by
                row; the rows named must reference entries of `agg`.
            row_indices: The rows of the batch to commit on this call.
        """
        from .agg_commit_batch import _commit_batch_indexed_impl
        _commit_batch_indexed_impl(
            self, agg, entries.unsafe_ptr(), row_indices.unsafe_ptr(), len(row_indices)
        )



# =============================================================================
# Factory helpers
# =============================================================================
#
# Two flavors:
#   - `build_agg_commit_plan` — resolves the value column of each aggregate
#     from `AggSinkData` against `batch.schema`.
#   - `build_agg_commit_plan_indexed` — takes a pre-resolved `val_col_indices`
#     list, for call sites that already computed them.
#
# Both do the same classification: for each agg, decide which bucket it
# belongs to and push (agg_idx, ptr, offset) into that bucket.
# =============================================================================


def build_agg_commit_plan[
    batch_origin: ImmOrigin
](
    ref [batch_origin] batch: RecordBatch,
    agg_data: AggSinkData,
    num_aggs: Int,
) raises -> AggCommitPlan[batch_origin]:
    """Build a commit plan from the agg expressions and the input batch.

    Called once per batch; cost is O(num_aggs). Parametric on the batch's
    origin, inferred from the `batch` ref argument: the value and validity
    pointers baked into the returned plan carry `batch_origin`, so the
    compiler keeps the input batch alive through the plan.
    """
    var plan = AggCommitPlan[batch_origin](num_aggs)

    for a in range(num_aggs):
        if agg_data.agg_exprs[a].child:
            var vi = resolve_col_index(
                agg_data.agg_exprs[a].child.value(), batch.schema
            )
            ref vp = batch.column_at(vi)
            var vat = vp.arrow_type
            var offset = vp._offset
            # SQL-standard `count(col)` skips NULL rows. The i32/i64/f64
            # buckets increment the count slot unconditionally, which is
            # correct ONLY when the column has no nulls or the agg is not
            # COUNT. COUNT(col) on a nullable column goes to the
            # `_count_with_validity` bucket, whose per-row commit consults
            # the validity bit.
            if (
                agg_data.agg_exprs[a].func == AGG_COUNT
                and vp._null_count > 0
                and vp._validity
            ):
                plan._push_count_with_validity(
                    a,
                    vp._validity.value().buffer.view_ro()._unsafe_ptr()
                        .unsafe_origin_cast[batch_origin](),
                    offset,
                )
                continue
            # The value-column pointer carries `batch_origin`.
            if vat == ArrowType.INT32:
                plan._push_i32(
                    a,
                    vp._data.view_ro()._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_origin_cast[batch_origin](),
                    offset,
                )
            elif vat == ArrowType.INT64:
                plan._push_i64(
                    a,
                    vp._data.view_ro()._unsafe_ptr()
                        .bitcast[Scalar[DType.int64]]()
                        .unsafe_origin_cast[batch_origin](),
                    offset,
                )
            else:
                plan._push_f64(
                    a,
                    vp._data.view_ro()._unsafe_ptr()
                        .bitcast[Scalar[DType.float64]]()
                        .unsafe_origin_cast[batch_origin](),
                    offset,
                )
        else:
            # COUNT(*): no column — just bump count slot per row.
            plan._push_count(a)

    return plan^


def build_agg_commit_plan_indexed[
    batch_origin: ImmOrigin
](
    ref [batch_origin] batch: RecordBatch,
    agg_data: AggSinkData,
    num_aggs: Int,
    val_col_indices: List[Int],
) raises -> AggCommitPlan[batch_origin]:
    """Build a commit plan from pre-resolved value column indices.

    For callers that already computed `val_col_indices` during batch
    setup. `val_col_indices[a] < 0` means COUNT(*). The plan carries
    `batch_origin` (see `build_agg_commit_plan`).
    """
    var plan = AggCommitPlan[batch_origin](num_aggs)

    for a in range(num_aggs):
        var vi = val_col_indices[a]
        if vi < 0:
            plan._push_count(a)
            continue
        ref vp = batch.column_at(vi)
        var vat = vp.arrow_type
        var offset = vp._offset
        # Nullable count(col) goes to the validity-aware bucket (see
        # `build_agg_commit_plan`).
        if (
            agg_data.agg_exprs[a].func == AGG_COUNT
            and vp._null_count > 0
            and vp._validity
        ):
            plan._push_count_with_validity(
                a,
                vp._validity.value().buffer.view_ro()._unsafe_ptr()
                    .unsafe_origin_cast[batch_origin](),
                offset,
            )
            continue
        # The value-column pointer carries `batch_origin`.
        if vat == ArrowType.INT32:
            plan._push_i32(
                a,
                vp._data.view_ro()._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_origin_cast[batch_origin](),
                offset,
            )
        elif vat == ArrowType.INT64:
            plan._push_i64(
                a,
                vp._data.view_ro()._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_origin_cast[batch_origin](),
                offset,
            )
        else:
            plan._push_f64(
                a,
                vp._data.view_ro()._unsafe_ptr()
                    .bitcast[Scalar[DType.float64]]()
                    .unsafe_origin_cast[batch_origin](),
                offset,
            )

    return plan^
