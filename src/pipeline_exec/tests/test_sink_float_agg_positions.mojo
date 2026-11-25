# =============================================================================
# The ungrouped aggregation sink folding by source position (ORDER_ROW_RANGE)
# =============================================================================
#
# The tests hand the sink morsels directly, naming the worker of each and the
# order they arrive in, so a dealing a real schedule could produce is chosen
# here. Each morsel carries a source position (partition id, origin hint) as a
# Parquet or resident-batch source stamps it. The expected answers are written
# from the values alone: each position's rows added from +0.0 in row order,
# then the positions' sums added from +0.0 in position order. What they prove:
#
#   * Four one-row morsels 1e16, 1, -1e16, 1 sum to exactly 1.0 (AVG 0.25) in
#     FLOAT64 and in FLOAT32, on 1, 2, 3, 4 and 7 workers, with the morsels
#     dealt round robin, in reverse and in a scrambled order, and arriving
#     last first. Folded by worker instead, the two-worker round-robin
#     dealing gives 2.0: the input is one whose sum depends on the order.
#   * Over a 1000-row table whose sum shows the order of its additions, cut
#     into 13-row morsels at Parquet-like positions (row group times 2^20
#     plus the morsel's index, the index again as the origin hint), SUM and
#     AVG are the position-order fold bit for bit on every dealing, in FLOAT64
#     and FLOAT32; MIN, MAX, COUNT and COUNT(*) equal the worker fold's. The
#     worker fold over seven workers gives other bits: the table's sum
#     depends on the order.
#   * The chunks of one morsel (one position, consecutive on one worker) fold
#     into one position, row after row.
#   * Two morsels at one position are refused by name at combine, on two
#     workers and on one worker when another position came between them;
#     folded by worker (ORDER_NONE) they are summed, not refused.
#   * Over only NULL rows, by position, SUM and AVG are NULL.
#   * A morsel of no row draws no position cells; over no morsel SUM and AVG
#     are NULL and the counts zero.
#   * Each new position draws its cells from the segment pool: a budget of
#     three cell sets serves the worker's own and two positions and refuses
#     the third with the full message; combine returns every byte.
#   * COUNT(DISTINCT) beside a float SUM counts the distinct values.

from std.memory import bitcast
from std.sys import size_of
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
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from pipeline_exec.agg_fold import AggCell
from pipeline_exec.plan_harness import ungrouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import Expr

comptime _STRIDE = 1_048_576
"""The Parquet source's partition id stride per row group (2^20)."""


# -----------------------------------------------------------------------------
# Inputs and the sink
# -----------------------------------------------------------------------------


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _batch(ref d: List[Optional[Float64]], start: Int, end: Int) raises -> RecordBatch:
    """Rows `start` to `end` of `d` as column `d` (FLOAT64) and column `f`
    (FLOAT32, each value rounded); None is NULL in both."""
    var dc = ColumnBuilder[DType.float64].with_capacity(end - start)
    var fc = ColumnBuilder[DType.float32].with_capacity(end - start)
    for i in range(start, end):
        if d[i]:
            dc.append(d[i].value())
            fc.append(d[i].value().cast[DType.float32]())
        else:
            dc.append_null()
            fc.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    rb.add_column(dc^.materialize())
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    rb.add_column(fc^.materialize())
    return rb.build(sb.build())


def _vals(*xs: Float64) -> List[Optional[Float64]]:
    var out = List[Optional[Float64]]()
    for i in range(len(xs)):
        out.append(Optional[Float64](xs[i]))
    return out^


def _table(rows: Int) -> List[Optional[Float64]]:
    """Row r: NULL where r % 6 == 4, else ((r * 7919) % 10007 - 2000) / 7.
    Not dyadic, so the order of the additions shows in the last bits."""
    var out = List[Optional[Float64]]()
    for r in range(rows):
        if r % 6 == 4:
            out.append(None)
        else:
            out.append(
                Optional[Float64](Float64((r * 7919) % 10007 - 2000) / 7.0)
            )
    return out^


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _six(col: String) -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, col))
    aggs.append(_agg(AGG_MEAN, col))
    aggs.append(_agg(AGG_MIN, col))
    aggs.append(_agg(AGG_MAX, col))
    aggs.append(_agg(AGG_COUNT, col))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    return aggs^


def _six_schema(minmax: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.FLOAT64, True))
    sb.add_field(Field("a", ArrowType.FLOAT64, True))
    sb.add_field(Field("mn", minmax, True))
    sb.add_field(Field("mx", minmax, True))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return sb.build()


