# =============================================================================
# asof_kernel -- the ASOF search kernels: the best match of one left value in
# a right equi-key group
# =============================================================================
#
#   * `AsofValue`: a tagged Int32 / Int64 / Float64 scalar (one ASOF sample).
#   * `equi_keys_equal_int64`: one INT64 equi-key column compared at two rows.
#   * `_partition_point_with_hint` / `_lower_bound_with_hint`: upper and lower
#     bound in an ascending run, galloping out from a hint and then a binary
#     search. A left run that is ascending within a group carries the last
#     answer as the next hint, which makes a dense run O(1) per probe.
#   * `_find_best_asof[strategy, dtype]`: one body, the strategy a comptime
#     branch, so each (strategy, dtype) pair is its own monomorph with no
#     run-time strategy branch in the loop.
#
# THE ORDER. Every comparison of two ASOF values goes through
# `komira_op_sort.sort.sort_key_lt`, the order the sort that prepares the
# right group uses. For integers that is `<`. For floats it is DuckDB's total
# order: NaN above every other value (+inf included) and equal to every NaN,
# and -0.0 equal to +0.0. A kernel that compared with the IEEE operators would
# disagree with its own input's order on NaN, and a NaN probe would miss the
# NaN rows DuckDB matches (`NaN >= NaN` is true there).
#
# THE DISTANCE (NEAREST and tolerance). Integers: the exact magnitude of the
# difference as a UInt64, so a difference past Int64's range does not wrap.
# Floats: |a - b|, 0 for two equal values (two NaNs, two infinities of one
# sign), and +inf when exactly one side is NaN, so a NaN is never nearer than
# a number and never within a finite tolerance of one.
#
# Tolerance is inclusive: a match at distance == tolerance is kept. NEAREST
# breaks a distance tie toward the earlier (backward) candidate. DuckDB has no
# NEAREST and no tolerance; these are the engine's own and keep this rule.
# =============================================================================

from std.math import inf, isnan

from komira_op_sort.sort import sort_key_lt
from komira_plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    AsofTolerance,
)


comptime ASOF_VAL_INT32: UInt8 = 0
comptime ASOF_VAL_INT64: UInt8 = 1
comptime ASOF_VAL_FLOAT64: UInt8 = 2


@fieldwise_init
struct AsofValue(ImplicitlyCopyable, Movable):
    """A tagged ASOF-column scalar (Int32 / Int64 / Float64). Only the payload
    field `tag` names carries meaning."""

    var tag: UInt8
    var int32_val: Int32
    var int64_val: Int64
    var float64_val: Float64

    @staticmethod
    def int32(v: Int32) -> AsofValue:
        return AsofValue(
            tag=ASOF_VAL_INT32, int32_val=v, int64_val=Int64(0),
            float64_val=Float64(0.0),
        )

    @staticmethod
    def int64(v: Int64) -> AsofValue:
        return AsofValue(
            tag=ASOF_VAL_INT64, int32_val=Int32(0), int64_val=v,
            float64_val=Float64(0.0),
        )

    @staticmethod
    def float64(v: Float64) -> AsofValue:
        return AsofValue(
            tag=ASOF_VAL_FLOAT64, int32_val=Int32(0), int64_val=Int64(0),
            float64_val=v,
        )

    @always_inline
    def abs_diff_f64(self, other: AsofValue) -> Float64:
        """The distance between `self` and `other` as a Float64 (the module
        header's distance). Both must carry the same tag."""
        if self.tag == ASOF_VAL_INT32:
            return Float64(
                _abs_diff_int(Int64(self.int32_val), Int64(other.int32_val))
            )
        elif self.tag == ASOF_VAL_INT64:
            return Float64(_abs_diff_int(self.int64_val, other.int64_val))
        else:
            return _abs_diff_float(self.float64_val, other.float64_val)


@always_inline
def equi_keys_equal_int64(
    left: List[Int64], left_idx: Int, right: List[Int64], right_idx: Int
) -> Bool:
    """One INT64 equi-key column: `left[left_idx] == right[right_idx]`. NULLs
    are the caller's (this column carries no validity)."""
    return left[left_idx] == right[right_idx]


# =============================================================================
# The order and the distance
# =============================================================================


@always_inline
def _le[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) -> Bool:
    """`a` sorts at or before `b` (`sort_key_lt` order)."""
    return not sort_key_lt[dtype](b, a)


