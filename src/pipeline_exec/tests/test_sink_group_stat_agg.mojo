# =============================================================================
# MEDIAN, QUANTILE_CONT and the variance family in the grouped sinks
# =============================================================================
#
# The rows have an INT64 key `k`, the same key as a STRING `s` ("g<k>"), and
# an INT64 value `x`; key 3 has one value, key 4 only NULL values, and one row
# in 17 has a NULL key. The grouped sinks (`GroupAggSink` over `k`,
# `StringGroupAggSink` over `s`) fold MEDIAN, STDDEV_SAMP, STDDEV_POP,
# VAR_SAMP, VAR_POP and QUANTILE_CONT at 0.25 and 0.75 of `x`; the answer of
# each group is held to the ungrouped sink's over that group's rows alone
# (whose answers `test_sink_stat_agg` holds to DuckDB's). What the tests
# prove:
#
#   * Grouped equals ungrouped per group, the NULL key included: the quantiles
#     exactly, the variances to 1e-12, on one, two and five workers, with the
#     rows dealt in order and in reverse, and folding by position.
#   * A group of one value has NULL sample forms and 0.0 population forms; a
#     group of only NULL values is NULL in every one of the seven.
#   * The values a group keeps are moved into the merged group of their
#     worker group, so a group whose rows sit on every worker is whole.

from std.testing import TestSuite, assert_almost_equal, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import KEY_DTYPE_I64
from pipeline_exec.plan_harness import grouped_agg_data, ungrouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from pipeline_exec.sink_group_agg import GroupAggSink
from pipeline_exec.sink_string_group_agg import StringGroupAggSink
from plan_expr.agg_expr import (
    AGG_MEDIAN,
    AGG_QUANTILE_CONT,
    AGG_STDDEV_POP,
    AGG_STDDEV_SAMP,
    AGG_VAR_POP,
    AGG_VAR_SAMP,
    AggExpr,
)
from plan_expr.expr import Expr
from plan_expr.scalar_value import ScalarValue

comptime N_AGGS = 7
comptime ROWS = 120
comptime NULL_KEY = -1
comptime KEYS = 6


@fieldwise_init
struct _Row(Copyable, Movable):
    var key: Int
    var val: Optional[Int]


def _rows() -> List[_Row]:
    """Row r: key r % KEYS (NULL where r % 17 == 9); value
    (r * 7919) % 101 - 50, NULL where r % 5 == 2. Key 3 keeps one value and
    key 4 none."""
    var out = List[_Row]()
    var three_seen = False
    for r in range(ROWS):
        var key = NULL_KEY if r % 17 == 9 else r % KEYS
        var v = Optional[Int]((r * 7919) % 101 - 50)
        if r % 5 == 2 or key == 4:
            v = None
        if key == 3:
            if three_seen:
                v = None
            elif v:
                three_seen = True
        out.append(_Row(key, v))
    return out^


def _batch(ref rows: List[_Row], start: Int, end: Int) raises -> RecordBatch:
    var kc = ColumnBuilder[DType.int64].with_capacity(end - start)
    var xc = ColumnBuilder[DType.int64].with_capacity(end - start)
    var strs = List[String]()
    var valid = List[Bool]()
    for i in range(start, end):
        if rows[i].key == NULL_KEY:
            kc.append_null()
            strs.append("")
            valid.append(False)
        else:
            kc.append(Int64(rows[i].key))
            strs.append("g" + String(rows[i].key))
            valid.append(True)
        if rows[i].val:
            xc.append(Int64(rows[i].val.value()))
        else:
            xc.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(kc^.materialize())
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(strs, valid))
    )
    sb.add_field(Field("x", ArrowType.INT64, True))
    rb.add_column(xc^.materialize())
    return rb.build(sb.build())


def _agg(func: UInt8) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref("x")), None)


def _quantile(q: Float64) -> AggExpr:
    return AggExpr(
        AGG_QUANTILE_CONT,
        Optional(Expr.col_ref("x")),
        Optional(Expr.literal(ScalarValue.from_float(q))),
        None,
    )


def _seven() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_MEDIAN))
    aggs.append(_agg(AGG_STDDEV_SAMP))
    aggs.append(_agg(AGG_STDDEV_POP))
    aggs.append(_agg(AGG_VAR_SAMP))
    aggs.append(_agg(AGG_VAR_POP))
    aggs.append(_quantile(0.25))
    aggs.append(_quantile(0.75))
    return aggs^


def _schema(key: ArrowType, keyed: Bool) raises -> Schema:
    var sb = SchemaBuilder()
    if keyed:
        sb.add_field(Field("key", key, True))
    for i in range(N_AGGS):
        sb.add_field(Field("a" + String(i), ArrowType.FLOAT64, True))
    return sb.build()


def _keys(col: String) -> Slab[Expr]:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref(col))
    return keys^


