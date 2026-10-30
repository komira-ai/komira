# =============================================================================
# The memory of the string-keyed sink: charged before it grows, refused by name
# =============================================================================
#
# The sink draws the bytes of its group tables and intern tables from the
# segment pool as they grow, and gives them back. What these tests prove:
#
#   * The pool is charged as the tables grow (more groups, more held, at least
#     the doubled capacity of the group table and of the intern table) and is
#     whole again after `take_output`.
#   * A budget the byte arena of the intern table outgrows (few groups, long
#     strings) fails the query by name, as the intern table's, and the pool is
#     never over its budget.
#   * A budget the group table outgrows while the strings stay few (two keys of
#     a hundred strings each give ten thousand groups) fails by name, as the
#     group table's.
#   * A budget that holds the workers' tables and not the merge's fails in
#     `combine` by name; with room for the merge the same tables merge. The
#     pool is whole after the refusal and after the sink is dropped.
#   * More distinct strings than an intern table holds are refused by name in
#     a worker and in the merge, where two workers' disjoint strings add up.
#   * A sink dropped without a combine returns what its workers hold.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import AggSinkData
from komira_pipeline_exec.group_table import GroupTable
from komira_pipeline_exec.plan_harness import grouped_agg_data
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_string_group_agg import StringGroupAggSink
from komira_plan_expr.agg_expr import AGG_COUNT, AggExpr
from komira_plan_expr.expr import Expr


def _data(two: Bool) raises -> AggSinkData:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("a"))
    if two:
        keys.append(Expr.col_ref("b"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.STRING, True))
    if two:
        sb.add_field(Field("b", ArrowType.STRING, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return grouped_agg_data(keys^, aggs^, sb.build())


def _sink(
    ref pool: SegmentPool,
    two: Bool = False,
    dict_encoded: Bool = False,
    max_strings: Int = 1 << 30,
) raises -> StringGroupAggSink:
    return StringGroupAggSink(
        _data(two), dict_encoded, pool.share(), 0, 1 << 30, max_strings
    )


def _text(r: Int, width: Int) -> String:
    """The string of row r, `width` bytes or a little more, distinct per r."""
    var s = String(r)
    while s.byte_length() < width:
        s += "."
    return s^


def _unique(start: Int, rows: Int, width: Int = 0) raises -> RecordBatch:
    var a = List[String]()
    for r in range(start, start + rows):
        a.append(_text(r, width))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(a)))
    return rb.build(sb.build())


def _pairs(first: Int, rows: Int, modulus: Int) raises -> RecordBatch:
    """Rows `first ..`: a = r // modulus, b = r % modulus, so `modulus`
    squared rows are as many distinct pairs, of 2 x modulus distinct strings."""
    var a = List[String]()
    var b = List[String]()
    for r in range(first, first + rows):
        a.append("a" + String(r // modulus))
        b.append("b" + String(r % modulus))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(a)))
    sb.add_field(Field("b", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(b)))
    return rb.build(sb.build())


def _combine_and_take(
    mut sink: StringGroupAggSink, workers: Int
) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def test_the_pool_is_charged_as_the_tables_grow_and_whole_after_take_output() raises:
    var pool = SegmentPool(1 << 30)
    var sink = _sink(pool)
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(_unique(0, 10), 0, 0))
    var small = pool.granted()
    var per_group = GroupTable(1, 1).per_group_bytes()
    assert_true(small >= 64 * (per_group + 28), "the first steps are not charged")
    for m in range(1, 6):
        sink.consume(0, Morsel(_unique(1000 * m - 990, 1000), m, 0))
    var big = pool.granted()
    # 5,010 groups and strings: both tables have doubled up to 8,192.
    assert_true(big >= 8192 * (per_group + 28), "the doublings are not charged")
    assert_true(big > small)
    var out = _combine_and_take(sink, 1)
    assert_equal(out.num_rows(), 5010)
    assert_equal(pool.granted(), 0)


