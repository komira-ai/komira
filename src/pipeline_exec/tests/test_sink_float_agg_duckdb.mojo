# =============================================================================
# Float SUM, AVG, MIN and MAX of the ungrouped sink against DuckDB
# =============================================================================
#
# The expected answers are DuckDB's: the cases of the SQL conformance corpus
# `agg_float_ungrouped` (src/tests/conformance/komira_sql_conformance), each
# run by the pinned DuckDB as a build action and staged here as
# `duckdb/<case>.tsv`, a header `s a mn mx c n` and one row. This file builds
# the same rows as that corpus's tables.sql, in the order of id, with the same
# IEEE steps (an integer converted and divided once, a FLOAT rounded from that
# double, or an exact constant), and holds the sink's answer to DuckDB's by the
# tolerance rule of the package README:
#
#   * NULL, COUNT and COUNT(*) exactly;
#   * NaN against any NaN, +inf and -inf against themselves;
#   * a zero by its sign (these sets fix it: a sum of -0.0 is +0.0, the MIN
#     and MAX of -0.0 are -0.0);
#   * MIN and MAX of FLOAT32 as the FLOAT32 DuckDB's spelling rounds to, of
#     FLOAT64 within 1e-15 relative (the reader's parse of DuckDB's shortest
#     spelling, not the sink, is what that allows for: these inputs are at
#     least 1/7 apart);
#   * a finite SUM or AVG within 1e-9 relative: |got - want| <= 1e-9 *
#     max(|got|, |want|).
#
# Each case runs on several schedules: the segment through `run_plan`, its
# projection and its sink, on one, two and seven workers (the single-thread
# dispatcher lets the first worker drain the source); and morsels dealt
# directly to three and to seven workers, in order and in reverse, so the
# sums are added in other orders. What the tests prove:
#
#   * 4096 rows of non-dyadic DOUBLE and FLOAT values with NULLs: every
#     aggregate within the rule on every schedule.
#   * The small sets (NaN among values, NaN first, only NaN, +inf, -inf, both
#     infinities, a DOUBLE sum past the range and a FLOAT sum past the FLOAT
#     range, only NULL, no row, -0.0): every aggregate within the rule on
#     every schedule.
#   * The comparison is not vacuous: it accepts a SUM 1e-10 relative off and
#     reports, at the right column, a SUM 1e-8 off, NULL for a value and a
#     value for NULL, a number for NaN and NaN for a number, an infinity of
#     the wrong sign and a finite value for one, a zero of the wrong sign,
#     a wrong COUNT and COUNT(*), and a FLOAT32 MIN one step off.

from std.math import inf, nan
from std.memory import bitcast
from std.pathlib import Path
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
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import MorselOp, SegmentDescPod
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    batch_segment,
    ungrouped_agg_data,
    with_agg_sink,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import Expr
from plan_expr.expr_pool import ExprPool


# -----------------------------------------------------------------------------
# The corpus's rows
# -----------------------------------------------------------------------------


struct _Rows(Movable):
    """Columns d (FLOAT64) and f (FLOAT32, held widened) of one input."""

    var d: List[Optional[Float64]]
    var f: List[Optional[Float64]]

    def __init__(out self):
        self.d = List[Optional[Float64]]()
        self.f = List[Optional[Float64]]()

    def add(mut self, d: Optional[Float64], f: Optional[Float64]):
        self.d.append(d)
        # A FLOAT value: the double rounded to FLOAT32, as DuckDB's cast.
        if f:
            self.f.append(
                Optional[Float64](
                    f.value().cast[DType.float32]().cast[DType.float64]()
                )
            )
        else:
            self.f.append(None)

    def both(mut self, v: Float64):
        self.add(Optional[Float64](v), Optional[Float64](v))


def _v_table() -> _Rows:
    """V of tables.sql: row i of 4096."""
    var t = _Rows()
    for i in range(4096):
        var d: Optional[Float64] = None
        var f: Optional[Float64] = None
        if i % 8 != 3:
            d = Optional[Float64](Float64((i * 7919) % 10007 - 2000) / 7.0)
        if i % 8 != 5:
            f = Optional[Float64](Float64((i * 104729) % 1009 - 200) / 3.0)
        t.add(d, f)
    return t^


def _nan() -> Float64:
    return nan[DType.float64]()


def _inf() -> Float64:
    return inf[DType.float64]()


