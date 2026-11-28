# =============================================================================
# The as-of join segment: a SINK_ASOF_JOIN segment over the rows of a right
# segment it depends on
# =============================================================================
#
# Plans of two segments built by hand and run through `run_plan` and
# `RealBuilder` on a dispatcher that runs the workers inline: segment 0 reads
# the resident right batch (key rk, time rt, value v) and collects it;
# segment 1 reads the resident left batch (key lk, time lt), depends on
# segment 0 over an E3 edge and ends in SINK_ASOF_JOIN, whose
# `AsofJoinSinkData` names segment 0 as its right side.
#
# What these tests prove:
#   * The rows are the as-of join of the two batches, on 1, 2, 3 and 7 workers
#     and morsels of 2 and 5 rows: each left row once, BACKWARD with the right
#     row of its key at the latest time at or before its own, the first of two
#     right rows tied at that time, NULL right columns where none is, and
#     neither side's order sorted on input. FORWARD takes the earliest at or
#     after.
#   * The same plan run twice on one builder gives the same rows.
#   * A left side with no row gives no row under the node's output schema.
#   * Refused by name: a right segment that is not among the segment's
#     dependencies, a `sink_param_id` naming no as-of sink data, an as-of
#     sink with a key type (it is served with KEY_DTYPE_NONE only), a sink built
#     before its segment's source took the right rows (or after the source of
#     another segment did), and the output read before it is combined.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from async_api.token import CancellationToken
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import (
    AsofJoinSinkData,
    EDGE_E3_PUBLISH_WAIT,
    KEY_DTYPE_I64,
    KEY_DTYPE_NONE,
    SINK_ASOF_JOIN,
    SINK_ORIENT_COLUMNAR,
    SegmentDescPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import batch_segment
from pipeline_exec.published_outputs import PublishedOutputs
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_builder import SegmentBuilder
from pipeline_exec.sink_asof_join import AsofSink
from plan_expr.expr_pool import ExprPool
from plan_ir.logical_plan import ASOF_BACKWARD, ASOF_FORWARD, AsofTolerance

comptime _NULL: Int64 = -999
"""A cell the fixtures write as NULL, and the readers show as NULL."""


def _batch(names: List[String], var cols: List[List[Int64]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    for c in range(len(names)):
        sb.add_field(Field(names[c], ArrowType.INT64, True))
        var col = ColumnBuilder[DType.int64].with_capacity(len(cols[c]))
        for r in range(len(cols[c])):
            if cols[c][r] == _NULL:
                col.append_null()
            else:
                col.append(cols[c][r])
        b.add_column(col^.materialize())
    return b.build(sb.build())


def _left() raises -> RecordBatch:
    # Key 1 at 25, 10, 5 and 30; key 2 at 15 and 50; key 3 at 7; a NULL key.
    var cols = List[List[Int64]]()
    cols.append([1, 2, 1, 3, 1, 2, _NULL, 1])
    cols.append([25, 15, 10, 7, 5, 50, 20, 30])
    return _batch(["lk", "lt"], cols^)


def _right() raises -> RecordBatch:
    # Key 1 at 20, 10 and 30; key 2 twice at 15 (v 4 first, then 5) and at 40.
    var cols = List[List[Int64]]()
    cols.append([1, 2, 1, 2, 2, 1])
    cols.append([20, 15, 10, 40, 15, 30])
    cols.append([200, 4, 100, 400, 5, 300])
    return _batch(["rk", "rt", "v"], cols^)


def _empty_left() raises -> RecordBatch:
    var cols = List[List[Int64]]()
    cols.append(List[Int64]())
    cols.append(List[Int64]())
    return _batch(["lk", "lt"], cols^)


def _out_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("lk", ArrowType.INT64, True))
    sb.add_field(Field("lt", ArrowType.INT64, True))
    sb.add_field(Field("rk", ArrowType.INT64, True))
    sb.add_field(Field("rt", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    return sb.build()


def _data(strategy: UInt8, right_seg: Int = 0) -> AsofJoinSinkData:
    var lk: List[String] = ["lk"]
    var rk: List[String] = ["rk"]
    return AsofJoinSinkData(
        lk^,
        rk^,
        "lt",
        "rt",
        strategy,
        AsofTolerance.none(),
        List[String](),
        List[Bool](),
        List[String](),
        List[Bool](),
        _out_schema(),
        asof_dtype=DType.int64,
        right_seg_id=right_seg,
    )


def _asof_segment(
    seg_id: Int, handle: Int, param: Int, dep: Int, morsel_rows: Int
) -> SegmentDescPod:
    var desc = batch_segment(seg_id, handle, morsel_rows=morsel_rows)
    desc.sink_kind = SINK_ASOF_JOIN
    desc.sink_key_dtype = KEY_DTYPE_NONE
    desc.sink_orientation = SINK_ORIENT_COLUMNAR
    desc.sink_param_id = param
    if dep >= 0:
        desc.deps.append(dep)
        desc.edge_tags.append(EDGE_E3_PUBLISH_WAIT)
    return desc^


def _plan(
    left: Int, right: Int, param: Int, morsel_rows: Int, dep: Int = 0
) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(batch_segment(0, right, morsel_rows=morsel_rows))
    out.append(_asof_segment(1, left, param, dep, morsel_rows))
    return out^


def _run[
    B: SegmentBuilder
](ref descs: List[SegmentDescPod], mut builder: B, workers: Int) raises -> PublishedOutputs:
    var dispatch = InlineDispatch()
    return run_plan(descs, builder, dispatch, workers, CancellationToken.new())


def _cell(ref batch: RecordBatch, c: Int, r: Int) raises -> String:
    if batch.column_at(c).is_null_at(r):
        return "NULL"
    return String(batch.column_at(c).as_primitive[DType.int64]().get(r))


def _rows(ref batch: RecordBatch) raises -> List[String]:
    """Each row as `lk lt -> rk rt v`, sorted (the sink emits its left rows in
    its sorted order)."""
    var out = List[String]()
    for r in range(batch.num_rows()):
        var row = _cell(batch, 0, r) + " " + _cell(batch, 1, r) + " ->"
        for c in range(2, batch.num_columns()):
            row += " " + _cell(batch, c, r)
        out.append(row^)
    sort(out)
    return out^


def _backward_rows() -> List[String]:
    var out: List[String] = [
        "1 10 -> 1 10 100",
        "1 25 -> 1 20 200",
        "1 30 -> 1 30 300",
        "1 5 -> NULL NULL NULL",
        "2 15 -> 2 15 4",
        "2 50 -> 2 40 400",
        "3 7 -> NULL NULL NULL",
        "NULL 20 -> NULL NULL NULL",
    ]
    sort(out)
    return out^


def _forward_rows() -> List[String]:
    var out: List[String] = [
        "1 10 -> 1 10 100",
        "1 25 -> 1 30 300",
        "1 30 -> 1 30 300",
        "1 5 -> 1 10 100",
        "2 15 -> 2 15 4",
        "2 50 -> NULL NULL NULL",
        "3 7 -> NULL NULL NULL",
        "NULL 20 -> NULL NULL NULL",
    ]
    sort(out)
    return out^


def _expect(got: List[String], want: List[String], label: String) raises:
    var g = String("")
    for i in range(len(got)):
        g += got[i] + "\n"
    var w = String("")
    for i in range(len(want)):
        w += want[i] + "\n"
    assert_equal(g, w, label)


def test_the_rows_are_the_as_of_join_on_every_worker_count() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_left())
    var right = builder.add_resident(_right())
    var backward = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var forward = builder.add_asof_sink(_data(ASOF_FORWARD))
    var workers: List[Int] = [1, 2, 3, 7]
    var sizes: List[Int] = [2, 5]
    for s in range(len(sizes)):
        for w in range(len(workers)):
            var label = (
                "morsel " + String(sizes[s]) + ", workers " + String(workers[w])
            )
            var b = _plan(left, right, backward, sizes[s])
            var out = _run(b, builder, workers[w])
            _expect(_rows(out.take(1)), _backward_rows(), "backward " + label)
            var f = _plan(left, right, forward, sizes[s])
            var fout = _run(f, builder, workers[w])
            _expect(_rows(fout.take(1)), _forward_rows(), "forward " + label)


def test_the_same_plan_run_twice_on_one_builder_gives_the_same_rows() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_left())
    var right = builder.add_resident(_right())
    var p = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var descs = _plan(left, right, p, 3)
    var first = _run(descs, builder, 3)
    _expect(_rows(first.take(1)), _backward_rows(), "first run")
    var second = _run(descs, builder, 2)
    _expect(_rows(second.take(1)), _backward_rows(), "second run")
    assert_equal(builder.pool_granted(), 0)


def test_a_left_side_with_no_row_gives_no_row_under_the_node_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_empty_left())
    var right = builder.add_resident(_right())
    var p = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var descs = _plan(left, right, p, 4)
    var out = _run(descs, builder, 2)
    var batch = out.take(1)
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 5)
    assert_equal(batch.schema.field_name(4), "v")


