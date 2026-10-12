# =============================================================================
# FlatHashAggregator -- accumulator path
# =============================================================================
#
# The per-slot accumulator init / update / read / merge helpers of
# `FlatHashAggregator`, as free functions taking the aggregator as their
# first argument; the methods in `flat_hash_agg.mojo` forward to them (the
# same pattern as `flat_hash_agg_probe.mojo` for find_or_create). They are
# package-private: their names start with `_`.
#
# Every helper dispatches on the slot's layout tag
# (`agg._layout.tags[agg_idx]`): the 32 B quartet
# (ACC_SUM_COUNT_MIN_MAX_F64) and the narrow slots (ACC_SUM_COUNT_F64,
# ACC_SUM_F64, ACC_COUNT_STAR / ACC_COUNT_NONNULL) write or read only the
# fields their slot holds. Entry rows stay array-of-structs.
# =============================================================================

from std.memory import UnsafePointer
from komira_udf.float_quotient_order import float_max_fold_f64, float_min_fold_f64

from .flat_hash_agg import EntryHandle, FlatHashAggregator
from .flat_hash_agg_hash import (
    _F64_MIN_SEED_BITS,
    _F64_MAX_SEED_BITS,
)
from komira_agg_api.agg_layout import (
    AggLayout,
    ACC_SUM_F64,
    ACC_SUM_COUNT_F64,
    ACC_COUNT_STAR,
    ACC_COUNT_NONNULL,
    ACC_SUM_COUNT_MIN_MAX_F64,
)


# -----------------------------------------------------------------------------
# Accumulator init (for new groups)
# -----------------------------------------------------------------------------
#
# PERF-CRITICAL: layout-aware init/update dispatch.
#
# For quartet (32B) slots, initialize sum=0, count=0 and the min/max seeds.
# For narrow slots, initialize only the fields present in the slot:
#
#   ACC_SUM_COUNT_F64 (16B): sum=0, count=0
#   ACC_SUM_F64 (8B): sum=0
#   ACC_COUNT_STAR / ACC_COUNT_NONNULL (8B): count=0
#
# The tag check is const-foldable when AggLayout is fixed at plan time.


@always_inline
def _init_agg_slot_impl[
    o_entry: Origin[mut=True]
](
    layout: AggLayout,
    aggs_offset: Int,
    entry: UnsafePointer[UInt8, o_entry],
    agg_idx: Int,
):
    """Initialize an agg slot based on its layout tag.

    PERF-CRITICAL: Dispatches on `layout.tags[agg_idx]` so narrow
    layouts only write the fields their slot holds. Takes the
    aggregator's layout and aggs offset, not the aggregator, because
    `entry` points into the aggregator's own buffer.
    """
    var ap = entry + aggs_offset + layout.offsets[agg_idx]
    var tag = layout.tags[agg_idx]
    if tag == ACC_SUM_COUNT_MIN_MAX_F64:
        # 32B quartet: sum=0, count=0, min and max seeded.
        ap.bitcast[Float64]()[] = 0.0
        (ap + 8).bitcast[Int64]()[] = Int64(0)
        (ap + 16).bitcast[UInt64]()[] = _F64_MIN_SEED_BITS
        (ap + 24).bitcast[UInt64]()[] = _F64_MAX_SEED_BITS
    elif tag == ACC_SUM_COUNT_F64:
        # 16B: [sum:f64 @+0][count:i64 @+8]
        ap.bitcast[Float64]()[] = 0.0
        (ap + 8).bitcast[Int64]()[] = Int64(0)
    elif tag == ACC_SUM_F64:
        # 8B: [sum:f64 @+0]
        ap.bitcast[Float64]()[] = 0.0
    elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        # 8B: [count:i64 @+0]
        ap.bitcast[Int64]()[] = Int64(0)
    else:
        # Defensive default: initialize as a quartet.
        ap.bitcast[Float64]()[] = 0.0
        (ap + 8).bitcast[Int64]()[] = Int64(0)
        (ap + 16).bitcast[UInt64]()[] = _F64_MIN_SEED_BITS
        (ap + 24).bitcast[UInt64]()[] = _F64_MAX_SEED_BITS


