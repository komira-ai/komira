# =============================================================================
# The parallel per-group finalize (`median_parallel_drain`)
# =============================================================================
#
# `parallel_group_finalize_column` finalizes each occupied group's state and
# appends one output column, fanning the groups out over the workers when
# there are at least `_MEDIAN_PARALLEL_MIN_GROUPS` of them. The answer must not
# depend on which way it ran. What each test proves:
#   * a finalize that writes group `si`'s answer into another row, skips a
#     slice, or reads `states[si]` instead of `states[slots[si]]` (the slots
#     here are a permutation over a larger state list, so both shapes differ);
#   * a parallel arm that never runs: the scheduler trace's fork count for the
#     median drain site is asserted, 0 below the gate and at least 1 above it,
#     so the value assertions cover both arms;
#   * a median that does not follow DuckDB's total order, in which NaN is the
#     largest value (a group whose middle value is NaN answers NaN; a group
#     with a NaN above the middle answers the median of the rest).
#
# The oracle is computed in the test: the values sorted with NaN last, the
# middle one, or the mean of the two middle ones.

from std.collections import List
from std.math import isnan
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder

from komira_agg.hash_agg_op_dt import HashAggOpAgg, MedianOp, MedianState

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import (
    SITE_MEDIAN_DRAIN,
    sched_trace_force_enable,
    sched_trace_reset,
    sched_trace_site,
)

from komira_op_agg_distinct.median_parallel_drain import (
    parallel_group_finalize_column,
)


comptime _WORKERS: Int = 4
comptime _Med = MedianOp[DType.float64]
comptime _Agg = HashAggOpAgg[_Med, 0]
# The scheduler trace's per-site fork count (`sched_trace_site` field 2).
comptime _FIELD_COUNT: Int32 = 2


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _value(g: Int, i: Int) -> Float64:
    return Float64(((g * 7_919 + i * 104_729) % 1_000) - 500) / 4.0


def _group_values(g: Int) -> List[Float64]:
    """Group g holds 1 + g % 9 values (odd and even counts). Every 50th group
    also holds NaNs: two of three values (the middle one is NaN), or one NaN
    above four values (the median is of the four)."""
    var out = List[Float64]()
    if g % 50 == 7:
        out.append(Float64.MAX)
        out.append(_value(g, 0))
        out.append(Float64(0) / Float64(0))
        out.append(Float64(0) / Float64(0))
        return out^
    if g % 50 == 21:
        for i in range(4):
            out.append(_value(g, i))
        out.append(Float64(0) / Float64(0))
        return out^
    for i in range(1 + g % 9):
        out.append(_value(g, i))
    return out^


def _oracle(imm vals: List[Float64]) -> Float64:
    var nums = List[Float64]()
    var nans = 0
    for i in range(len(vals)):
        if isnan(vals[i]):
            nans += 1
        else:
            nums.append(vals[i])
    sort(nums)
    for _ in range(nans):
        nums.append(Float64(0) / Float64(0))
    var n = len(nums)
    if n % 2 == 1:
        return nums[n // 2]
    return (nums[n // 2 - 1] + nums[n // 2]) / 2.0


def _same(a: Float64, b: Float64) -> Bool:
    if isnan(a) or isnan(b):
        return isnan(a) and isnan(b)
    return a == b


def _run(num_states: Int, imm slots: List[Int]) raises -> Tuple[List[Float64], UInt64]:
    """Finalize `slots` over `num_states` group states; return the column's
    values and how many times the median drain site forked."""
    var states = List[MedianState[DType.float64]](capacity=num_states)
    for g in range(num_states):
        var st = _Agg.init()
        var vals = _group_values(g)
        for i in range(len(vals)):
            _Med.update_scalar(st, vals[i])
        states.append(st^)
    # The dispatcher reads the trace switch when it is built, so the switch
    # is set first.
    sched_trace_force_enable(True)
    sched_trace_reset()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var rb = RecordBatchBuilder.with_capacity(1)
    parallel_group_finalize_column[_Agg](
        states, slots, rb, disp, CancellationToken.never()
    )
    var forks = sched_trace_site(SITE_MEDIAN_DRAIN, _FIELD_COUNT)
    rt.shutdown()
    sched_trace_force_enable(False)
    var sb = SchemaBuilder()
    sb.add_field(Field("m", ArrowType.FLOAT64, True))
    var batch = rb.build(sb.build())
    var col = batch.column_at(0).as_primitive[DType.float64]()
    var out = List[Float64](capacity=len(slots))
    for i in range(len(slots)):
        out.append(col.get(i))
    return (out^, forks)


def _check(num_states: Int, imm slots: List[Int], parallel: Bool) raises:
    var got = _run(num_states, slots)
    ref vals = got[0]
    assert_equal(len(vals), len(slots), "one row per occupied group")
    if parallel:
        assert_true(got[1] >= 1, "the parallel arm must have forked")
    else:
        assert_equal(got[1], UInt64(0), "below the gate the drain is serial")
    for si in range(len(slots)):
        var want = _oracle(_group_values(slots[si]))
        if not _same(vals[si], want):
            assert_equal(
                String(vals[si]), String(want),
                "row " + String(si) + " (group " + String(slots[si]) + ")",
            )


def _permuted_slots(num_states: Int, num_slots: Int) -> List[Int]:
    """`num_slots` distinct groups out of `num_states`, in a scattered order."""
    var out = List[Int](capacity=num_slots)
    for i in range(num_slots):
        out.append((i * 613 + 5) % num_states)
    return out^


def test_parallel_finalize_matches_the_oracle_in_slot_order() raises:
    # 1,000 of 1,201 groups (gcd(613, 1201) = 1, so all distinct).
    _check(1_201, _permuted_slots(1_201, 1_000), True)


def test_at_the_gate_the_drain_is_parallel() raises:
    _check(1_201, _permuted_slots(1_201, 256), True)


def test_below_the_gate_the_drain_is_serial_and_the_same() raises:
    _check(1_201, _permuted_slots(1_201, 255), False)
    _check(1_201, _permuted_slots(1_201, 3), False)


def test_no_groups_emits_an_empty_column() raises:
    var none = List[Int]()
    var got = _run(10, none)
    assert_equal(len(got[0]), 0, "no occupied group, no row")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
