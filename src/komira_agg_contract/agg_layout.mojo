# =============================================================================
# AggLayout -- plan-time accumulator layout for FlatHashAggregator
# =============================================================================
#
# The hash-aggregate entry keeps an AoS `[hash][keys][aggs]` row layout
# because the entry layout is a cross-module byte contract (scatter, merge,
# spill, perfect-hash sibling). Instead of SoA, the PER-AGG SLOT WIDTH
# varies, so a SUM+COUNT query pays 16B per agg instead of 32B.
#
# The `tags` / `offsets` / `widths` storage is `InlineArray[T, MAX_AGGS]`,
# not `List[T]`. The `List[T]` form triggers a Mojo codegen bug: when
# AggLayout lives inside a `FlatHashAggregator` that lives inside a
# `Slab[FlatHashAggregator]` (the `PartitionedFlatHashAggregator` case),
# reading `self._layout.offsets[agg_idx]` from `@always_inline def _agg_ptr`
# returns pointer-sized garbage. Stack-backed InlineArray storage avoids the
# heap-pointer move path.
#
# MAX_AGGS=16 is well above the aggregate counts of typical analytical
# queries. If a query needs more, raise the cap in this file's `MAX_AGGS`
# constant.
# =============================================================================

from std.collections import Array


# -----------------------------------------------------------------------------
# Static cap on the number of aggregators per plan.
# -----------------------------------------------------------------------------

comptime MAX_AGGS: Int = 16


# -----------------------------------------------------------------------------
# AccTag -- per-aggregator slot layout tag
# -----------------------------------------------------------------------------
#
# Tag values are stable across the scatter/merge/spill byte contract. Do NOT
# renumber; add new variants at the end. Only ACC_SUM_COUNT_MIN_MAX_F64 (the
# 32B default) and ACC_SUM_COUNT_F64 (the SUM+COUNT fast path) are wired;
# the others are declared but unused.

comptime ACC_TAG_INVALID: UInt8 = 0
comptime ACC_SUM_F64: UInt8 = 1  # 8B:  [sum:f64]
comptime ACC_SUM_I64: UInt8 = 2  # 8B:  [sum:i64]
comptime ACC_COUNT_STAR: UInt8 = 3  # 8B:  [count:i64]
comptime ACC_COUNT_NONNULL: UInt8 = 4  # 8B:  [count:i64]  (skips nulls)
comptime ACC_SUM_COUNT_F64: UInt8 = 5  # 16B: [sum:f64][count:i64]
comptime ACC_SUM_COUNT_I64: UInt8 = 6  # 16B: [sum:i64][count:i64]
comptime ACC_MIN_F64: UInt8 = 7  # 8B:  [min:f64]
comptime ACC_MAX_F64: UInt8 = 8  # 8B:  [max:f64]
comptime ACC_SUM_COUNT_MIN_MAX_F64: UInt8 = 9  # 32B: full quartet (current default)
comptime ACC_COUNT_DISTINCT_I64: UInt8 = 10  # 8B: pointer/idx into DynAccumulator


# -----------------------------------------------------------------------------
# Width table -- bytes per slot for each AccTag
# -----------------------------------------------------------------------------
#
# Keep `acc_slot_width` and `acc_slot_layout` in lockstep with the AccTag
# aliases. A mismatch here is a correctness bug (merge would decode a source
# row's 32B slot into a narrower dst and read off the end).

@always_inline
def acc_slot_width(tag: UInt8) -> Int:
    """Bytes per slot for the given AccTag."""
    if tag == ACC_SUM_F64:
        return 8
    if tag == ACC_SUM_I64:
        return 8
    if tag == ACC_COUNT_STAR:
        return 8
    if tag == ACC_COUNT_NONNULL:
        return 8
    if tag == ACC_SUM_COUNT_F64:
        return 16
    if tag == ACC_SUM_COUNT_I64:
        return 16
    if tag == ACC_MIN_F64:
        return 8
    if tag == ACC_MAX_F64:
        return 8
    if tag == ACC_SUM_COUNT_MIN_MAX_F64:
        return 32
    if tag == ACC_COUNT_DISTINCT_I64:
        return 8
    # ACC_TAG_INVALID or unknown: fall back to 0 so any downstream offset
    # arithmetic is obviously wrong. Callers should never see this path on
    # a correctly-constructed AggLayout.
    return 0