@always_inline
def _init_all_agg_slots_impl[
    o_entry: Origin[mut=True]
](
    layout: AggLayout,
    aggs_offset: Int,
    entry: UnsafePointer[UInt8, o_entry],
):
    """Initialize all agg slots in an entry (`layout.num_aggs` of them)."""
    for a in range(layout.num_aggs):
        _init_agg_slot_impl(layout, aggs_offset, entry, a)


# -----------------------------------------------------------------------------
# Accumulator update
# -----------------------------------------------------------------------------


@always_inline
def _update_agg_impl(
    mut agg: FlatHashAggregator,
    entry: EntryHandle,
    agg_idx: Int,
    value: Float64,
):
    """Update fields present in this slot based on its layout tag.

    PERF-CRITICAL: Dispatches on `agg._layout.tags[agg_idx]`. The 32B
    quartet writes sum + count + min/max; narrow slots write only the
    fields they hold. The entry pointer is resolved afresh from `agg`,
    so the write is anchored to `agg._entries`.
    """
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var tag = agg._layout.tags[agg_idx]
    if tag == ACC_SUM_COUNT_MIN_MAX_F64:
        # 32B quartet: sum/count/min/max.
        var sum_p = ap.bitcast[Float64]()
        var count_p = (ap + 8).bitcast[Int64]()
        var min_p = (ap + 16).bitcast[Float64]()
        var max_p = (ap + 24).bitcast[Float64]()
        sum_p[] = sum_p[] + value
        count_p[] = count_p[] + 1
        min_p[] = float_min_fold_f64(min_p[], value)
        max_p[] = float_max_fold_f64(max_p[], value)
    elif tag == ACC_SUM_COUNT_F64:
        # 16B: sum + count
        var sum_p = ap.bitcast[Float64]()
        var count_p = (ap + 8).bitcast[Int64]()
        sum_p[] = sum_p[] + value
        count_p[] = count_p[] + 1
    elif tag == ACC_SUM_F64:
        # 8B: sum only
        var sum_p = ap.bitcast[Float64]()
        sum_p[] = sum_p[] + value
    elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        # 8B: count only. `value` is ignored; the caller typically
        # routes COUNT through `_update_count_only_impl` for brevity,
        # but incrementing by 1 here preserves semantics.
        var count_p = ap.bitcast[Int64]()
        count_p[] = count_p[] + 1
    else:
        # Defensive default: quartet shape.
        var sum_p = ap.bitcast[Float64]()
        var count_p = (ap + 8).bitcast[Int64]()
        var min_p = (ap + 16).bitcast[Float64]()
        var max_p = (ap + 24).bitcast[Float64]()
        sum_p[] = sum_p[] + value
        count_p[] = count_p[] + 1
        min_p[] = float_min_fold_f64(min_p[], value)
        max_p[] = float_max_fold_f64(max_p[], value)


@always_inline
def _merge_quartet_prehashed_impl(
    mut agg: FlatHashAggregator,
    entry: EntryHandle,
    agg_idx: Int,
    sum_in: Float64,
    count_in: Int,
    min_in: Float64,
    max_in: Float64,
):
    """Merge one pre-aggregated quartet into a quartet slot.

    The spill-restore primitive; see
    `FlatHashAggregator._merge_quartet_prehashed` for semantics. The
    entry pointer is resolved afresh from `agg`.
    """
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var tag = agg._layout.tags[agg_idx]
    # Only quartet shape supported.
    if tag != ACC_SUM_COUNT_MIN_MAX_F64:
        # Defensive: do nothing (callers that need narrower shapes must
        # add a dedicated helper).
        return
    # SAFETY: ap is derived from agg._entries via _agg_ptr; the
    # bitcasts below stay within the entry's quartet slot
    # (32 bytes), and the slot layout matches _update_agg_impl's
    # ACC_SUM_COUNT_MIN_MAX_F64 arm byte-for-byte.
    var sum_p = ap.bitcast[Float64]()
    var count_p = (ap + 8).bitcast[Int64]()
    var min_p = (ap + 16).bitcast[Float64]()
    var max_p = (ap + 24).bitcast[Float64]()
    var cur_count = count_p[]
    if cur_count == Int64(0):
        # Fresh slot — replace identity values with the incoming deltas.
        sum_p[] = sum_in
        count_p[] = Int64(count_in)
        min_p[] = min_in
        max_p[] = max_in
    else:
        sum_p[] = sum_p[] + sum_in
        count_p[] = cur_count + Int64(count_in)
        min_p[] = float_min_fold_f64(min_p[], min_in)
        max_p[] = float_max_fold_f64(max_p[], max_in)