def test_a_budget_the_string_bytes_outgrow_is_refused_by_name() raises:
    for dict_encoded in [False, True]:
        var pool = SegmentPool(100000)
        var sink = _sink(pool, False, dict_encoded)
        sink.resize_worker_state(1)
        # 300 strings of 500 bytes: 150 KB of arena against 100 KB.
        with assert_raises(contains="bytes of the segment's memory pool for its distinct key strings"):
            for m in range(3):
                sink.consume(0, Morsel(_unique(100 * m, 100, 500), m, 0))
        assert_true(pool.granted() <= 100000)
        _ = sink^
        assert_equal(pool.granted(), 0)


def test_a_budget_the_group_table_outgrows_is_refused_by_name() raises:
    var pool = SegmentPool(300000)
    var sink = _sink(pool, True)
    sink.resize_worker_state(1)
    # 10,000 pairs of 200 strings: the strings fit, the groups do not.
    with assert_raises(contains="bytes of the segment's memory pool for its groups"):
        for m in range(10):
            sink.consume(0, Morsel(_pairs(1000 * m, 1000, 100), m, 0))
    assert_true(pool.granted() <= 300000)
    _ = sink^
    assert_equal(pool.granted(), 0)


def _two_workers(ref pool: SegmentPool, groups: Int) raises -> StringGroupAggSink:
    """A sink whose two workers hold the same `groups` keys, so the merged
    tables hold `groups` and each worker's are as big as that."""
    var sink = _sink(pool)
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(_unique(0, groups, 24), 0, 0))
    sink.consume(1, Morsel(_unique(0, groups, 24), 1, 0))
    return sink^


def test_growth_past_the_budget_is_refused_by_name_in_the_merge() raises:
    # Measure what the two workers hold, whatever the layout is.
    var probe = SegmentPool(1 << 30)
    var measured = _two_workers(probe, 3000)
    var held = probe.granted()
    _ = measured^
    assert_equal(probe.granted(), 0)
    # Room for both workers and a quarter of that again: the merged tables,
    # about half of it, do not fit.
    var tight = SegmentPool(held + held // 4)
    var sink = _two_workers(tight, 3000)
    with assert_raises(contains="bytes of the segment's memory pool"):
        _ = _combine_and_take(sink, 2)
    _ = sink^
    assert_equal(tight.granted(), 0)
    # With room for the workers and the merged tables, the same tables merge.
    var roomy = SegmentPool(2 * held)
    var ok = _two_workers(roomy, 3000)
    assert_equal(_combine_and_take(ok, 2).num_rows(), 3000)
    assert_equal(roomy.granted(), 0)


def test_more_strings_than_an_intern_table_holds_are_refused_by_name() raises:
    # The limit is a parameter so the refusal can be reached with a few
    # strings. 128 fit in a worker, 129 do not.
    var pool = SegmentPool()
    var worker = _sink(pool, False, False, 128)
    worker.resize_worker_state(1)
    worker.consume(0, Morsel(_unique(0, 128), 0, 0))
    with assert_raises(contains="more distinct key strings than it holds"):
        worker.consume(0, Morsel(_unique(128, 1), 1, 0))
    # Two workers of 100 disjoint strings each fit alone; the merge's 200 do not.
    var merge = _sink(pool, False, False, 128)
    merge.resize_worker_state(2)
    merge.consume(0, Morsel(_unique(0, 100), 0, 0))
    merge.consume(1, Morsel(_unique(100, 100), 1, 0))
    with assert_raises(contains="more distinct key strings than it holds"):
        _ = _combine_and_take(merge, 2)
    _ = merge^
    _ = worker^
    assert_equal(pool.granted(), 0)


def test_a_sink_dropped_without_a_combine_returns_its_memory() raises:
    var pool = SegmentPool(1 << 30)
    var sink = _sink(pool)
    sink.resize_worker_state(3)
    for w in range(3):
        sink.consume(w, Morsel(_unique(100 * w, 100, 40), w, 0))
    assert_true(pool.granted() > 0)
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_pool_is_charged_as_the_tables_grow_and_whole_after_take_output]()
    suite.test[test_a_budget_the_string_bytes_outgrow_is_refused_by_name]()
    suite.test[test_a_budget_the_group_table_outgrows_is_refused_by_name]()
    suite.test[test_growth_past_the_budget_is_refused_by_name_in_the_merge]()
    suite.test[test_more_strings_than_an_intern_table_holds_are_refused_by_name]()
    suite.test[test_a_sink_dropped_without_a_combine_returns_its_memory]()
    suite^.run()