def _sink(
    col: String, by_position: Bool, var pool: SegmentPool = SegmentPool()
) raises -> AggSink:
    var minmax = ArrowType.FLOAT64 if col == "d" else ArrowType.FLOAT32
    return AggSink(
        ungrouped_agg_data(_six(col), _six_schema(minmax)),
        pool^,
        0,
        by_position=by_position,
    )


def _take(mut sink: AggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _f(ref b: RecordBatch, col: Int) raises -> Float64:
    return b.column_at(col).as_primitive[DType.float64]().get(0)


def _i(ref b: RecordBatch, col: Int) raises -> Int:
    return Int(b.column_at(col).as_primitive[DType.int64]().get(0))


def _null(ref b: RecordBatch, col: Int) -> Bool:
    return b.column_at(col).is_null_at(0)


# -----------------------------------------------------------------------------
# Dealings
# -----------------------------------------------------------------------------

comptime _ROUND_ROBIN = 0
"""Morsel k to worker k % workers."""
comptime _REVERSED = 1
"""Morsel k to worker workers - 1 - k % workers."""
comptime _SCRAMBLED = 2
"""Morsel k to worker (k * 7 + k / 3) % workers."""


def _worker_of(k: Int, workers: Int, dealing: Int) -> Int:
    if dealing == _ROUND_ROBIN:
        return k % workers
    if dealing == _REVERSED:
        return workers - 1 - k % workers
    return (k * 7 + k // 3) % workers


def _position(k: Int) -> Tuple[Int, Int]:
    """A Parquet-like position for morsel k: row group k / 3 (every other
    row group skipped, as a pruned scan does), index k % 3 within it."""
    var rg = 2 * (k // 3)
    var sub = k % 3
    return (rg * _STRIDE + sub, sub)


def _dealt(
    col: String,
    ref d: List[Optional[Float64]],
    morsel_rows: Int,
    workers: Int,
    dealing: Int,
    last_first: Bool,
    by_position: Bool,
) raises -> RecordBatch:
    """The six aggregates of `col` over `d` cut into morsels of
    `morsel_rows`, morsel k at `_position(k)` handed to the worker the dealing
    names, the morsels arriving in input order or last first."""
    var sink = _sink(col, by_position)
    sink.resize_worker_state(workers)
    var n = (len(d) + morsel_rows - 1) // morsel_rows
    for j in range(n):
        var k = n - 1 - j if last_first else j
        var start = k * morsel_rows
        var end = min(start + morsel_rows, len(d))
        var pos = _position(k)
        # The morsel id is an arrival stamp, as the sources mint it; the sink
        # must not read it.
        sink.consume(
            _worker_of(k, workers, dealing),
            Morsel(_batch(d, start, end), j, pos[0], pos[1]),
        )
    return _take(sink, workers)


def _position_model(
    ref d: List[Optional[Float64]], morsel_rows: Int
) -> Float64:
    """Each morsel's rows added from +0.0 in row order, then the morsels'
    sums added from +0.0 in position order (`_position` is increasing in k)."""
    var total = 0.0
    var start = 0
    while start < len(d):
        var end = min(start + morsel_rows, len(d))
        var part = 0.0
        for i in range(start, end):
            if d[i]:
                part += d[i].value()
        total += part
        start = end
    return total


def _f32_rounded(ref d: List[Optional[Float64]]) -> List[Optional[Float64]]:
    """`d` with each value rounded to FLOAT32 and widened back, the values the
    sink folds for column `f`."""
    var out = List[Optional[Float64]]()
    for i in range(len(d)):
        if d[i]:
            out.append(
                Optional[Float64](
                    d[i].value().cast[DType.float32]().cast[DType.float64]()
                )
            )
        else:
            out.append(None)
    return out^


# -----------------------------------------------------------------------------
# The same bits on every worker count and dealing
# -----------------------------------------------------------------------------


def test_an_order_sensitive_sum_is_one_answer_on_every_dealing() raises:
    var d = _vals(1e16, 1.0, -1e16, 1.0)
    var counts = List[Int]()
    counts.append(1)
    counts.append(2)
    counts.append(3)
    counts.append(4)
    counts.append(7)
    for c in range(len(counts)):
        var workers = counts[c]
        for dealing in range(3):
            for lf in range(2):
                var last_first = lf == 1
                var label = (
                    String(workers)
                    + " workers, dealing "
                    + String(dealing)
                    + ", last first "
                    + String(last_first)
                )
                for col_i in range(2):
                    var col = "d" if col_i == 0 else "f"
                    var b = _dealt(
                        col, d, 1, workers, dealing, last_first, True
                    )
                    assert_equal(_bits(_f(b, 0)), _bits(1.0), col + " " + label)
                    assert_equal(
                        _bits(_f(b, 1)), _bits(0.25), col + " " + label
                    )
                    assert_equal(_i(b, 5), 4, col + " " + label)
    # Folded by worker, the round-robin dealing over two workers adds
    # (1e16 + -1e16) + (1 + 1): the input's sum depends on the order.
    var by_worker = _dealt("d", d, 1, 2, _ROUND_ROBIN, False, False)
    assert_equal(_f(by_worker, 0), 2.0)


def test_a_table_sums_in_position_order_on_every_dealing() raises:
    var d = _table(1000)
    var rows = 13
    var want_d = _position_model(d, rows)
    var want_f = _position_model(_f32_rounded(d), rows)
    var one = _dealt("d", d, rows, 1, _ROUND_ROBIN, False, False)
    # The table's sum depends on the order: folded by worker over seven
    # workers it is other bits than the position-order fold.
    var by_worker = _dealt("d", d, rows, 7, _ROUND_ROBIN, False, False)
    assert_true(
        _bits(_f(by_worker, 0)) != _bits(want_d),
        "the table must be one whose sum depends on the order",
    )
    var counts = List[Int]()
    counts.append(1)
    counts.append(2)
    counts.append(3)
    counts.append(7)
    for c in range(len(counts)):
        var workers = counts[c]
        for dealing in range(3):
            for lf in range(2):
                var last_first = lf == 1
                var label = (
                    String(workers)
                    + " workers, dealing "
                    + String(dealing)
                    + ", last first "
                    + String(last_first)
                )
                var b = _dealt("d", d, rows, workers, dealing, last_first, True)
                assert_equal(_bits(_f(b, 0)), _bits(want_d), label)
                assert_equal(
                    _bits(_f(b, 1)),
                    _bits(want_d / Float64(_i(one, 4))),
                    label,
                )
                assert_equal(_f(b, 2), _f(one, 2), label)
                assert_equal(_f(b, 3), _f(one, 3), label)
                assert_equal(_i(b, 4), _i(one, 4), label)
                assert_equal(_i(b, 5), 1000, label)
                var bf = _dealt("f", d, rows, workers, dealing, last_first, True)
                assert_equal(_bits(_f(bf, 0)), _bits(want_f), "f " + label)
                assert_equal(
                    _bits(_f(bf, 1)),
                    _bits(want_f / Float64(_i(one, 4))),
                    "f " + label,
                )


# -----------------------------------------------------------------------------
# Positions: chunks, duplicates, empty morsels
# -----------------------------------------------------------------------------


def test_the_chunks_of_one_morsel_fold_into_one_position() raises:
    # Position P arrives as two chunks on worker 0 (an operator cut it); the
    # other two positions are on worker 1. P's chunks add 1e16 + 1 = 1e16, so
    # the total is ((1e16 + -1e16) + 1) = 1.
    var d = _vals(1e16, 1.0, -1e16, 1.0)
    var sink = _sink("d", True)
    sink.resize_worker_state(2)
    sink.consume(1, Morsel(_batch(d, 2, 3), 0, 3 * _STRIDE, 0))
    sink.consume(0, Morsel(_batch(d, 0, 1), 1, _STRIDE, 0))
    sink.consume(0, Morsel(_batch(d, 1, 2), 1, _STRIDE, 0))
    sink.consume(1, Morsel(_batch(d, 3, 4), 2, 3 * _STRIDE, 1))
    var b = _take(sink, 2)
    assert_equal(_bits(_f(b, 0)), _bits(1.0))
    assert_equal(_i(b, 5), 4)


def _expect_duplicate(mut sink: AggSink, workers: Int) raises:
    var pipeline = PipelineExecution(workers, 0)
    try:
        sink.combine(pipeline)
    except e:
        assert_equal(
            String(e),
            "pipeline_exec: the aggregation sink of segment 0 folds by source"
            " position, and two morsels carried position (partition 5,"
            " origin 2); its source does not stamp one position per morsel",
        )
        return
    assert_true(False, "two morsels at one position were merged")


def test_two_morsels_at_one_position_are_refused() raises:
    var d = _vals(1.0, 2.0, 3.0)
    var two = _sink("d", True)
    two.resize_worker_state(2)
    two.consume(0, Morsel(_batch(d, 0, 1), 0, 5, 2))
    two.consume(1, Morsel(_batch(d, 1, 2), 1, 5, 2))
    _expect_duplicate(two, 2)
    # On one worker, with another position between the two.
    var one = _sink("d", True)
    one.resize_worker_state(1)
    one.consume(0, Morsel(_batch(d, 0, 1), 0, 5, 2))
    one.consume(0, Morsel(_batch(d, 1, 2), 1, 9, 0))
    one.consume(0, Morsel(_batch(d, 2, 3), 2, 5, 2))
    _expect_duplicate(one, 1)


def test_only_null_rows_by_position_give_null() raises:
    var d = List[Optional[Float64]]()
    for _ in range(6):
        d.append(None)
    for workers in range(1, 4):
        var b = _dealt("d", d, 2, workers, _SCRAMBLED, True, True)
        assert_true(_null(b, 0), "SUM of only NULL is NULL")
        assert_true(_null(b, 1), "AVG of only NULL is NULL")
        assert_equal(_i(b, 4), 0)
        assert_equal(_i(b, 5), 6)


def test_a_worker_fold_does_not_refuse_a_repeated_position() raises:
    # Only the position fold needs one morsel per position; folded by worker
    # (ORDER_NONE) two morsels at one position are summed.
    var d = _vals(1.0, 2.0)
    var sink = _sink("d", False)
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(_batch(d, 0, 1), 0, 5, 2))
    sink.consume(1, Morsel(_batch(d, 1, 2), 1, 5, 2))
    var b = _take(sink, 2)
    assert_equal(_f(b, 0), 3.0)


def _cell_bytes() -> Int:
    return 6 * size_of[AggCell]()


def test_a_morsel_of_no_row_draws_no_position() raises:
    # The pool holds the worker's own cells and nothing more: morsels of no
    # row at three positions must not draw.
    var d = _vals(1.0)
    var sink = _sink("d", True, SegmentPool(_cell_bytes()))
    sink.resize_worker_state(1)
    for k in range(3):
        sink.consume(0, Morsel(_batch(d, 0, 0), k, k, 0))
    var b = _take(sink, 1)
    assert_true(_null(b, 0), "SUM over no row is NULL")
    assert_true(_null(b, 1), "AVG over no row is NULL")
    assert_equal(_i(b, 4), 0)
    assert_equal(_i(b, 5), 0)
    var none = _sink("f", True)
    none.resize_worker_state(3)
    var nb = _take(none, 3)
    assert_true(_null(nb, 0), "SUM over no morsel is NULL")
    assert_equal(_i(nb, 5), 0)


def test_each_position_draws_from_the_pool() raises:
    var bytes = _cell_bytes()
    var d = _vals(1.0, 2.0, 3.0)
    var pool = SegmentPool(3 * bytes)
    var sink = _sink("d", True, pool.share())
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(_batch(d, 0, 1), 0, 0, 0))
    sink.consume(0, Morsel(_batch(d, 1, 2), 1, 1, 0))
    assert_equal(pool.granted(), 3 * bytes)
    try:
        sink.consume(0, Morsel(_batch(d, 2, 3), 2, 2, 0))
        assert_true(False, "a third position was drawn past the budget")
    except e:
        assert_equal(
            String(e),
            "MEMORY_BUDGET_EXCEEDED: pipeline_exec: the aggregation sink of"
            " segment 0 was denied "
            + String(bytes)
            + " bytes of the segment's memory pool (budget "
            + String(3 * bytes)
            + ", granted "
            + String(3 * bytes)
            + ")",
        )
    var fresh = SegmentPool(3 * bytes)
    var served = _sink("d", True, fresh.share())
    served.resize_worker_state(1)
    served.consume(0, Morsel(_batch(d, 0, 1), 0, 0, 0))
    served.consume(0, Morsel(_batch(d, 1, 2), 1, 1, 0))
    var b = _take(served, 1)
    assert_equal(_f(b, 0), 3.0)
    assert_equal(fresh.granted(), 0)


def test_count_distinct_beside_a_float_sum_by_position() raises:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "d"))
    aggs.append(_agg(AGG_COUNT_DISTINCT, "d"))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.FLOAT64, True))
    sb.add_field(Field("cd", ArrowType.INT64, False))
    var sink = AggSink(
        ungrouped_agg_data(aggs^, sb.build()),
        SegmentPool(),
        0,
        by_position=True,
    )
    sink.resize_worker_state(2)
    var d = _vals(1.5, 2.5, 1.5, 4.0)
    sink.consume(1, Morsel(_batch(d, 2, 4), 0, 1, 0))
    sink.consume(0, Morsel(_batch(d, 0, 2), 1, 0, 0))
    var b = _take(sink, 2)
    assert_equal(_f(b, 0), 9.5)
    assert_equal(_i(b, 1), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