def _x_set(name: String) raises -> _Rows:
    """The rows of X in tables.sql whose grp is `name`, in the order of id."""
    var t = _Rows()
    if name == "nan_mixed":
        t.both(1.5)
        t.both(_nan())
        t.both(-2.25)
        t.add(None, None)
        t.both(4.0)
    elif name == "nan_first":
        t.both(_nan())
        t.both(2.0)
        t.both(1.0)
    elif name == "nan_only":
        t.both(_nan())
        t.add(None, None)
        t.both(_nan())
    elif name == "pos_inf":
        t.both(1.0)
        t.both(_inf())
        t.both(2.0)
    elif name == "neg_inf":
        t.both(-_inf())
        t.both(-1.0)
    elif name == "both_inf":
        t.both(_inf())
        t.both(-_inf())
        t.both(3.0)
    elif name == "overflow":
        var d_top = bitcast[DType.float64](UInt64(0x7FE0000000000000))  # 2^1023
        var f_top = bitcast[DType.float64](UInt64(0x47E0000000000000))  # 2^127
        t.add(Optional[Float64](d_top), Optional[Float64](f_top))
        t.add(Optional[Float64](d_top), Optional[Float64](f_top))
        t.add(Optional[Float64](1.0), Optional[Float64](f_top))
    elif name == "all_null":
        for _ in range(3):
            t.add(None, None)
    elif name == "none":
        pass
    elif name == "neg_zero":
        t.both(-0.0)
        t.both(-0.0)
    else:
        raise Error("no set " + name + " in X")
    return t^


def _batch(ref t: _Rows, start: Int, end: Int) raises -> RecordBatch:
    var dc = ColumnBuilder[DType.float64].with_capacity(end - start)
    var fc = ColumnBuilder[DType.float32].with_capacity(end - start)
    for i in range(start, end):
        if t.d[i]:
            dc.append(t.d[i].value())
        else:
            dc.append_null()
        if t.f[i]:
            fc.append(t.f[i].value().cast[DType.float32]())
        else:
            fc.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    rb.add_column(dc^.materialize())
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    rb.add_column(fc^.materialize())
    return rb.build(sb.build())


# -----------------------------------------------------------------------------
# The sink on each schedule
# -----------------------------------------------------------------------------


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _aggs(col: String) -> Slab[AggExpr]:
    """The six aggregates of the corpus's SELECT over `col`, in its order."""
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, col))
    aggs.append(_agg(AGG_MEAN, col))
    aggs.append(_agg(AGG_MIN, col))
    aggs.append(_agg(AGG_MAX, col))
    aggs.append(_agg(AGG_COUNT, col))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    return aggs^


def _schema(col: String) raises -> Schema:
    """The types DuckDB answers: SUM and AVG DOUBLE, MIN and MAX the input's
    type, the counts BIGINT."""
    var minmax = ArrowType.FLOAT64 if col == "d" else ArrowType.FLOAT32
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.FLOAT64, True))
    sb.add_field(Field("a", ArrowType.FLOAT64, True))
    sb.add_field(Field("mn", minmax, True))
    sb.add_field(Field("mx", minmax, True))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return sb.build()


def _through_run_plan(
    ref t: _Rows, col: String, morsel_rows: Int, workers: Int
) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(_batch(t, 0, len(t.d)))
    var id = builder.add_agg_sink(ungrouped_agg_data(_aggs(col), _schema(col)))
    var descs = List[SegmentDescPod]()
    descs.append(
        with_agg_sink(
            batch_segment(0, handle, Slab[MorselOp](), morsel_rows), id
        )
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )
    return out.take(0)


def _dealt(
    ref t: _Rows, col: String, morsel_rows: Int, workers: Int, reverse: Bool
) raises -> RecordBatch:
    var sink = AggSink(
        ungrouped_agg_data(_aggs(col), _schema(col)), SegmentPool(), 0
    )
    sink.resize_worker_state(workers)
    var k = 0
    var start = 0
    while start < len(t.d):
        var end = min(start + morsel_rows, len(t.d))
        var w = k % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(_batch(t, start, end), k, 0))
        k += 1
        start = end
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


# -----------------------------------------------------------------------------
# DuckDB's answer and the rule
# -----------------------------------------------------------------------------


def _answer(cname: String) raises -> List[String]:
    """The cells of the one row of `duckdb/<case>.tsv`; "" is NULL."""
    var text = Path("duckdb/" + cname + ".tsv").read_text()
    var lines = List[String]()
    for raw in text.split("\n"):
        lines.append(String(raw))
    if len(lines) != 3 or lines[2] != "":
        raise Error(cname + ": expected a header and one row")
    if lines[0] != "s\ta\tmn\tmx\tc\tn":
        raise Error(cname + ": header " + lines[0])
    var cells = List[String]()
    for raw in lines[1].split("\t"):
        cells.append(String(raw))
    if len(cells) != 6:
        raise Error(cname + ": " + String(len(cells)) + " cells")
    return cells^


