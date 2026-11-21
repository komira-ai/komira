# =============================================================================
# A float SUM and AVG in ORDER_ROW_RANGE: the same bits on every worker count
# =============================================================================
#
# An ungrouped aggregation over FLOAT64 and FLOAT32 columns whose segment is
# ORDER_ROW_RANGE, run through `run_plan` on real runtimes of 1, 2, 4 and 7
# workers (and, for the resident batch, the same worker counts), run after
# run. The expected sums are written from the values alone: the rows of each
# morsel (a row group cut into pieces of the segment's morsel_rows rows, in
# order) added from +0.0, then the morsel sums added from +0.0 in file order.
# What the tests prove:
#
#   * Over a 40-row-group Parquet file whose sum shows the order of its
#     additions, SUM(v), AVG(v), SUM(f) and COUNT(*) are that model's bits on
#     1, 2, 4 and 7 workers, on every run, with each row group cut into
#     several morsels and with one morsel per row group (morsel_rows 0).
#   * Four row groups of one row each, 1e16, 1, -1e16, 1, give a SUM of
#     exactly 1.0 and an AVG of 0.25 on 1, 2, 4 and 7 workers, on every run.
#   * The same plan over a resident batch gives the same bits on 1, 2, 4 and
#     7 workers.
#   * While the scan's cursor-grain route is on, an ORDER_ROW_RANGE segment
#     over Parquet is refused with the full message, and the same plan in
#     ORDER_NONE still runs. The switch is turned off again on every path.