@always_inline
def _abs_diff_int(a: Int64, b: Int64) -> UInt64:
    """|a - b| exactly, as a UInt64 (no wrap past Int64's range)."""
    if a >= b:
        return a.cast[DType.uint64]() - b.cast[DType.uint64]()
    return b.cast[DType.uint64]() - a.cast[DType.uint64]()


@always_inline
def _abs_diff_float(a: Float64, b: Float64) -> Float64:
    """|a - b|; 0 for equal values (NaN equals NaN), +inf for a NaN against a
    number."""
    var a_nan = isnan(a)
    var b_nan = isnan(b)
    if a_nan and b_nan:
        return Float64(0.0)
    if a_nan or b_nan:
        return inf[DType.float64]()
    if a == b:
        return Float64(0.0)
    var d = a - b
    if d < Float64(0.0):
        d = -d
    return d


@always_inline
def _diff_le[dtype: DType](
    a0: Scalar[dtype], b0: Scalar[dtype], a1: Scalar[dtype], b1: Scalar[dtype]
) -> Bool:
    """`dist(a0, b0) <= dist(a1, b1)`."""
    comptime if dtype.is_floating_point():
        return _abs_diff_float(Float64(a0), Float64(b0)) <= _abs_diff_float(
            Float64(a1), Float64(b1)
        )
    else:
        return _abs_diff_int(Int64(a0), Int64(b0)) <= _abs_diff_int(
            Int64(a1), Int64(b1)
        )


# =============================================================================
# Bounds with a hint
# =============================================================================


@always_inline
def _partition_point_with_hint[dtype: DType](
    values: List[Scalar[dtype]], n: Int, target: Scalar[dtype], hint: Int
) -> Int:
    """The smallest `i` in `[0, n]` with `values[i]` after `target` (upper
    bound), searching out from `hint` (any value; clamped to [0, n]).

    PERF-CRITICAL: called once per left row in the walker's loop.
    """
    if n <= 0:
        return 0
    var h = hint
    if h < 0:
        h = 0
    if h > n:
        h = n

    var lo: Int
    var hi: Int
    if h < n and _le[dtype](values[h], target):
        # Gallop forward to a window [lo, hi) with values[hi] after target.
        lo = h
        var step = 1
        hi = h + step
        while hi < n and _le[dtype](values[hi], target):
            lo = hi
            step = step << 1
            hi = hi + step
        if hi > n:
            hi = n
    else:
        # Gallop backward to a window [lo, hi) with lo == 0 or values[lo - 1]
        # at or before target.
        hi = h
        var step = 1
        lo = h - step
        while lo > 0 and not _le[dtype](values[lo], target):
            hi = lo
            step = step << 1
            lo = h - step
        if lo < 0:
            lo = 0

    while lo < hi:
        var mid = lo + ((hi - lo) >> 1)
        if _le[dtype](values[mid], target):
            lo = mid + 1
        else:
            hi = mid
    return lo


@always_inline
def _partition_point[dtype: DType](
    values: List[Scalar[dtype]], n: Int, target: Scalar[dtype]
) -> Int:
    """`_partition_point_with_hint` from hint 0."""
    return _partition_point_with_hint[dtype](values, n, target, 0)


@always_inline
def _lower_bound_with_hint[dtype: DType](
    values: List[Scalar[dtype]], n: Int, target: Scalar[dtype], hint: Int
) -> Int:
    """The smallest `i` in `[0, n]` with `values[i]` at or after `target`
    (lower bound), searching out from `hint`.

    PERF-CRITICAL: called once per left row in the FORWARD and NEAREST loops.
    """
    if n <= 0:
        return 0
    var h = hint
    if h < 0:
        h = 0
    if h > n:
        h = n

    var lo: Int
    var hi: Int
    if h < n and sort_key_lt[dtype](values[h], target):
        lo = h
        var step = 1
        hi = h + step
        while hi < n and sort_key_lt[dtype](values[hi], target):
            lo = hi
            step = step << 1
            hi = hi + step
        if hi > n:
            hi = n
    else:
        hi = h
        var step = 1
        lo = h - step
        while lo > 0 and not sort_key_lt[dtype](values[lo], target):
            hi = lo
            step = step << 1
            lo = h - step
        if lo < 0:
            lo = 0

    while lo < hi:
        var mid = lo + ((hi - lo) >> 1)
        if sort_key_lt[dtype](values[mid], target):
            lo = mid + 1
        else:
            hi = mid
    return lo


