# =============================================================================
# COUNT(DISTINCT x) in the grouped aggregation sinks: refusals and memory
# =============================================================================
#
# The same sinks and the same hand-fed morsels as `test_sink_count_distinct_
# grouped`. What they prove:
#
#   * test_what_the_grouped_sinks_refuse_when_they_are_built: no argument and a
#     declared type other than INT64, by exact message, in both sinks.
#   * test_what_the_grouped_sinks_refuse_when_they_run: an argument type that is
#     not served, a value column that changes type between a worker's morsels,
#     and one that differs between workers (refused at combine), by exact
#     message.
#   * test_a_pool_too_small_for_the_distinct_entries_is_refused_by_name: after
#     the group table fits, in both sinks, and the pool is whole after.
#   * test_a_pool_too_small_for_the_merge_is_refused_and_returned: workers that
#     fit and a merge that does not, in both sinks; with room for the merge the
#     same morsels give the oracle's counts.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.primitive_array import PrimitiveArray
from arrow.string_array import StringArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import (
    AggSinkData,
    KEY_DTYPE_I64,
)
from pipeline_exec.group_table import GroupTable
from pipeline_exec.plan_harness import grouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_group_agg import GroupAggSink
from pipeline_exec.sink_string_group_agg import StringGroupAggSink
from pipeline_exec.string_harness import FORM_FLAT, key_batch
from plan_expr.agg_expr import AGG_COUNT_DISTINCT, AggExpr
from plan_expr.expr import Expr

comptime NUL: Int = -999999
"""In a list of test values: this row is NULL."""


def _cd(col: String) -> AggExpr:
    return AggExpr(AGG_COUNT_DISTINCT, Optional(Expr.col_ref(col)), None)


def _key_exprs(name: String) -> Slab[Expr]:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref(name))
    return keys^


def _combine_and_take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _combine_and_take_s(
    mut sink: StringGroupAggSink, workers: Int
) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _i64_at(ref out: RecordBatch, col: Int, row: Int) raises -> Int:
    assert_equal(out.schema.field_arrow_type(col), ArrowType.INT64)
    return Int(out.column_at(col).as_primitive[DType.int64]().get(row))


def _count_at(ref out: RecordBatch, col: Int, row: Int) raises -> Int:
    """A count column's value, which is never NULL."""
    assert_false(out.column_at(col).is_null_at(row))
    return _i64_at(out, col, row)


def _key_at(ref out: RecordBatch, row: Int) raises -> Int:
    if out.column_at(0).is_null_at(row):
        return NUL
    return _i64_at(out, 0, row)


def _out_text(ref out: RecordBatch, col: Int, row: Int) raises -> String:
    if out.column_at(col).is_null_at(row):
        return "NULL"
    return "S:" + out.column_at(col).as_string().get(row)


def _kvw_batch(
    keys: List[Int], vals: List[Int], ws: List[Int], lo: Int, hi: Int
) raises -> RecordBatch:
    """Rows `lo` to `hi - 1` of the key `k`, and the values `v` and `w`."""
    var k = ColumnBuilder[DType.int64].with_capacity(hi - lo)
    var v = ColumnBuilder[DType.int64].with_capacity(hi - lo)
    var w = ColumnBuilder[DType.int64].with_capacity(hi - lo)
    for r in range(lo, hi):
        if keys[r] == NUL:
            k.append_null()
        else:
            k.append(Int64(keys[r]))
        if vals[r] == NUL:
            v.append_null()
        else:
            v.append(Int64(vals[r]))
        if ws[r] == NUL:
            w.append_null()
        else:
            w.append(Int64(ws[r]))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(k^.materialize())
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    sb.add_field(Field("w", ArrowType.INT64, True))
    rb.add_column(w^.materialize())
    return rb.build(sb.build())


# --- refusals -----------------------------------------------------------------