def _refusal[
    B: SegmentBuilder
](ref descs: List[SegmentDescPod], mut builder: B) raises -> String:
    try:
        _ = _run(descs, builder, 1)
    except e:
        return String(e)
    return String("")


def test_a_right_segment_that_is_not_a_dependency_is_refused() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_left())
    var right = builder.add_resident(_right())
    var p = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var descs = _plan(left, right, p, 4, dep=-1)
    var m = _refusal(descs, builder)
    assert_true(
        "the as-of join of segment 1 reads its right side from segment 0,"
        " which is not among its dependencies" in m,
        m,
    )


def test_a_param_naming_no_sink_data_is_refused() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_left())
    var right = builder.add_resident(_right())
    _ = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var high = _plan(left, right, 3, 4)
    var m = _refusal(high, builder)
    assert_true(
        "segment 1 names as-of join sink data 3, and the builder holds 1" in m,
        m,
    )
    var low = _plan(left, right, -1, 4)
    m = _refusal(low, builder)
    assert_true(
        "segment 1 names as-of join sink data -1, and the builder holds 1" in m,
        m,
    )


def test_a_sink_built_before_its_source_took_the_right_rows_is_refused() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_left())
    var right = builder.add_resident(_right())
    var p = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var descs = _plan(left, right, p, 4)
    var schema = _left().schema.copy()
    # No source built yet.
    try:
        _ = builder.build_sink(descs[1], schema)
        assert_true(False, "a sink with no right rows was built")
    except e:
        assert_true(
            "the as-of join sink of segment 1 was built before its source took"
            " the right rows" in String(e),
            String(e),
        )
    # The source of segment 1 took them; segment 2's sink is not theirs.
    var published = PublishedOutputs(descs)
    published.publish(0, _right())
    _ = builder.build_source(descs[1], published, 1)
    var other = _asof_segment(2, left, p, 0, 4)
    try:
        _ = builder.build_sink(other, schema)
        assert_true(False, "a sink took another segment's right rows")
    except e:
        assert_true(
            "the as-of join sink of segment 2 was built before" in String(e),
            String(e),
        )