# -----------------------------------------------------------------------------
# AggLayout -- computed once at plan time, shared across the aggregator family
# -----------------------------------------------------------------------------
#
# Byte layout of the AGG region of a FlatHashAggregator entry:
#   [agg_0: widths[0] bytes][agg_1: widths[1] bytes]...[agg_{N-1}: widths[N-1] bytes]
#
# offsets[i] is the byte offset of slot i from the agg-region base (i.e.
# entry + aggs_offset). total_width is sum(widths).
#
# NOTE: The SCATTER rows (FlatHashPartitionFlush buffers) always use the
# 32B-per-slot layout. AggLayout describes
# the HT-side layout only. The merge code decodes 32B source slots into
# variable-width dst slots.

struct AggLayout(Movable, Copyable):
    """Per-query accumulator slot layout.

    Computed once at plan time, shared across:
      - FlatHashAggregator (entry_stride, _agg_ptr)
      - PerfectHashAggregator (slot_stride, _agg_ptr)
      - merge (_fold_agg_slots dispatch)
      - kernels (thunk offset/width)

    Storage note: the tag/offset/width arrays are stored as
    `InlineArray[T, MAX_AGGS]`, NOT `List[T]`. See module header for the
    codegen bug that drove that choice. Only the first `num_aggs` entries
    are meaningful; positions in [num_aggs, MAX_AGGS) are zero.
    """

    var tags: Array[UInt8, MAX_AGGS]
    var offsets: Array[Int, MAX_AGGS]
    var widths: Array[Int, MAX_AGGS]
    var total_width: Int
    var num_aggs: Int

    def __init__(out self, var tags: List[UInt8]):
        """Build an AggLayout from a per-slot tag list.

        Offsets + widths + total_width are derived. Tags are consumed
        (moved) -- the AggLayout copies them into stack-backed storage.
        """
        var n = len(tags)
        debug_assert(
            n <= MAX_AGGS,
            "AggLayout: num_aggs exceeds MAX_AGGS",
        )
        self.tags = Array[UInt8, MAX_AGGS](fill=0)
        self.offsets = Array[Int, MAX_AGGS](fill=0)
        self.widths = Array[Int, MAX_AGGS](fill=0)
        var acc = 0
        for i in range(n):
            var t = tags[i]
            var w = acc_slot_width(t)
            self.tags[i] = t
            self.offsets[i] = acc
            self.widths[i] = w
            acc += w
        self.total_width = acc
        self.num_aggs = n

    @staticmethod
    def default_quartet(num_aggs: Int) -> AggLayout:
        """Build the 32B-per-slot quartet layout.

        Every agg slot is ACC_SUM_COUNT_MIN_MAX_F64 (32B). This is the
        default layout.
        """
        var tags = List[UInt8](capacity=num_aggs)
        for _ in range(num_aggs):
            tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
        return AggLayout(tags^)

    @staticmethod
    def sum_count_f64(num_aggs: Int) -> AggLayout:
        """Build a 16B-per-slot layout of ACC_SUM_COUNT_F64.

        Intended for SUM+COUNT-only shapes.
        Callers MUST guarantee that no MIN/MAX / variance / stddev is
        needed on any of these slots -- those fields are not stored.
        """
        var tags = List[UInt8](capacity=num_aggs)
        for _ in range(num_aggs):
            tags.append(ACC_SUM_COUNT_F64)
        return AggLayout(tags^)

    @always_inline
    def slot_tag(self, agg_idx: Int) -> UInt8:
        """Return the AccTag for slot agg_idx."""
        return self.tags[agg_idx]

    @always_inline
    def slot_offset(self, agg_idx: Int) -> Int:
        """Byte offset of slot agg_idx from the agg-region base."""
        return self.offsets[agg_idx]

    @always_inline
    def slot_width(self, agg_idx: Int) -> Int:
        """Width in bytes of slot agg_idx."""
        return self.widths[agg_idx]


# -----------------------------------------------------------------------------
# Sanity helpers for tests / debug asserts.
# -----------------------------------------------------------------------------

def agg_layout_is_quartet(layout: AggLayout) -> Bool:
    """True if every slot is ACC_SUM_COUNT_MIN_MAX_F64 (32B).

    The scatter path assumes this shape; a layout for which this is False
    needs the width-aware merge decoder.
    """
    for i in range(layout.num_aggs):
        if layout.tags[i] != ACC_SUM_COUNT_MIN_MAX_F64:
            return False
    return True


