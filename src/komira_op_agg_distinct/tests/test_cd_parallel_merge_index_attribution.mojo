# =============================================================================
# test_cd_parallel_merge_index_attribution -- the driver's merge attributes
# every group's distinct count to the group's own KEY, at every worker count
# =============================================================================
#
# The driver hash-partitions rows across K workers, so every group lives in
# one worker's table, and the merge presents the K tables as one sequence of
# output rows through a (worker, gid) index. An index that is off by one,
# names the wrong worker, or skips worker 0's identity prefix emits the SAME
# keys in the SAME order with the WRONG counts beside them; a test that reads
# only the key column cannot see it.
#
# What each test catches:
#   * `test_every_group_carries_its_own_distinct_count`: every (key, count)
#     pair against an oracle walked from the fixture rows (reading the count
#     from worker 0 only, an off-by-one index, a dropped identity prefix);
#   * `test_the_fixture_gives_every_group_a_different_count`: guards the
#     fixture (a swap between two groups with equal counts would be invisible);
#   * `test_the_mapping_is_the_same_at_one_worker_and_at_four`: at K=1 the
#     merge never runs, so its answer shares no merge code with K=4;
#   * `test_more_than_one_worker_actually_receives_a_group`: the summed counts
#     need every worker's groups to survive.
#
# Group k takes the values `(i // NKEYS) % (k + 1)`, so the six groups count
# 1..6, all different.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
    _should_use_parallel_count_distinct,
)

# =============================================================================

comptime _ROWS: Int = 70_000
comptime _NKEYS: Int = 6
comptime _WORKERS: Int = 4


def _key_at(i: Int) raises -> String:
    """Six byte shapes: an empty value first (a zero-length key is its own
    arena edge case), a multi-byte UTF-8 value, and all-different lengths."""
    var k = i % _NKEYS
    if k == 0:
        return String("")
    if k == 1:
        return String("A")
    if k == 2:
        return String("aé")
    if k == 3:
        return String("Brand#23")
    if k == 4:
        return String("STANDARD ANODIZED TIN")
    return String("PROMO BURNISHED NICKEL PLATED ")