def _cd_schema(key_type: ArrowType, count_type: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", key_type, True))
    sb.add_field(Field("n", count_type, False))
    return sb.build()


def _fixed_built(var aggs: Slab[AggExpr], count_type: ArrowType) raises -> String:
    try:
        _ = GroupAggSink(
            grouped_agg_data(
                _key_exprs("k"), aggs^, _cd_schema(ArrowType.INT64, count_type)
            ),
            KEY_DTYPE_I64,
            SegmentPool(),
            0,
        )
    except e:
        return String(e)
    return String("")


def _string_built(var aggs: Slab[AggExpr], count_type: ArrowType) raises -> String:
    try:
        _ = StringGroupAggSink(
            grouped_agg_data(
                _key_exprs("k"), aggs^, _cd_schema(ArrowType.STRING, count_type)
            ),
            False,
            SegmentPool(),
            0,
        )
    except e:
        return String(e)
    return String("")


def _one_agg(var a: AggExpr) -> Slab[AggExpr]:
    var out = Slab[AggExpr]()
    out.append(a^)
    return out^


def test_what_the_grouped_sinks_refuse_when_they_are_built() raises:
    assert_equal(
        _fixed_built(
            _one_agg(AggExpr(AGG_COUNT_DISTINCT, None, None)), ArrowType.INT64
        ),
        "pipeline_exec: the grouped aggregation sink of segment 0:"
        " COUNT(DISTINCT) (output column 1) has no argument",
    )
    assert_equal(
        _string_built(
            _one_agg(AggExpr(AGG_COUNT_DISTINCT, None, None)), ArrowType.INT64
        ),
        "pipeline_exec: the string-keyed aggregation sink of segment 0:"
        " COUNT(DISTINCT) (output column 1) has no argument",
    )
    var declared = (
        "pipeline_exec: COUNT(DISTINCT) (output column 1) cannot produce the"
        " declared output type float64 of column 1"
    )
    assert_equal(_fixed_built(_one_agg(_cd("v")), ArrowType.FLOAT64), declared)
    assert_equal(_string_built(_one_agg(_cd("v")), ArrowType.FLOAT64), declared)
    assert_equal(_fixed_built(_one_agg(_cd("v")), ArrowType.INT64), "")
    assert_equal(_string_built(_one_agg(_cd("v")), ArrowType.INT64), "")


def _v_u32_batch() raises -> RecordBatch:
    """Key `k` (INT64) and a UINT32 column `v`."""
    var k = PrimitiveArray[DType.int64].allocate(2)
    k.set(0, Int64(1))
    k.set(1, Int64(2))
    var v = PrimitiveArray[DType.uint32].allocate(2)
    v.set(0, UInt32(1))
    v.set(1, UInt32(2))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    sb.add_field(Field("v", ArrowType.UINT32, False))
    rb.add_column(Column.from_primitive[DType.uint32](v^))
    return rb.build(sb.build())


def _kv_data_only_v() raises -> AggSinkData:
    return grouped_agg_data(
        _key_exprs("k"),
        _one_agg(_cd("v")),
        _cd_schema(ArrowType.INT64, ArrowType.INT64),
    )


def _fixed_feed_error(
    sink: GroupAggSink, w: Int, idx: Int, var batch: RecordBatch
) raises -> String:
    try:
        sink.consume(w, Morsel(batch^, idx, 0))
    except e:
        return String(e)
    return String("")


def _int_pair(lo: Int, hi: Int) raises -> RecordBatch:
    var vals = List[Int]()
    for r in range(lo, hi):
        vals.append(r)
    return _kvw_batch(vals, vals, vals, 0, len(vals))


def _string_value_batch() raises -> RecordBatch:
    """Key `k` (INT64) and a STRING column `v`."""
    var k = PrimitiveArray[DType.int64].allocate(1)
    k.set(0, Int64(1))
    var names = List[String](["a"])
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    sb.add_field(Field("v", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rb.build(sb.build())


def test_what_the_grouped_sinks_refuse_when_they_run() raises:
    var unserved = (
        "pipeline_exec: COUNT(DISTINCT) (output column 1) is not served over"
        " this column type (uint32): COUNT(DISTINCT) takes INT8 to INT64,"
        " DATE32, FLOAT32, FLOAT64, DECIMAL128 and strings"
    )
    var fixed = GroupAggSink(_kv_data_only_v(), KEY_DTYPE_I64, SegmentPool(), 0)
    fixed.resize_worker_state(2)
    assert_equal(_fixed_feed_error(fixed, 0, 0, _v_u32_batch()), unserved)
    # A column that changes type between the morsels of a worker.
    var changed = (
        "pipeline_exec: COUNT(DISTINCT) (output column 1) saw a column of"
        " another type than the morsels before it"
    )
    assert_equal(_fixed_feed_error(fixed, 1, 1, _int_pair(0, 3)), "")
    assert_equal(
        _fixed_feed_error(fixed, 1, 2, _string_value_batch()), changed
    )
    # Two workers that read the argument as different types: refused when
    # their entries are merged.
    var apart = GroupAggSink(_kv_data_only_v(), KEY_DTYPE_I64, SegmentPool(), 0)
    apart.resize_worker_state(2)
    assert_equal(_fixed_feed_error(apart, 0, 0, _int_pair(0, 3)), "")
    assert_equal(
        _fixed_feed_error(apart, 1, 1, _string_value_batch()), ""
    )
    with assert_raises(
        contains=(
            "pipeline_exec: COUNT(DISTINCT) (output column 1) saw columns of"
            " different types on different workers"
        )
    ):
        _ = _combine_and_take(apart, 2)
    # The string-keyed sink, over string keys `s1` and a UINT32 value.
    var strs = StringGroupAggSink(
        grouped_agg_data(
            _key_exprs("s1"),
            _one_agg(_cd("v")),
            _cd_schema(ArrowType.STRING, ArrowType.INT64),
        ),
        False,
        SegmentPool(),
        0,
    )
    strs.resize_worker_state(2)
    var bad = String("")
    try:
        strs.consume(0, Morsel(_s1_u32_batch(), 0, 0))
    except e:
        bad = String(e)
    assert_equal(bad, unserved)
    var ok = List[String](["a", "b"])
    var ok_valid = List[Bool]([True, True])
    strs.consume(1, Morsel(key_batch(ok, ok_valid, FORM_FLAT), 1, 0))
    var changed_to_string = String("")
    try:
        strs.consume(1, Morsel(_s1_string_value_batch(), 2, 0))
    except e:
        changed_to_string = String(e)
    assert_equal(changed_to_string, changed)


def _s1_u32_batch() raises -> RecordBatch:
    """String key `s1` and a UINT32 column `v`."""
    var v = PrimitiveArray[DType.uint32].allocate(2)
    v.set(0, UInt32(1))
    v.set(1, UInt32(2))
    var values = List[String](["a", "b"])
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("s1", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(values)))
    sb.add_field(Field("v", ArrowType.UINT32, False))
    rb.add_column(Column.from_primitive[DType.uint32](v^))
    return rb.build(sb.build())


def _s1_string_value_batch() raises -> RecordBatch:
    """String key `s1` and a STRING column `v`."""
    var values = List[String](["a", "b"])
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("s1", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(values)))
    sb.add_field(Field("v", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(values)))
    return rb.build(sb.build())


# --- memory ------------------------------------------------------------------


def _fixed_budget_sink(ref pool: SegmentPool) raises -> GroupAggSink:
    return GroupAggSink(_kv_data_only_v(), KEY_DTYPE_I64, pool.share(), 0)


def _string_budget_sink(ref pool: SegmentPool) raises -> StringGroupAggSink:
    return StringGroupAggSink(
        grouped_agg_data(
            _key_exprs("s1"),
            _one_agg(_cd("v")),
            _cd_schema(ArrowType.STRING, ArrowType.INT64),
        ),
        False,
        pool.share(),
        0,
    )


def test_a_pool_too_small_for_the_distinct_entries_is_refused_by_name() raises:
    var entries = 64 * GroupTable(4, 0).per_group_bytes()
    # The group table of one key and one aggregate fits, the first entries of
    # the distinct values do not.
    var table = 64 * GroupTable(1, 1).per_group_bytes()
    var budget = table + entries // 2
    var pool = SegmentPool(budget)
    var fixed = _fixed_budget_sink(pool)
    fixed.resize_worker_state(1)
    assert_equal(
        _fixed_feed_error(fixed, 0, 0, _int_pair(0, 3)),
        "MEMORY_BUDGET_EXCEEDED: pipeline_exec: the grouped aggregation sink"
        " of segment 0 was denied "
        + String(entries)
        + " bytes of the segment's memory pool for its COUNT(DISTINCT) values"
        " (budget "
        + String(budget)
        + ", granted "
        + String(table)
        + ")",
    )
    _ = fixed^
    assert_equal(pool.granted(), 0)
    # The string-keyed sink also holds its key strings: 64 entries of 28 bytes
    # and an arena of 1024 bytes. The message says how much was denied.
    var held = 64 * 28 + 1024 + table
    var sbudget = held + entries // 2
    var spool = SegmentPool(sbudget)
    var strs = _string_budget_sink(spool)
    strs.resize_worker_state(1)
    var names = List[String](["a", "b"])
    var valid = List[Bool]([True, True])
    var failure = String("")
    try:
        strs.consume(0, Morsel(key_batch(names, valid, FORM_FLAT), 0, 0))
    except e:
        failure = String(e)
    assert_true(
        "pipeline_exec: the string-keyed aggregation sink of segment 0 was"
        " denied " + String(entries) + " bytes of the segment's memory pool"
        " for its COUNT(DISTINCT) values (budget " + String(sbudget) + ", "
        "granted " in failure,
        failure,
    )
    _ = strs^
    assert_equal(spool.granted(), 0)


def _fixed_two_workers(ref pool: SegmentPool) raises -> GroupAggSink:
    var sink = _fixed_budget_sink(pool)
    sink.resize_worker_state(2)
    var keys = List[Int]([1, 2, 3, 2, 3, 4])
    var vals = List[Int]([10, 20, 30, 20, 31, 40])
    sink.consume(0, Morsel(_kvw_batch(keys, vals, vals, 0, 3), 0, 0))
    sink.consume(1, Morsel(_kvw_batch(keys, vals, vals, 3, 6), 1, 0))
    return sink^


def _string_two_workers(ref pool: SegmentPool) raises -> StringGroupAggSink:
    var sink = _string_budget_sink(pool)
    sink.resize_worker_state(2)
    var names = List[String](["a", "b", "c"])
    var more = List[String](["b", "c", "d"])
    var valid = List[Bool]([True, True, True])
    # key_batch holds the row number plus one as `v`: 1 to 3 on both workers,
    # so `v` repeats across workers and differs inside a group.
    sink.consume(0, Morsel(key_batch(names, valid, FORM_FLAT), 0, 0))
    sink.consume(1, Morsel(key_batch(more, valid, FORM_FLAT), 1, 0))
    return sink^


def test_a_pool_too_small_for_the_merge_is_refused_and_returned() raises:
    var probe = SegmentPool(1 << 22)
    var measured = _fixed_two_workers(probe)
    var held = probe.granted()
    _ = measured^
    assert_equal(probe.granted(), 0)
    # Room for the workers and the merged group table, nothing for the merged
    # entries.
    var tight = SegmentPool(held + 65536)
    var sink = _fixed_two_workers(tight)
    with assert_raises(contains="for its COUNT(DISTINCT) values"):
        _ = _combine_and_take(sink, 2)
    _ = sink^
    assert_equal(tight.granted(), 0)
    # With room for both the same morsels give the oracle's counts: keys 1 and
    # 4 hold one value, 2 holds {20}, 3 holds {30, 31}.
    var roomy = SegmentPool(held + 2 * 65536)
    var ok = _fixed_two_workers(roomy)
    var out = _combine_and_take(ok, 2)
    assert_equal(out.num_rows(), 4)
    for i in range(out.num_rows()):
        var key = _key_at(out, i)
        assert_equal(_count_at(out, 1, i), 2 if key == 3 else 1)
    assert_equal(roomy.granted(), 0)
    # The string-keyed sink.
    var sprobe = SegmentPool(1 << 22)
    var smeasured = _string_two_workers(sprobe)
    var sheld = sprobe.granted()
    _ = smeasured^
    assert_equal(sprobe.granted(), 0)
    var stight = SegmentPool(sheld + 65536)
    var ssink = _string_two_workers(stight)
    with assert_raises(contains="for its COUNT(DISTINCT) values"):
        _ = _combine_and_take_s(ssink, 2)
    _ = ssink^
    assert_equal(stight.granted(), 0)
    var sroomy = SegmentPool(sheld + 2 * 65536)
    var sok = _string_two_workers(sroomy)
    var sout = _combine_and_take_s(sok, 2)
    # a: {1}, b: {2} and {1}, c: {3} and {2}, d: {3}.
    assert_equal(sout.num_rows(), 4)
    for i in range(sout.num_rows()):
        var key = _out_text(sout, 0, i)
        assert_equal(_count_at(sout, 1, i), 2 if (key == "S:b" or key == "S:c") else 1)
    assert_equal(sroomy.granted(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