@always_inline
def _lower_bound[dtype: DType](
    values: List[Scalar[dtype]], n: Int, target: Scalar[dtype]
) -> Int:
    """`_lower_bound_with_hint` from hint 0."""
    return _lower_bound_with_hint[dtype](values, n, target, 0)


# =============================================================================
# Tolerance
# =============================================================================


@always_inline
def _tolerance_exceeds[dtype: DType](
    left_ts: Scalar[dtype], right_ts: Scalar[dtype], tolerance: AsofTolerance
) -> Bool:
    """True iff the match must be rejected: the distance exceeds the
    tolerance. Always False without a tolerance. A float column takes a
    FLOAT64 tolerance and an integer column an INT64 one (the planner checks
    the pair); a negative integer tolerance rejects every match."""
    if tolerance.is_none():
        return False
    comptime if dtype.is_floating_point():
        return (
            _abs_diff_float(Float64(left_ts), Float64(right_ts))
            > tolerance.float_val
        )
    else:
        if tolerance.int_val < 0:
            return True
        return _abs_diff_int(
            Int64(left_ts), Int64(right_ts)
        ) > tolerance.int_val.cast[DType.uint64]()


# =============================================================================
# _find_best_asof -- one body, a monomorph per (strategy, dtype)
# =============================================================================


@always_inline
def _find_best_asof[strategy: UInt8, dtype: DType](
    left_ts: Scalar[dtype],
    right_asof: List[Scalar[dtype]],
    right_group_len: Int,
    tolerance: AsofTolerance,
    mut lo_hint: Int,
    mut best_idx: Int,
):
    """The best match of `left_ts` in `right_asof[0:right_group_len]` (one
    equi-key group, ascending in `sort_key_lt` order, no NULLs).

    Sets `best_idx` to the index of the match, or -1, and `lo_hint` to the
    search result for the next left row of the group (the caller resets it to
    0 at a new group).

      * ASOF_BACKWARD (DuckDB `left.t >= right.t`): the last value at or
        before `left_ts`; among equal values the last one.
      * ASOF_FORWARD (DuckDB `left.t <= right.t`): the first value at or after
        `left_ts`; among equal values the first one.
      * ASOF_NEAREST: the nearer of those two candidates (the module header's
        distance); a tie takes the backward one.

    Then the tolerance (inclusive) may reject the match.

    PERF-CRITICAL: the strategy is a comptime branch; one arm per monomorph.
    """
    if right_group_len <= 0:
        best_idx = -1
        return

    comptime if strategy == ASOF_BACKWARD:
        var lo = _partition_point_with_hint[dtype](
            right_asof, right_group_len, left_ts, lo_hint
        )
        lo_hint = lo
        if lo == 0:
            best_idx = -1
            return
        var cand = lo - 1
        if _tolerance_exceeds[dtype](left_ts, right_asof[cand], tolerance):
            best_idx = -1
            return
        best_idx = cand

    elif strategy == ASOF_FORWARD:
        var lo = _lower_bound_with_hint[dtype](
            right_asof, right_group_len, left_ts, lo_hint
        )
        lo_hint = lo
        if lo >= right_group_len:
            best_idx = -1
            return
        if _tolerance_exceeds[dtype](left_ts, right_asof[lo], tolerance):
            best_idx = -1
            return
        best_idx = lo

    else:
        comptime assert strategy == ASOF_NEAREST, "unknown ASOF strategy"
        var lo = _lower_bound_with_hint[dtype](
            right_asof, right_group_len, left_ts, lo_hint
        )
        lo_hint = lo
        var have_left = lo > 0
        var have_right = lo < right_group_len
        if not have_left and not have_right:
            best_idx = -1
            return
        var cand: Int
        if have_left and have_right:
            if _diff_le[dtype](
                left_ts, right_asof[lo - 1], right_asof[lo], left_ts
            ):
                cand = lo - 1  # a tie takes the backward candidate
            else:
                cand = lo
        elif have_left:
            cand = lo - 1
        else:
            cand = lo
        if _tolerance_exceeds[dtype](left_ts, right_asof[cand], tolerance):
            best_idx = -1
            return
        best_idx = cand
