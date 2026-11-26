# =============================================================================
# The grouped sinks' float folds by position: chunks, mixed aggregates, types
# =============================================================================
#
# The cases beside test_sink_group_float_agg's table runs. The tests hand a
# grouped sink morsels directly, naming the worker and the source position of
# each. What they prove:
#
#   * Two chunks of one morsel (one position, consecutive on one worker) fold
#     into one position, row after row, and are not refused; positions that
#     share a partition id are ordered by their origin hint, whatever worker
#     and arrival order held them.
#   * Exact aggregates beside a float SUM by position (COUNT(*), an integer
#     SUM, COUNT(DISTINCT) of an integer, a float MIN) give their exact
#     answers on 4 workers; by position with no float aggregate, the integer
#     folds give the same answers.
#   * Folded by worker (ORDER_NONE), a float MIN, MAX and COUNT per group are
#     the model's on 4 and 16 workers in every dealing (no tie of zeros).
#   * An argument whose type changes between morsels is refused by name, by
#     the worker that met both, and at combine when two workers met one each.
#   * The string-keyed sink refuses a denied position entry by name.

from std.collections import Dict, Set
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

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
from pipeline_exec.plan_harness import grouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_group_agg import GroupAggSink
from pipeline_exec.sink_string_group_agg import StringGroupAggSink
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import Expr


def _ints(*xs: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _floats(*xs: Float64) -> List[Float64]:
    var out = List[Float64]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _names(*xs: String) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _kinds(*is_float: Bool) -> List[ArrowType]:
    """FLOAT64 for True, INT64 for False."""
    var out = List[ArrowType]()
    for i in range(len(is_float)):
        out.append(ArrowType.FLOAT64 if is_float[i] else ArrowType.INT64)
    return out^


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _batch(
    ref keys: List[Int],
    ref vals: List[Float64],
    start: Int,
    end: Int,
    float32: Bool = False,
) raises -> RecordBatch:
    """Rows `start` to `end`: key `k` (INT64), the key as a string `s`, an
    integer `i` (the key times 10 plus the row index modulo 3) and `d`, the
    value as FLOAT64, or FLOAT32 when `float32`."""
    var kc = ColumnBuilder[DType.int64].with_capacity(end - start)
    var ic = ColumnBuilder[DType.int64].with_capacity(end - start)
    var strs = List[String]()
    var valid = List[Bool]()
    for r in range(start, end):
        kc.append(Int64(keys[r]))
        ic.append(Int64(keys[r] * 10 + r % 3))
        strs.append("g" + String(keys[r]))
        valid.append(True)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(kc^.materialize())
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(strs, valid))
    )
    sb.add_field(Field("i", ArrowType.INT64, False))
    rb.add_column(ic^.materialize())
    if float32:
        var fc = ColumnBuilder[DType.float32].with_capacity(end - start)
        for r in range(start, end):
            fc.append(vals[r].cast[DType.float32]())
        sb.add_field(Field("d", ArrowType.FLOAT32, False))
        rb.add_column(fc^.materialize())
    else:
        var dc = ColumnBuilder[DType.float64].with_capacity(end - start)
        for r in range(start, end):
            dc.append(vals[r])
        sb.add_field(Field("d", ArrowType.FLOAT64, False))
        rb.add_column(dc^.materialize())
    return rb.build(sb.build())


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _sink(
    var aggs: Slab[AggExpr], var schema: Schema, by_position: Bool
) raises -> GroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k"))
    return GroupAggSink(
        grouped_agg_data(keys^, aggs^, schema^),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
        by_position=by_position,
    )


def _schema(names: List[String], types: List[ArrowType]) raises -> Schema:
    """Key `k` (INT64), then one column per name."""
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    for c in range(len(names)):
        sb.add_field(Field(names[c], types[c], True))
    return sb.build()


def _take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _row_of(ref b: RecordBatch) raises -> Dict[Int, Int]:
    var out = Dict[Int, Int]()
    for r in range(b.num_rows()):
        out[Int(b.column_at(0).as_primitive[DType.int64]().get(r))] = r
    return out^


def _f(ref b: RecordBatch, col: Int, row: Int) raises -> Float64:
    return b.column_at(col).as_primitive[DType.float64]().get(row)


def _i(ref b: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(b.column_at(col).as_primitive[DType.int64]().get(row))


def _sum_sink(by_position: Bool) raises -> GroupAggSink:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "d"))
    return _sink(aggs^, _schema(_names("s"), _kinds(True)), by_position)