# -----------------------------------------------------------------------------
# Plan-time layout selection
# -----------------------------------------------------------------------------
#
# Callers that construct `FlatHashAggregator` / `PerfectHashAggregator` want
# a single place to decide "narrow or quartet?" based on the planner's
# `AggExprArray`. The rule (intentionally conservative):
#
#   - Every agg is SUM or COUNT (no MIN/MAX/AVG/CountDistinct)
#     AND every value column the planner binds is Float64-compatible
#   -> `sum_count_f64(num_aggs)` (16B/slot, sum+count only)
#
#   - Otherwise
#   -> `default_quartet(num_aggs)` (32B/slot, sum/count/min/max)
#
# The "Float64-compatible" check is delegated to the caller -- most call
# sites already know the column types via `build_agg_commit_plan`. Callers
# that can't cheaply check dtype should pass `f64_values=False`, which
# forces the quartet layout (safe default).
#
# The accumulator tier is picked from the agg expression kind at plan
# time. Do NOT call this from hot paths -- it is plan-time only.


def _agg_exprs_all_sum_or_count(agg_exprs: List[UInt8]) -> Bool:
    """Return True iff every agg in `agg_exprs.func` is SUM or COUNT.

    The callers pass a List[UInt8] of AggExpr.func bytes (AGG_SUM=0,
    AGG_COUNT=1). This helper keeps the module free of a dependency on
    `komira_plan_expr.agg_expr` (which would create a cross-layer import
    cycle).
    """
    for i in range(len(agg_exprs)):
        var f = agg_exprs[i]
        # AGG_SUM = 0, AGG_COUNT = 1. Other values (MIN=2, MAX=3, MEAN=4,
        # COUNT_DISTINCT=5, FIRST=6, LAST=7) force quartet.
        if f != UInt8(0) and f != UInt8(1):
            return False
    return True


def select_agg_layout(
    var agg_func_bytes: List[UInt8],
    f64_values: Bool = True,
) -> AggLayout:
    """Plan-time layout picker.

    Args:
        agg_func_bytes: AggExpr.func (one UInt8 per agg). Consumed.
        f64_values: True when every SUM's value column is Float64-
            compatible. Callers who can't cheaply check pass False to
            force the quartet fallback.

    Returns:
        `sum_count_f64`(n) if both predicates hold, else default_quartet(n).
    """
    var n = len(agg_func_bytes)
    if n > 0 and f64_values and _agg_exprs_all_sum_or_count(agg_func_bytes):
        _ = agg_func_bytes^  # consume
        return AggLayout.sum_count_f64(n)
    _ = agg_func_bytes^  # consume
    return AggLayout.default_quartet(n)


# PERF-CRITICAL: when True, SUM+COUNT-only queries use the narrow 16B
# layout; when False every call site gets the 32B default_quartet layout.
# The commit hot path derives each entry pointer fresh from the slot index
# (`agg._entry_ptr(slot)`), so the compiler tracks the borrow through
# `agg._entries` and the narrow layout is safe across aggregator teardown.
comptime _NARROW_LAYOUT_ENABLED: Bool = True


# -----------------------------------------------------------------------------
# layout_for_num_aggs_and_funcs -- the one-stop call-site helper
# -----------------------------------------------------------------------------
#
# Most call sites already have `num_aggs: Int` plus access to a container
# of AggExpr. Rather than every call site opening the AggExpr and building
# a List[UInt8], this helper accepts a pre-built List[UInt8] of `.func`
# bytes. The convention: call sites compute the bytes with a small loop
# right next to the `FlatHashAggregator(...)` construction, immediately
# followed by `FlatHashAggregator.with_layout(num_keys, layout_for_...(...))`.
#
# When the gate is disabled (`_NARROW_LAYOUT_ENABLED == False`) every
# callsite gets the default_quartet layout without touching call-site code.


def layout_for_funcs(var agg_func_bytes: List[UInt8]) -> AggLayout:
    """Build an AggLayout from a list of AggExpr.func bytes.

    Gated: when `_NARROW_LAYOUT_ENABLED` is False the return is always
    default_quartet regardless of input. When True, routes through
    select_agg_layout with f64_values=True (the pipeline always stores
    sum/count as Float64 regardless of input dtype, so
    the narrow layout is correct for any numeric input).
    """
    if not _NARROW_LAYOUT_ENABLED:
        var n = len(agg_func_bytes)
        _ = agg_func_bytes^
        return AggLayout.default_quartet(n)
    return select_agg_layout(agg_func_bytes^, True)