def test_an_asof_sink_with_a_key_type_is_not_served() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var left = builder.add_resident(_left())
    var right = builder.add_resident(_right())
    var p = builder.add_asof_sink(_data(ASOF_BACKWARD))
    var descs = _plan(left, right, p, 4)
    descs[1].sink_key_dtype = KEY_DTYPE_I64
    var m = _refusal(descs, builder)
    assert_true("the sink of segment 1 is not served" in m, m)
    assert_true(
        "(SINK_ASOF_JOIN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)" in m, m
    )


def test_the_output_read_before_it_is_combined_is_refused() raises:
    var sink = AsofSink(_data(ASOF_BACKWARD), _right(), Optional(_left().schema.copy()))
    try:
        _ = sink.take_output()
        assert_true(False, "an uncombined as-of sink answered")
    except e:
        assert_true(
            "the as-of join sink was read before it was combined" in String(e),
            String(e),
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_rows_are_the_as_of_join_on_every_worker_count]()
    suite.test[test_the_same_plan_run_twice_on_one_builder_gives_the_same_rows]()
    suite.test[test_a_left_side_with_no_row_gives_no_row_under_the_node_schema]()
    suite.test[test_a_right_segment_that_is_not_a_dependency_is_refused]()
    suite.test[test_a_param_naming_no_sink_data_is_refused]()
    suite.test[test_a_sink_built_before_its_source_took_the_right_rows_is_refused]()
    suite.test[test_an_asof_sink_with_a_key_type_is_not_served]()
    suite.test[test_the_output_read_before_it_is_combined_is_refused]()
    suite^.run()