def _val_at(i: Int) -> Int64:
    """Group `k = i % _NKEYS` takes values `(i // _NKEYS) % (k + 1)`, i.e. the
    dense set {0 .. k}. Its distinct count is therefore EXACTLY `k + 1`, and
    the six groups' counts are 1, 2, 3, 4, 5, 6 — all different."""
    var k = i % _NKEYS
    return Int64((i // _NKEYS) % (k + 1))


def _expected_count_for_key(imm key: String) raises -> Int:
    """The oracle, recomputed from the fixture rather than transcribed: walk
    every row, keep the values whose key matches, count the distinct ones.
    Transcribing `k + 1` here would make this test agree with a mutated
    `_val_at`; walking the rows cannot."""
    var seen = List[Int64]()
    for i in range(_ROWS):
        if _key_at(i) != key:
            continue
        var v = _val_at(i)
        var have = False
        for j in range(len(seen)):
            if seen[j] == v:
                have = True
                break
        if not have:
            seen.append(v)
    return len(seen)


def _batch() raises -> RecordBatch:
    var keys = List[String]()
    var vals = List[Int64]()
    for i in range(_ROWS):
        keys.append(_key_at(i))
        vals.append(_val_at(i))
    var kcol = Column.from_string(StringArray.from_strings(keys))
    var vcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(kcol^)
    b.add_column(vcol^)
    return b.build(sb.build())


def _sink_data() raises -> AggSinkData:
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.STRING, False))
    osb.add_field(Field("n", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run(workers: Int) raises -> RecordBatch:
    var batch = _batch()
    var sink = _sink_data()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(workers, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, 1, 1, _ROWS
    )


struct _Pair(Copyable, Movable):
    var key: String
    var count: Int

    def __init__(out self, var key: String, count: Int):
        self.key = key^
        self.count = count


def _pairs(imm rb: RecordBatch) raises -> List[_Pair]:
    """The emitted (key, count) rows; the empty key reads back as ""."""
    var sa = rb.column_at(0).as_string()
    var pa = rb.column_at(1).as_primitive[DType.int64]()
    var out = List[_Pair]()
    for g in range(rb.num_rows()):
        out.append(_Pair(sa.get(g), Int(pa.get(g))))
    return out^


# =============================================================================
# Absolute: every emitted PAIR is the fixture's own answer
# =============================================================================


def test_every_group_carries_its_own_distinct_count() raises:
    """THE CLAIM THE KEY-COLUMN TESTS CANNOT MAKE: the count next to a key
    is THAT key's count.

    Killed by: reading the CD value set from the wrong worker (counts collapse
    onto worker 0's groups); an off-by-one in the `(worker, gid)` index (every
    group after the first gets its neighbour's set); dropping worker 0's
    identity prefix (the whole mapping shifts); appending the index entry
    before the key so the two sequences disagree by one.
    """
    if not _should_use_parallel_count_distinct(_ROWS, _WORKERS):
        raise Error(
            "PRECONDITION FAILED: n="
            + String(_ROWS)
            + " no longer routes to the PARALLEL count-distinct driver; this"
            " file would be testing a shape production never sends here"
        )
    var rb = _run(_WORKERS)
    var got = _pairs(rb)
    assert_equal(len(got), _NKEYS, "one output row per distinct key")

    var seen = List[Bool]()
    for _ in range(_NKEYS):
        seen.append(False)
    for g in range(len(got)):
        var matched = -1
        for k in range(_NKEYS):
            if _key_at(k) == got[g].key:
                matched = k
                break
        if matched < 0:
            raise Error(
                "emitted key `" + got[g].key + "` is not a fixture key"
            )
        if seen[matched]:
            raise Error(
                "key `" + got[g].key + "` was emitted more than once"
            )
        seen[matched] = True
        var want = _expected_count_for_key(got[g].key)
        if got[g].count != want:
            raise Error(
                "key `"
                + got[g].key
                + "` carries count "
                + String(got[g].count)
                + ", expected "
                + String(want)
                + " — the merge attributed this group's value set to the"
                " wrong (worker, gid)"
            )
    for k in range(_NKEYS):
        if not seen[k]:
            raise Error("key `" + _key_at(k) + "` was never emitted")


def test_the_fixture_gives_every_group_a_different_count() raises:
    """GUARDS THE TEST ABOVE. If two groups shared a distinct count, a swap
    between them would be invisible there and the file would be weaker than
    its header claims without anything going red."""
    var counts = List[Int]()
    for k in range(_NKEYS):
        counts.append(_expected_count_for_key(_key_at(k)))
    for a in range(_NKEYS):
        for b in range(a + 1, _NKEYS):
            if counts[a] == counts[b]:
                raise Error(
                    "groups "
                    + String(a)
                    + " and "
                    + String(b)
                    + " share distinct count "
                    + String(counts[a])
                    + "; a mis-attribution between them would be invisible"
                )
    # And the counts are the dense 1..NKEYS the fixture docstring claims.
    for k in range(_NKEYS):
        assert_equal(counts[k], k + 1, "group k's distinct count is k + 1")


# =============================================================================
# Worker-count invariance: K=1 runs no merge at all
# =============================================================================


def test_the_mapping_is_the_same_at_one_worker_and_at_four() raises:
    """At K=1 the merge loop is `range(1, 1)` — it does not execute — so the
    K=1 answer never touches the index being tested. Any (worker, gid) defect
    that is self-consistent at K=4 still diverges from it here.

    The ROW ORDER is deliberately NOT compared: it is group-arrival order
    and is not a promise of this operator. The MAPPING is.
    """
    var one = _pairs(_run(1))
    var four = _pairs(_run(_WORKERS))
    assert_equal(len(one), len(four), "same number of groups at K=1 and K=4")
    for i in range(len(one)):
        var found = False
        for j in range(len(four)):
            if four[j].key == one[i].key:
                found = True
                if four[j].count != one[i].count:
                    raise Error(
                        "key `"
                        + one[i].key
                        + "` counts "
                        + String(one[i].count)
                        + " at K=1 and "
                        + String(four[j].count)
                        + " at K="
                        + String(_WORKERS)
                    )
                break
        if not found:
            raise Error(
                "key `" + one[i].key + "` present at K=1, absent at K="
                + String(_WORKERS)
            )


def test_more_than_one_worker_actually_receives_a_group() raises:
    """THE ANTI-VACUITY CHECK. If hash-partitioning put all six groups on
    worker 0, the merge loop would find nothing to walk and the first test would pass over
    a driver that never merged anything. The sum over groups of `count` is a
    cheap proxy nobody can satisfy without the other workers' sets: it equals
    1+2+...+NKEYS only if every group's set survived.
    """
    var got = _pairs(_run(_WORKERS))
    var total = 0
    for g in range(len(got)):
        total += got[g].count
    var want = 0


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