# -----------------------------------------------------------------------------
# Chunks and origin hints
# -----------------------------------------------------------------------------


def test_chunks_of_one_morsel_fold_into_one_position() raises:
    # Group 0 only. Positions (5, 0), (5, 1) and (5, 2) share partition 5:
    # the hint orders them. (5, 1) reaches worker 0 as two chunks.
    var keys = _ints(0, 0, 0, 0, 0)
    var vals = _floats(1.0, 1e16, 1.0, -1e16, 0.5)
    var sink = _sum_sink(True)
    sink.resize_worker_state(2)
    sink.consume(1, Morsel(_batch(keys, vals, 3, 5), 0, 5, 2))
    sink.consume(0, Morsel(_batch(keys, vals, 1, 2), 1, 5, 1))
    sink.consume(0, Morsel(_batch(keys, vals, 2, 3), 2, 5, 1))
    sink.consume(1, Morsel(_batch(keys, vals, 0, 1), 3, 5, 0))
    var b = _take(sink, 2)
    # Runtime double additions, in the model's order.
    var zero: Float64 = 0.0
    var p0 = zero + vals[0]
    var p1 = (zero + vals[1]) + vals[2]
    var p2 = (zero + vals[3]) + vals[4]
    var want = ((zero + p0) + p1) + p2
    assert_equal(_bits(_f(b, 1, 0)), _bits(want))


# -----------------------------------------------------------------------------
# Exact aggregates beside a float one
# -----------------------------------------------------------------------------


def _mixed_rows(n: Int, mut keys: List[Int], mut vals: List[Float64]):
    for r in range(n):
        keys.append(r % 4)
        vals.append(Float64((r * 7919) % 1009 - 400) / 7.0)


def _mixed_sink(with_float: Bool) raises -> GroupAggSink:
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_agg(AGG_SUM, "i"))
    aggs.append(_agg(AGG_COUNT_DISTINCT, "i"))
    if with_float:
        aggs.append(_agg(AGG_SUM, "d"))
        aggs.append(_agg(AGG_MIN, "d"))
        return _sink(
            aggs^,
            _schema(
                _names("n", "si", "cd", "sd", "mn"),
                _kinds(False, False, False, True, True),
            ),
            True,
        )
    return _sink(
        aggs^,
        _schema(
            _names("n", "si", "cd"),
            _kinds(False, False, False),
        ),
        True,
    )