from std.memory import bitcast
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
from async_rt.ops.waker_sink import NoopSink
from async_rt.reactor.reactor import BACKEND_MOCK
from async_rt.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from containers.slab import Slab
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_scan.cursor_grain_feed import set_cursor_grain_enabled
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.physical_plan import (
    ORDER_NONE,
    ORDER_ROW_RANGE,
    MorselOp,
    SegmentDescPod,
)
from pipeline_exec.plan_harness import (
    batch_segment,
    parquet_segment,
    ungrouped_agg_data,
    with_agg_sink,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MEAN,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import Expr
from plan_expr.expr_pool import ExprPool
from runtime_paths import test_tmpdir

comptime RUNS = 5
comptime ROW_GROUPS = 40
comptime RG_ROWS = 100


# -----------------------------------------------------------------------------
# Inputs and the plan
# -----------------------------------------------------------------------------


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _values(rows: Int) -> List[Float64]:
    """Row r: 1e16 where r % 7 is 0, -1e16 where it is 3, else
    ((r * 7919) % 10007 - 2000) / 7. The big values swallow the small ones, so
    the sum depends on the order of its additions."""
    var out = List[Float64]()
    for r in range(rows):
        if r % 7 == 0:
            out.append(1e16)
        elif r % 7 == 3:
            out.append(-1e16)
        else:
            out.append(Float64((r * 7919) % 10007 - 2000) / 7.0)
    return out^


def _batch(ref v: List[Float64]) raises -> RecordBatch:
    """Column v (FLOAT64) and column f (FLOAT32, each value rounded)."""
    var vc = ColumnBuilder[DType.float64].with_capacity(len(v))
    var fc = ColumnBuilder[DType.float32].with_capacity(len(v))
    for i in range(len(v)):
        vc.append(v[i])
        fc.append(v[i].cast[DType.float32]())
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    rb.add_column(vc^.materialize())
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    rb.add_column(fc^.materialize())
    return rb.build(sb.build())


def _write(name: String, ref v: List[Float64], rg_rows: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        _batch(v), max_rows_per_rg=rg_rows
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("v")), None))
    aggs.append(AggExpr(AGG_MEAN, Optional(Expr.col_ref("v")), None))
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("f")), None))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    return aggs^


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("sv", ArrowType.FLOAT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    sb.add_field(Field("sf", ArrowType.FLOAT64, True))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return sb.build()


struct _Answer(Copyable, Movable):
    var sv: UInt64
    var av: UInt64
    var sf: UInt64
    var n: Int

    def __init__(out self, sv: UInt64, av: UInt64, sf: UInt64, n: Int):
        self.sv = sv
        self.av = av
        self.sf = sf
        self.n = n


def _answer(ref b: RecordBatch) raises -> _Answer:
    assert_equal(b.num_rows(), 1)
    return _Answer(
        _bits(b.column_at(0).as_primitive[DType.float64]().get(0)),
        _bits(b.column_at(1).as_primitive[DType.float64]().get(0)),
        _bits(b.column_at(2).as_primitive[DType.float64]().get(0)),
        Int(b.column_at(3).as_primitive[DType.int64]().get(0)),
    )


def _model(
    ref v: List[Float64], rg_rows: Int, morsel_rows: Int
) -> _Answer:
    """The rows of each morsel added from +0.0, then the morsel sums added
    from +0.0 in file order; a row group is cut into pieces of `morsel_rows`
    rows (the whole group when it is 0)."""
    var piece = morsel_rows if morsel_rows > 0 else rg_rows
    var sv = Float64(0.0)
    var sf = Float64(0.0)
    var rg_start = 0
    while rg_start < len(v):
        var rg_end = min(rg_start + rg_rows, len(v))
        var start = rg_start
        while start < rg_end:
            var end = min(start + piece, rg_end)
            var mv = Float64(0.0)
            var mf = Float64(0.0)
            for i in range(start, end):
                mv += v[i]
                mf += v[i].cast[DType.float32]().cast[DType.float64]()
            sv += mv
            sf += mf
            start = end
        rg_start = rg_end
    return _Answer(_bits(sv), _bits(sv / Float64(len(v))), _bits(sf), len(v))


def _same(ref got: _Answer, ref want: _Answer, what: String) raises:
    assert_equal(got.n, want.n, what + ": COUNT(*)")
    assert_true(got.sv == want.sv, what + ": SUM(v) bits differ")
    assert_true(got.av == want.av, what + ": AVG(v) bits differ")
    assert_true(got.sf == want.sf, what + ": SUM(f) bits differ")


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _started_runtime(workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _parquet_desc(
    path: String, morsel_rows: Int, order: UInt8, sink_id: Int
) -> SegmentDescPod:
    var desc = with_agg_sink(
        parquet_segment(
            0, path, None, None, Slab[MorselOp](), morsel_rows
        ),
        sink_id,
    )
    desc.order_key_kind = order
    return desc^


def _run_parquet(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    path: String,
    morsel_rows: Int,
    order: UInt8,
    workers: Int,
) raises -> _Answer:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var id = builder.add_agg_sink(ungrouped_agg_data(_aggs(), _schema()))
    var descs = List[SegmentDescPod]()
    descs.append(_parquet_desc(path, morsel_rows, order, id))
    ref disp = rt.dispatcher()
    var out = run_plan(descs, builder, disp, workers, CancellationToken.new())
    var batch = out.take(0)
    var a = _answer(batch)
    assert_equal(builder.pool_granted(), 0)
    return a^


def _run_resident(
    mut rt: PerCoreAsyncRuntime[NoopSink],
    ref v: List[Float64],
    morsel_rows: Int,
    workers: Int,
) raises -> _Answer:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(_batch(v))
    var id = builder.add_agg_sink(ungrouped_agg_data(_aggs(), _schema()))
    var desc = with_agg_sink(
        batch_segment(0, handle, Slab[MorselOp](), morsel_rows), id
    )
    desc.order_key_kind = ORDER_ROW_RANGE
    var descs = List[SegmentDescPod]()
    descs.append(desc^)
    ref disp = rt.dispatcher()
    var out = run_plan(descs, builder, disp, workers, CancellationToken.new())
    var batch = out.take(0)
    var a = _answer(batch)
    assert_equal(builder.pool_granted(), 0)
    return a^


def _parquet_on_workers(
    path: String, morsel_rows: Int, workers: Int, ref want: _Answer, what: String
) raises:
    var rt = _started_runtime(workers)
    var failure = String("")
    try:
        for _ in range(RUNS):
            var got = _run_parquet(
                rt, path, morsel_rows, ORDER_ROW_RANGE, workers
            )
            _same(got, want, what + " on " + String(workers) + " workers")
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


def _resident_on_workers(
    ref v: List[Float64], morsel_rows: Int, workers: Int, ref want: _Answer
) raises:
    var rt = _started_runtime(workers)
    var failure = String("")
    try:
        for _ in range(RUNS):
            var got = _run_resident(rt, v, morsel_rows, workers)
            _same(got, want, "resident on " + String(workers) + " workers")
    except e:
        failure = String(e)
    rt.shutdown()
    assert_equal(failure, "")


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_parquet_sums_are_the_position_order_fold_on_every_worker_count() raises:
    var v = _values(ROW_GROUPS * RG_ROWS)
    var path = _write("float_sum_rg", v, RG_ROWS)
    for cut in range(2):
        var morsel_rows = 30 if cut == 0 else 0
        var want = _model(v, RG_ROWS, morsel_rows)
        for k in range(4):
            var workers = 1
            if k == 1:
                workers = 2
            elif k == 2:
                workers = 4
            elif k == 3:
                workers = 7
            _parquet_on_workers(
                path,
                morsel_rows,
                workers,
                want,
                "morsel_rows " + String(morsel_rows),
            )


def test_one_row_groups_of_1e16_1_minus_1e16_1_sum_to_exactly_one() raises:
    var v = List[Float64]()
    v.append(1e16)
    v.append(1.0)
    v.append(-1e16)
    v.append(1.0)
    var path = _write("float_sum_four_rg", v, 1)
    for k in range(4):
        var workers = 1
        if k == 1:
            workers = 2
        elif k == 2:
            workers = 4
        elif k == 3:
            workers = 7
        var rt = _started_runtime(workers)
        var failure = String("")
        try:
            for _ in range(RUNS):
                var got = _run_parquet(rt, path, 0, ORDER_ROW_RANGE, workers)
                assert_true(got.sv == _bits(1.0), "SUM(v) is not 1.0")
                assert_true(got.av == _bits(0.25), "AVG(v) is not 0.25")
                assert_equal(got.n, 4)
        except e:
            failure = String(e)
        rt.shutdown()
        assert_equal(failure, "")


def test_a_resident_batch_gives_the_same_bits_on_every_worker_count() raises:
    var v = _values(ROW_GROUPS * RG_ROWS)
    var first = Optional[_Answer](None)
    for k in range(4):
        var workers = 1
        if k == 1:
            workers = 2
        elif k == 2:
            workers = 4
        elif k == 3:
            workers = 7
        var rt = _started_runtime(workers)
        var failure = String("")
        try:
            for _ in range(RUNS):
                var got = _run_resident(rt, v, 37, workers)
                if not first:
                    first = Optional[_Answer](got.copy())
                _same(
                    got, first.value(), "resident on " + String(workers) + " workers"
                )
        except e:
            failure = String(e)
        rt.shutdown()
        assert_equal(failure, "")


def _refusal_with_the_switch_on(path: String) raises -> String:
    """The error of the ORDER_ROW_RANGE run, the ORDER_NONE run's answer
    checked on the way; the switch is off again on return."""
    var message = String("")
    var failure = String("")
    set_cursor_grain_enabled(True)
    try:
        var rt = _started_runtime(2)
        try:
            var none = _run_parquet(rt, path, 30, ORDER_NONE, 2)
            assert_equal(none.n, ROW_GROUPS * RG_ROWS)
            try:
                _ = _run_parquet(rt, path, 30, ORDER_ROW_RANGE, 2)
                failure = String("the ORDER_ROW_RANGE run was not refused")
            except e:
                message = String(e)
        except e:
            failure = String(e)
        rt.shutdown()
    except e:
        failure = String(e)
    set_cursor_grain_enabled(False)
    assert_equal(failure, "")
    return message^


def test_cursor_grain_route_refuses_row_range_over_parquet_only() raises:
    var v = _values(ROW_GROUPS * RG_ROWS)
    var path = _write("float_sum_cursor_grain", v, RG_ROWS)
    assert_equal(
        _refusal_with_the_switch_on(path),
        "pipeline_exec: segment 0 is ORDER_ROW_RANGE over Parquet while the"
        " scan's cursor-grain route is on; that route cuts morsels by the"
        " worker count, so the float sums would not be the same bits on every"
        " worker count",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[
        test_parquet_sums_are_the_position_order_fold_on_every_worker_count
    ]()
    suite.test[test_one_row_groups_of_1e16_1_minus_1e16_1_sum_to_exactly_one]()
    suite.test[test_a_resident_batch_gives_the_same_bits_on_every_worker_count]()
    suite.test[test_cursor_grain_route_refuses_row_range_over_parquet_only]()
    suite^.run()