def _float_mismatch(
    ref got: RecordBatch, c: Int, want: String, f32: Bool
) raises -> String:
    """Why cell `c` (SUM, AVG, MIN or MAX) of `got` breaks the rule against
    DuckDB's spelling `want`, or ""."""
    ref col = got.column_at(c)
    if want == "":
        return "" if col.is_null_at(0) else "a value for NULL"
    if col.is_null_at(0):
        return "NULL for " + want
    var g: Float64
    if f32:
        g = col.as_primitive[DType.float32]().get(0).cast[DType.float64]()
    else:
        g = col.as_primitive[DType.float64]().get(0)
    var shown = String(g) + " for " + want
    if want == "nan" or want == "-nan":
        return "" if g != g else shown
    if g != g:
        return shown
    if want == "inf" or want == "-inf":
        return "" if g == (_inf() if want == "inf" else -_inf()) else shown
    var w = atof(want)
    if f32:
        w = w.cast[DType.float32]().cast[DType.float64]()
    if w == 0.0:
        # The sign of a zero is read from DuckDB's text, not from the parse.
        var g_negative = (bitcast[DType.uint64](g) >> 63) == 1
        return "" if g == 0.0 and g_negative == want.startswith("-") else shown
    var tol = 1e-9 if c <= 1 else (0.0 if f32 else 1e-15)
    if abs(g - w) <= tol * max(abs(g), abs(w)):
        return ""
    return shown


def _mismatch(cname: String, ref got: RecordBatch, f32: Bool) raises -> String:
    """Why `got` breaks the rule against DuckDB's answer to `cname`, or ""."""
    var want = _answer(cname)
    if got.num_rows() != 1 or got.num_columns() != 6:
        return cname + ": not one row of six columns"
    for c in range(4):
        var why = _float_mismatch(got, c, want[c], f32 and c >= 2)
        if why != "":
            return cname + " column " + String(c) + ": " + why
    for c in range(4, 6):
        var g = Int(got.column_at(c).as_primitive[DType.int64]().get(0))
        if g != atol(want[c]):
            return (
                cname + " column " + String(c) + ": " + String(g) + " for "
                + want[c]
            )
    return ""