def _fixed(workers: Int, reverse: Bool, by_position: Bool) raises -> RecordBatch:
    var rows = _rows()
    var sink = GroupAggSink(
        grouped_agg_data(_keys("k"), _seven(), _schema(ArrowType.INT64, True)),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
        by_position=by_position,
    )
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < ROWS:
        var end = min(start + 7, ROWS)
        var w = m % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(_batch(rows, start, end), m, 0))
        start = end
        m += 1
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _string(workers: Int, reverse: Bool, by_position: Bool) raises -> RecordBatch:
    var rows = _rows()
    var sink = StringGroupAggSink(
        grouped_agg_data(_keys("s"), _seven(), _schema(ArrowType.STRING, True)),
        False,
        SegmentPool(),
        0,
        by_position=by_position,
    )
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < ROWS:
        var end = min(start + 7, ROWS)
        var w = m % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(_batch(rows, start, end), m, 0))
        start = end
        m += 1
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _group_rows(key: Int) -> List[_Row]:
    var all = _rows()
    var out = List[_Row]()
    for i in range(len(all)):
        if all[i].key == key:
            out.append(all[i].copy())
    return out^


def _ungrouped(key: Int) raises -> RecordBatch:
    """The seven aggregates of the rows of `key` alone, by the ungrouped
    sink."""
    var rows = _group_rows(key)
    var sink = AggSink(
        ungrouped_agg_data(_seven(), _schema(ArrowType.INT64, False)),
        SegmentPool(),
        0,
    )
    sink.resize_worker_state(1)
    if len(rows) > 0:
        sink.consume(0, Morsel(_batch(rows, 0, len(rows)), 0, 0))
    var pipeline = PipelineExecution(1, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _key_of(ref out: RecordBatch, row: Int, strings: Bool) raises -> Int:
    if out.column_at(0).is_null_at(row):
        return NULL_KEY
    if strings:
        var s = String(out.column_at(0).as_string().get(row))
        for k in range(KEYS):
            if s == "g" + String(k):
                return k
        raise Error("an unexpected string key " + s)
    return Int(out.column_at(0).as_primitive[DType.int64]().get(row))


def _check_groups(ref out: RecordBatch, strings: Bool, what: String) raises:
    assert_equal(out.num_rows(), KEYS + 1, what + ": groups")
    var seen = List[Bool](length=KEYS + 1, fill=False)
    for row in range(out.num_rows()):
        var key = _key_of(out, row, strings)
        var slot = KEYS if key == NULL_KEY else key
        assert_true(not seen[slot], what + ": key " + String(key) + " twice")
        seen[slot] = True
        var want = _ungrouped(key)
        for i in range(N_AGGS):
            var label = what + ": key " + String(key) + ", aggregate " + String(i)
            var got_null = out.column_at(1 + i).is_null_at(row)
            assert_equal(got_null, want.column_at(i).is_null_at(0), label)
            if got_null:
                continue
            var got = out.column_at(1 + i).as_primitive[DType.float64]().get(row)
            var exp = want.column_at(i).as_primitive[DType.float64]().get(0)
            if i == 0 or i >= 5:
                assert_equal(got, exp, label)
            else:
                assert_almost_equal(got, exp, rtol=1e-12, msg=label)


def test_grouped_equals_ungrouped_per_group_on_fixed_width_keys() raises:
    for workers in [1, 2, 5]:
        for rev in range(2):
            for bp in range(2):
                var what = (
                    "INT64 key, "
                    + String(workers)
                    + " workers, reverse "
                    + String(rev)
                    + ", by position "
                    + String(bp)
                )
                _check_groups(_fixed(workers, rev == 1, bp == 1), False, what)


def test_grouped_equals_ungrouped_per_group_on_string_keys() raises:
    for workers in [1, 2, 5]:
        for rev in range(2):
            for bp in range(2):
                var what = (
                    "STRING key, "
                    + String(workers)
                    + " workers, reverse "
                    + String(rev)
                    + ", by position "
                    + String(bp)
                )
                _check_groups(_string(workers, rev == 1, bp == 1), True, what)


def test_one_value_and_only_null_groups() raises:
    var out = _fixed(3, False, False)
    for row in range(out.num_rows()):
        var key = _key_of(out, row, False)
        if key == 3:
            # One value: the sample forms NULL, the population forms 0.0.
            assert_true(out.column_at(2).is_null_at(row), "STDDEV_SAMP")
            assert_true(out.column_at(4).is_null_at(row), "VAR_SAMP")
            var pop = out.column_at(3).as_primitive[DType.float64]()
            assert_equal(pop.get(row), 0.0, "STDDEV_POP of one value")
            var vpop = out.column_at(5).as_primitive[DType.float64]()
            assert_equal(vpop.get(row), 0.0, "VAR_POP of one value")
            assert_true(not out.column_at(1).is_null_at(row), "MEDIAN")
        if key == 4:
            for i in range(N_AGGS):
                assert_true(
                    out.column_at(1 + i).is_null_at(row),
                    "only NULLs: aggregate " + String(i),
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