@always_inline
def _update_count_only_impl(
    mut agg: FlatHashAggregator,
    entry: EntryHandle,
    agg_idx: Int,
):
    """Increment only the count for COUNT(*) agg.

    Layout-aware: count is at slot +8 for the 32B quartet and 16B
    sum+count slots, and at slot +0 for the 8B count-only slots.
    """
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var tag = agg._layout.tags[agg_idx]
    if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        # 8B slot: count at +0.
        var count_p = ap.bitcast[Int64]()
        count_p[] = count_p[] + 1
    else:
        # 32B quartet or 16B sum+count: count at +8.
        var count_p = (ap + 8).bitcast[Int64]()
        count_p[] = count_p[] + 1


# PERF-CRITICAL: bulk add for the COUNT(*) ungrouped fast path: one
# `count += n` write replaces n per-row updates.
@always_inline
def _add_count_bulk_impl(
    mut agg: FlatHashAggregator,
    entry: EntryHandle,
    agg_idx: Int,
    n: Int,
):
    """Add `n` to the count slot in one shot (COUNT(*) fast path).

    Layout-aware: picks up count at +0 for 8B count-only slots and at
    +8 for the 32B quartet / 16B sum+count slots.
    """
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var tag = agg._layout.tags[agg_idx]
    if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        var count_p = ap.bitcast[Int64]()
        count_p[] = count_p[] + Int64(n)
    else:
        var count_p = (ap + 8).bitcast[Int64]()
        count_p[] = count_p[] + Int64(n)


# -----------------------------------------------------------------------------
# Result extraction
# -----------------------------------------------------------------------------


@always_inline
def _get_sum_impl(
    agg: FlatHashAggregator, entry: EntryHandle, agg_idx: Int
) -> Float64:
    """Read sum from an agg slot.

    Layout-aware: returns 0.0 for slots that don't store a sum
    (ACC_COUNT_STAR / ACC_COUNT_NONNULL).
    """
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var tag = agg._layout.tags[agg_idx]
    if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        return 0.0
    return ap.bitcast[Float64]()[]


@always_inline
def _get_count_impl(
    agg: FlatHashAggregator, entry: EntryHandle, agg_idx: Int
) -> Int:
    """Read count from an agg slot.

    Layout-aware: count is at +8 for 32B quartet / 16B sum+count
    slots and at +0 for 8B count-only slots. Returns 0 for sum-only
    slots (ACC_SUM_F64).
    """
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var tag = agg._layout.tags[agg_idx]
    if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        return Int(ap.bitcast[Int64]()[])
    if tag == ACC_SUM_F64:
        return 0
    return Int((ap + 8).bitcast[Int64]()[])


@always_inline
def _get_min_impl(
    agg: FlatHashAggregator, entry: EntryHandle, agg_idx: Int
) -> Float64:
    """Read min from an agg slot.

    Layout-aware: only the 32B quartet slot stores a min. Other
    layouts return the min seed (`_F64_MIN_SEED_BITS`) so a consumer
    that did not request MIN gets a harmless value.
    """
    var tag = agg._layout.tags[agg_idx]
    if tag != ACC_SUM_COUNT_MIN_MAX_F64:
        # Reinterpret the seed bits through a scratch UInt64 store.
        var scratch: UInt64 = _F64_MIN_SEED_BITS
        return UnsafePointer(to=scratch).bitcast[Float64]()[]
    return ((agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx)) + 16).bitcast[Float64]()[]