def _check_every_schedule(
    cname: String, ref t: _Rows, col: String, morsel_rows: Int, dealt_rows: Int
) raises:
    var f32 = col == "f"
    var plan_workers: List[Int] = [1, 2, 7]
    for workers in plan_workers:
        var why = _mismatch(
            cname, _through_run_plan(t, col, morsel_rows, workers), f32
        )
        assert_equal(why, "", "run_plan on " + String(workers) + " workers")
    var dealt_workers: List[Int] = [3, 7]
    for workers in dealt_workers:
        for rev in range(2):
            var rows = dealt_rows if workers == 3 else max(1, dealt_rows // 7)
            var why = _mismatch(
                cname, _dealt(t, col, rows, workers, rev == 1), f32
            )
            assert_equal(
                why,
                "",
                String(workers) + " workers, reverse " + String(rev),
            )


def _sets() -> List[String]:
    """The sets of X, in the order of the corpus's case numbers."""
    var out: List[String] = [
        "nan_mixed",
        "nan_first",
        "nan_only",
        "pos_inf",
        "neg_inf",
        "both_inf",
        "overflow",
        "all_null",
        "none",
        "neg_zero",
    ]
    return out^


def _case_name(n: Int, set: String, col: String) -> String:
    var num = String(n) if n >= 10 else "0" + String(n)
    return "c" + num + "_" + set + ("_double" if col == "d" else "_float")


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_the_4096_row_table_matches_duckdb_on_every_schedule() raises:
    var t = _v_table()
    _check_every_schedule("c01_v_double", t, "d", 1000, 100)
    _check_every_schedule("c02_v_float", t, "f", 1000, 100)


def test_nan_inf_null_and_zero_sets_match_duckdb_on_every_schedule() raises:
    var sets = _sets()
    var n = 3
    for i in range(len(sets)):
        var t = _x_set(sets[i])
        var cols: List[String] = ["d", "f"]
        for col in cols:
            _check_every_schedule(_case_name(n, sets[i], col), t, col, 2, 1)
            n += 1


def _row(
    s: Optional[Float64],
    a: Optional[Float64],
    mn: Optional[Float64],
    mx: Optional[Float64],
    c: Int,
    n: Int,
    f32: Bool = False,
) raises -> RecordBatch:
    """An answer row of the corpus's shape: None is NULL; MIN and MAX are
    FLOAT32 when `f32`."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var names: List[String] = ["s", "a", "mn", "mx"]
    var cells: List[Optional[Float64]] = [s, a, mn, mx]
    for k in range(4):
        if f32 and k >= 2:
            var b = ColumnBuilder[DType.float32].with_capacity(1)
            if cells[k]:
                b.append(cells[k].value().cast[DType.float32]())
            else:
                b.append_null()
            sb.add_field(Field(names[k], ArrowType.FLOAT32, True))
            rb.add_column(b^.materialize())
        else:
            var b = ColumnBuilder[DType.float64].with_capacity(1)
            if cells[k]:
                b.append(cells[k].value())
            else:
                b.append_null()
            sb.add_field(Field(names[k], ArrowType.FLOAT64, True))
            rb.add_column(b^.materialize())
    var counts: List[Int] = [c, n]
    var cnames: List[String] = ["c", "n"]
    for k in range(2):
        var b = ColumnBuilder[DType.int64].with_capacity(1)
        b.append(Int64(counts[k]))
        sb.add_field(Field(cnames[k], ArrowType.INT64, False))
        rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _reported(cname: String, ref got: RecordBatch, f32: Bool, column: Int) raises:
    var why = _mismatch(cname, got, f32)
    assert_true(
        why.startswith(cname + " column " + String(column) + ": "),
        cname + ": got [" + why + "]",
    )


def test_the_comparison_reports_answers_outside_the_rule() raises:
    var top = bitcast[DType.float64](UInt64(0x7FE0000000000000))  # 2^1023
    var t = _v_table()
    var good = _through_run_plan(t, "d", 1000, 1)
    assert_equal(_mismatch("c01_v_double", good, False), "")
    var s = good.column_at(0).as_primitive[DType.float64]().get(0)
    var a = good.column_at(1).as_primitive[DType.float64]().get(0)
    var mn = good.column_at(2).as_primitive[DType.float64]().get(0)
    var mx = good.column_at(3).as_primitive[DType.float64]().get(0)
    # Inside the rule: a SUM off by 1e-10 relative. Outside: by 1e-8.
    assert_equal(
        _mismatch("c01_v_double", _row(s * (1.0 + 1e-10), a, mn, mx, 3584, 4096), False),
        "",
    )
    _reported("c01_v_double", _row(s * (1.0 + 1e-8), a, mn, mx, 3584, 4096), False, 0)
    # NULL for a value, and a value for NULL.
    _reported("c01_v_double", _row(s, None, mn, mx, 3584, 4096), False, 1)
    _reported("c17_all_null_double", _row(1.0, None, None, None, 0, 3), False, 0)
    # A number for NaN, and NaN for a number (MIN of only NaN, MIN beside NaN).
    _reported("c03_nan_mixed_double", _row(1.0, _nan(), -2.25, _nan(), 4, 5), False, 0)
    _reported("c03_nan_mixed_double", _row(_nan(), _nan(), _nan(), _nan(), 4, 5), False, 2)
    _reported("c07_nan_only_double", _row(_nan(), _nan(), 1.0, _nan(), 2, 3), False, 2)
    # An infinity of the wrong sign, and a finite value for one.
    _reported("c09_pos_inf_double", _row(-_inf(), _inf(), 1.0, _inf(), 3, 3), False, 0)
    _reported("c15_overflow_double", _row(top, _inf(), 1.0, top, 3, 3), False, 0)
    # A zero of the wrong sign: +0.0 for MIN -0.0, -0.0 for SUM +0.0.
    _reported("c21_neg_zero_double", _row(0.0, 0.0, 0.0, -0.0, 2, 2), False, 2)
    _reported("c21_neg_zero_double", _row(-0.0, 0.0, -0.0, -0.0, 2, 2), False, 0)
    # A wrong COUNT and a wrong COUNT(*).
    _reported("c15_overflow_double", _row(_inf(), _inf(), 1.0, top, 2, 3), False, 4)
    _reported("c15_overflow_double", _row(_inf(), _inf(), 1.0, top, 3, 4), False, 5)
    # A FLOAT32 MIN one FLOAT32 step away from DuckDB's.
    var g = _through_run_plan(t, "f", 1000, 1)
    assert_equal(_mismatch("c02_v_float", g, True), "")
    var fmn = g.column_at(2).as_primitive[DType.float32]().get(0)
    var next = bitcast[DType.float32](bitcast[DType.uint32](fmn) + 1)
    _reported(
        "c02_v_float",
        _row(
            g.column_at(0).as_primitive[DType.float64]().get(0),
            g.column_at(1).as_primitive[DType.float64]().get(0),
            next.cast[DType.float64](),
            g.column_at(3).as_primitive[DType.float32]().get(0).cast[DType.float64](),
            3584,
            4096,
            True,
        ),
        True,
        2,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_4096_row_table_matches_duckdb_on_every_schedule]()
    suite.test[test_nan_inf_null_and_zero_sets_match_duckdb_on_every_schedule]()
    suite.test[test_the_comparison_reports_answers_outside_the_rule]()
    suite^.run()