def _check_mixed(with_float: Bool) raises:
    var keys = List[Int]()
    var vals = List[Float64]()
    _mixed_rows(200, keys, vals)
    var rows = 9
    var sink = _mixed_sink(with_float)
    sink.resize_worker_state(4)
    var n = (len(keys) + rows - 1) // rows
    for k in range(n):
        var end = min((k + 1) * rows, len(keys))
        sink.consume(
            (k * 7 + k // 3) % 4,
            Morsel(_batch(keys, vals, k * rows, end), k, k, 0),
        )
    var b = _take(sink, 4)
    var at = _row_of(b)
    assert_equal(len(at), 4)
    for g in range(4):
        var count = 0
        var isum = 0
        var distinct = Set[Int]()
        var fsum = 0.0
        var mn = 0.0
        var start = 0
        while start < len(keys):
            var part = 0.0
            for r in range(start, min(start + rows, len(keys))):
                if keys[r] != g:
                    continue
                if count == 0 or vals[r] < mn:
                    mn = vals[r]
                count += 1
                isum += g * 10 + r % 3
                distinct.add(g * 10 + r % 3)
                part += vals[r]
            fsum += part
            start += rows
        var r = at[g]
        var tag = "group " + String(g)
        assert_equal(_i(b, 1, r), count, tag + " COUNT(*)")
        assert_equal(_i(b, 2, r), isum, tag + " SUM(i)")
        assert_equal(_i(b, 3, r), len(distinct), tag + " COUNT(DISTINCT i)")
        if with_float:
            assert_equal(_bits(_f(b, 4, r)), _bits(fsum), tag + " SUM(d)")
            assert_equal(_f(b, 5, r), mn, tag + " MIN(d)")


def test_exact_aggregates_beside_a_float_sum_by_position() raises:
    _check_mixed(True)


def test_by_position_with_no_float_aggregate_folds_the_integers() raises:
    _check_mixed(False)


def test_float_min_max_and_count_folded_by_worker() raises:
    var keys = List[Int]()
    var vals = List[Float64]()
    _mixed_rows(300, keys, vals)
    var workers = _ints(4, 16)
    for w in range(len(workers)):
        for dealing in range(3):
            var aggs = Slab[AggExpr]()
            aggs.append(_agg(AGG_MIN, "d"))
            aggs.append(_agg(AGG_MAX, "d"))
            aggs.append(_agg(AGG_COUNT, "d"))
            var sink = _sink(
                aggs^,
                _schema(
                    _names("mn", "mx", "c"),
                    _kinds(True, True, False),
                ),
                False,
            )
            sink.resize_worker_state(workers[w])
            var n = (len(keys) + 6) // 7
            for k in range(n):
                var worker = k % workers[w]
                if dealing == 1:
                    worker = workers[w] - 1 - worker
                elif dealing == 2:
                    worker = (k * 7 + k // 3) % workers[w]
                var end = min((k + 1) * 7, len(keys))
                sink.consume(
                    worker, Morsel(_batch(keys, vals, k * 7, end), k, k, 0)
                )
            var b = _take(sink, workers[w])
            var at = _row_of(b)
            for g in range(4):
                var mn = 1e300
                var mx = -1e300
                var c = 0
                for r in range(len(keys)):
                    if keys[r] == g:
                        mn = min(mn, vals[r])
                        mx = max(mx, vals[r])
                        c += 1
                var tag = (
                    String(workers[w])
                    + " workers, dealing "
                    + String(dealing)
                    + ", group "
                    + String(g)
                )
                assert_equal(_f(b, 1, at[g]), mn, tag + " MIN")
                assert_equal(_f(b, 2, at[g]), mx, tag + " MAX")
                assert_equal(_i(b, 3, at[g]), c, tag + " COUNT")


# -----------------------------------------------------------------------------
# Refusals
# -----------------------------------------------------------------------------


def test_an_argument_type_change_is_refused_by_name() raises:
    var keys = _ints(0, 1, 0, 1)
    var vals = _floats(1.5, 2.5, 3.5, 4.5)
    # One worker meets FLOAT64, then FLOAT32.
    var one = _sum_sink(True)
    one.resize_worker_state(1)
    one.consume(0, Morsel(_batch(keys, vals, 0, 2), 0, 0, 0))
    try:
        one.consume(0, Morsel(_batch(keys, vals, 2, 4, float32=True), 1, 1, 0))
        assert_true(False, "a FLOAT32 morsel after FLOAT64 was folded")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: SUM (output column 1) saw a column of another type"
            " or scale than the morsels before it",
        )
    # Two workers meet one type each: refused when merged.
    var two = _sum_sink(True)
    two.resize_worker_state(2)
    two.consume(0, Morsel(_batch(keys, vals, 0, 2), 0, 0, 0))
    two.consume(1, Morsel(_batch(keys, vals, 2, 4, float32=True), 1, 1, 0))
    var pipeline = PipelineExecution(2, 0)
    try:
        two.combine(pipeline)
        assert_true(False, "FLOAT64 and FLOAT32 workers were merged")
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: SUM (output column 1) saw columns of different"
            " types on different workers",
        )


def test_the_string_sink_refuses_a_denied_position_entry() raises:
    # Budgets grown 8 bytes at a time until one serves the morsel: the last
    # refusal before it is the position folds' (the intern and group tables
    # are charged first, so they are served by then).
    var keys = _ints(0, 1, 2, 3)
    var vals = _floats(1.0, 2.0, 3.0, 4.0)
    var budget = 0
    var refused = String("")
    while budget < 1 << 20:
        budget += 8
        var skeys = Slab[Expr]()
        skeys.append(Expr.col_ref("s"))
        var aggs = Slab[AggExpr]()
        aggs.append(_agg(AGG_SUM, "d"))
        var sb = SchemaBuilder()
        sb.add_field(Field("s", ArrowType.STRING, True))
        sb.add_field(Field("sd", ArrowType.FLOAT64, True))
        var sink = StringGroupAggSink(
            grouped_agg_data(skeys^, aggs^, sb.build()),
            False,
            SegmentPool(budget),
            0,
            by_position=True,
        )
        sink.resize_worker_state(1)
        try:
            sink.consume(0, Morsel(_batch(keys, vals, 0, 4), 0, 0, 0))
            break
        except e:
            refused = String(e)
    assert_true(
        refused.startswith(
            "MEMORY_BUDGET_EXCEEDED: pipeline_exec: the string-keyed"
            " aggregation sink of segment 0 was denied "
        ),
        refused,
    )
    assert_true(
        "bytes of the segment's memory pool for its float folds by source"
        " position (budget " in refused,
        refused,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