@always_inline
def _get_max_impl(
    agg: FlatHashAggregator, entry: EntryHandle, agg_idx: Int
) -> Float64:
    """Read max from an agg slot.

    Layout-aware: only the 32B quartet slot stores a max. Other
    layouts return the max seed (`_F64_MAX_SEED_BITS`) for the same
    reason.
    """
    var tag = agg._layout.tags[agg_idx]
    if tag != ACC_SUM_COUNT_MIN_MAX_F64:
        var scratch: UInt64 = _F64_MAX_SEED_BITS
        return UnsafePointer(to=scratch).bitcast[Float64]()[]
    return ((agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx)) + 24).bitcast[Float64]()[]


@always_inline
def _get_avg_impl(
    agg: FlatHashAggregator, entry: EntryHandle, agg_idx: Int
) -> Float64:
    """Compute average from an agg slot.

    Requires the slot to carry both sum + count (quartet or
    sum_count_f64). Sum-only or count-only slots return 0.0.
    """
    var tag = agg._layout.tags[agg_idx]
    if tag != ACC_SUM_COUNT_MIN_MAX_F64 and tag != ACC_SUM_COUNT_F64:
        return 0.0
    var ap = (agg._entry_ptr_by_idx(Int(entry._entry_idx)) + agg._agg_off(agg_idx))
    var s = ap.bitcast[Float64]()[]
    var c = (ap + 8).bitcast[Int64]()[]
    if c > 0:
        return s / Float64(Int(c))
    return 0.0


# -----------------------------------------------------------------------------
# Merge paths (cross-aggregator fold)
# -----------------------------------------------------------------------------
#
# `_merge_flushed_row_impl` folds one flush-buffer row into `agg`;
# `_merge_one_entry_impl` folds one live entry of another aggregator. In
# both the source shares the destination's layout (a flush row is an entry
# copied verbatim; sibling aggregators come from one plan), so the source
# slot sits at `agg._layout.offsets[a]` too.


# PERF-CRITICAL: layout-aware per-slot fold shared by both merge paths.
# `src_slot_stride` is 32 when the source slot is a 32B quartet regardless
# of the destination's width, and 0 for a matched-layout source.
@always_inline
def _fold_slot_inline[
    o_self: Origin[mut=True], o_src: Origin
](
    tag: UInt8,
    self_ap: UnsafePointer[UInt8, o_self],
    src_ap: UnsafePointer[UInt8, o_src],
    src_slot_stride: Int,
):
    """Fold src agg slot into self_ap; field selection keyed by the
    destination slot's tag."""
    if tag == ACC_SUM_COUNT_MIN_MAX_F64:
        var self_sum = self_ap.bitcast[Float64]()
        self_sum[] = self_sum[] + src_ap.bitcast[Float64]()[]
        var self_count = (self_ap + 8).bitcast[Int64]()
        self_count[] = self_count[] + (src_ap + 8).bitcast[Int64]()[]
        var self_min = (self_ap + 16).bitcast[Float64]()
        var src_min = (src_ap + 16).bitcast[Float64]()[]
        self_min[] = float_min_fold_f64(self_min[], src_min)
        var self_max = (self_ap + 24).bitcast[Float64]()
        var src_max = (src_ap + 24).bitcast[Float64]()[]
        self_max[] = float_max_fold_f64(self_max[], src_max)
    elif tag == ACC_SUM_COUNT_F64:
        var self_sum = self_ap.bitcast[Float64]()
        self_sum[] = self_sum[] + src_ap.bitcast[Float64]()[]
        var self_count = (self_ap + 8).bitcast[Int64]()
        self_count[] = self_count[] + (src_ap + 8).bitcast[Int64]()[]
    elif tag == ACC_SUM_F64:
        var self_sum = self_ap.bitcast[Float64]()
        self_sum[] = self_sum[] + src_ap.bitcast[Float64]()[]
    elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
        var self_count = self_ap.bitcast[Int64]()
        if src_slot_stride >= 16:
            # Scatter src writes count at +8 of the 32B quartet.
            self_count[] = self_count[] + (src_ap + 8).bitcast[Int64]()[]
        else:
            # Matched 8B layout: count at +0.
            self_count[] = self_count[] + src_ap.bitcast[Int64]()[]
    else:
        # Defensive default: quartet fold.
        var self_sum = self_ap.bitcast[Float64]()
        self_sum[] = self_sum[] + src_ap.bitcast[Float64]()[]
        var self_count = (self_ap + 8).bitcast[Int64]()
        self_count[] = self_count[] + (src_ap + 8).bitcast[Int64]()[]


# PERF-CRITICAL: the combine step re-inserts the rows the abandon cycle
# scattered into FlatHashPartitionFlush buffers. `flush_to_partitions`
# copies `entry_stride` bytes verbatim, so a flush row has the source
# aggregator's layout, and the matched-layout decode (`src_slot_stride=0`)
# reads it correctly for quartet and narrow slots alike.
#
# SAFETY: `row` points at `agg._entry_stride` readable bytes (the public
# `merge_flushed_row` takes them as a span and debug-asserts the length).
def _merge_flushed_row_impl[
    o_row: Origin
](
    mut agg: FlatHashAggregator,
    row: UnsafePointer[UInt8, o_row],
):
    """Re-insert a flushed entry row (hash+keys+aggs).

    Flush rows share the aggregator's own layout (the scatter copies
    entry_stride bytes verbatim).
    """
    var self_entry_handle: EntryHandle
    if agg._num_keys == 1:
        var k = (row + agg._keys_offset).bitcast[Int64]()[]
        self_entry_handle = agg.find_or_create_1(k)
    elif agg._num_keys == 2:
        var kp = (row + agg._keys_offset).bitcast[Int64]()
        self_entry_handle = agg.find_or_create_2(kp[], (kp + 1)[])
    else:
        self_entry_handle = agg._find_or_create_n(
            (row + agg._keys_offset).bitcast[Int64](), agg._num_keys
        )
    # Resolve by insertion-order entry index (one load), anchored to
    # agg._entries through `agg`'s mut borrow.
    var self_entry = agg._entry_ptr_by_idx(Int(self_entry_handle._entry_idx))

    # Matched-layout fold: src shares dst's layout (see header).
    for a in range(agg._num_aggs):
        var self_ap = self_entry + agg._agg_off(a)
        var src_ap = row + agg._agg_off(a)
        _fold_slot_inline(agg._layout.tags[a], self_ap, src_ap, 0)


@always_inline
def _merge_one_entry_impl(
    mut agg: FlatHashAggregator,
    other: FlatHashAggregator,
    other_entry: EntryHandle,
):
    """Merge a single occupied entry from another aggregator into self.

    Both aggregators share the same layout (sibling aggs from the same
    plan). src and dst slots live at the same offset inside each entry.
    `other` is borrowed so `other_entry` resolves against
    `other._entries` with the owning aggregator's origin.
    """
    # Resolve other's entry pointer afresh so the read anchors to
    # other._entries through `other`.
    var other_ptr = other._entry_ptr_by_idx(Int(other_entry._entry_idx))
    var self_entry_handle: EntryHandle
    if agg._num_keys == 1:
        var key = FlatHashAggregator._key_ptr(other_ptr)[]
        self_entry_handle = agg.find_or_create_1(key)
    elif agg._num_keys == 2:
        var kp = FlatHashAggregator._key_ptr(other_ptr)
        self_entry_handle = agg.find_or_create_2(kp[], (kp + 1)[])
    else:
        self_entry_handle = agg._find_or_create_n(
            FlatHashAggregator._key_ptr(other_ptr), agg._num_keys
        )
    # agg.find_or_create_* above may have grown `agg`, so re-derive both
    # entry pointers from their owning aggregators AFTER the probe (entry
    # indices are stable across a resize).
    var self_entry = agg._entry_ptr_by_idx(Int(self_entry_handle._entry_idx))
    # Re-derive other_ptr as well defensively (cheap, same-aggregator).
    var other_ptr_live = other._entry_ptr_by_idx(Int(other_entry._entry_idx))

    # Matched-layout fold: src and dst use the same offsets + widths.
    for a in range(agg._num_aggs):
        var self_ap = self_entry + agg._agg_off(a)
        var other_ap = other._agg_ptr(other_ptr_live, a)
        _fold_slot_inline(agg._layout.tags[a], self_ap, other_ap, 0)
