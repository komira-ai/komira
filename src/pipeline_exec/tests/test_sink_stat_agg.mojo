# =============================================================================
# MEDIAN, QUANTILE_CONT and the variance family in the ungrouped sink
# =============================================================================
#
# The sink is handed morsels directly, dealt to one or several workers, so the
# merges see non-empty partials. Each run folds one column `x` into seven
# aggregates: MEDIAN, STDDEV_SAMP, STDDEV_POP, VAR_SAMP, VAR_POP and
# QUANTILE_CONT at 0.25 and 0.75. The expected answers are DuckDB's: the
# variance values are what its update (the same Welford steps in the same
# order) gives on one thread, and the sums of the conformance corpus's
# cross_int64 goldens; the quantiles follow its interpolation
# lo * (1 - d) + hi * d. What the tests prove:
#
#   * MEDIAN of an odd count is the middle value and of an even count the mean
#     of the two middle values, whatever the order of the rows.
#   * NULLs are skipped by every one of the seven; over only NULLs, and over no
#     row, every one is NULL.
#   * Over one value the sample forms are NULL, the population forms 0.0 and
#     MEDIAN and QUANTILE_CONT the value.
#   * The answers over 10, 20, .., 60 are DuckDB's bit for bit on one worker,
#     and equal (the quantiles exactly, the variances to 1e-12) on two and
#     three workers, dealt in order and in reverse, and folding by position.
#   * INT64, INT32 and FLOAT64 columns of the same values give the same
#     answers; a DECIMAL128 column folds its variance from DuckDB's DOUBLE of
#     each value.
#   * A large mean and a small spread (10^9 + 1 .. 10^9 + 4) keep their
#     variance (1.6666666666666667, where sum(x*x)/n - mean^2 gives 0).
#   * QUANTILE_CONT interpolates between neighbours and holds its ends (0 is
#     the least value, 1 the greatest).
#   * NaN sorts above every value and is counted; at the ends of the double
#     range the quantiles are DuckDB's (-DBL_MAX and DBL_MAX give 0.0, two
#     -inf give -inf); a variance that is not finite is refused by name.
#   * Refused by name: MEDIAN over DECIMAL128 and FLOAT32 (DuckDB keeps the
#     input's type there) and STDDEV over DATE32; a
#     QUANTILE_CONT whose fraction is out of [0, 1], not a constant, not a
#     FLOAT64, or missing; a MEDIAN with two arguments; a MEDIAN declared
#     INT64; an aggregate the sinks do not serve, naming those they do; kept
#     values the pool denies, leaving nothing granted.

from std.math import inf, isnan, nan
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.decimal_array import Decimal128Array
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
from pipeline_exec.plan_harness import ungrouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from plan_expr.agg_expr import (
    AGG_CORR,
    AGG_MEDIAN,
    AGG_QUANTILE_CONT,
    AGG_STDDEV_POP,
    AGG_STDDEV_SAMP,
    AGG_VAR_POP,
    AGG_VAR_SAMP,
    AggExpr,
)
from plan_expr.expr import BIN_ADD, Expr
from plan_expr.scalar_value import ScalarValue
from scalar_arithmetic.decimal_arith import I128

comptime N_AGGS = 7
comptime MEDIAN = 0
comptime STDDEV_SAMP = 1
comptime STDDEV_POP = 2
comptime VAR_SAMP = 3
comptime VAR_POP = 4
comptime Q1 = 5
comptime Q3 = 6


def _x() -> Expr:
    return Expr.col_ref("x")


def _agg(func: UInt8) -> AggExpr:
    return AggExpr(func, Optional(_x()), None)


def _quantile(q: Float64) -> AggExpr:
    return AggExpr(
        AGG_QUANTILE_CONT,
        Optional(_x()),
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


def _doubles(n: Int) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(n):
        sb.add_field(Field("a" + String(i), ArrowType.FLOAT64, True))
    return sb.build()


# --- columns ------------------------------------------------------------------


def _column(
    ref vals: List[Optional[Float64]], start: Int, end: Int, t: ArrowType
) raises -> RecordBatch:
    """Rows `start` to `end` of `vals` as the column `x` of type `t` (an
    integer type takes the values as integers)."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", t, True))
    if t == ArrowType.FLOAT64:
        var c = ColumnBuilder[DType.float64].with_capacity(end - start)
        for i in range(start, end):
            if vals[i]:
                c.append(vals[i].value())
            else:
                c.append_null()
        rb.add_column(c^.materialize())
    elif t == ArrowType.FLOAT32:
        var c = ColumnBuilder[DType.float32].with_capacity(end - start)
        for i in range(start, end):
            if vals[i]:
                c.append(vals[i].value().cast[DType.float32]())
            else:
                c.append_null()
        rb.add_column(c^.materialize())
    elif t == ArrowType.INT32:
        var c = ColumnBuilder[DType.int32].with_capacity(end - start)
        for i in range(start, end):
            if vals[i]:
                c.append(Int32(Int(vals[i].value())))
            else:
                c.append_null()
        rb.add_column(c^.materialize())
    else:
        var c = ColumnBuilder[DType.int64].with_capacity(end - start)
        for i in range(start, end):
            if vals[i]:
                c.append(Int64(Int(vals[i].value())))
            else:
                c.append_null()
        rb.add_column(c^.materialize())
    return rb.build(sb.build())


def _some(*xs: Float64) -> List[Optional[Float64]]:
    var out = List[Optional[Float64]]()
    for x in xs:
        out.append(Optional(x))
    return out^


def _sink(var aggs: Slab[AggExpr], by_position: Bool = False) raises -> AggSink:
    var n = len(aggs)
    return AggSink(
        ungrouped_agg_data(aggs^, _doubles(n)),
        SegmentPool(),
        0,
        by_position=by_position,
    )


def _take(mut sink: AggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _run(
    ref vals: List[Optional[Float64]],
    t: ArrowType = ArrowType.INT64,
    workers: Int = 1,
    reverse: Bool = False,
    by_position: Bool = False,
    morsel: Int = 2,
) raises -> RecordBatch:
    """The seven aggregates of `vals`, in morsels of `morsel` rows; morsel m
    goes to worker m % workers (the other way round when `reverse`)."""
    var sink = _sink(_seven(), by_position)
    sink.resize_worker_state(workers)
    var start = 0
    var m = 0
    while start < len(vals):
        var end = min(start + morsel, len(vals))
        var w = m % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(_column(vals, start, end, t), m, 0))
        start = end
        m += 1
    return _take(sink, workers)


def _f(ref out: RecordBatch, col: Int) raises -> Float64:
    return out.column_at(col).as_primitive[DType.float64]().get(0)


def _null(ref out: RecordBatch, col: Int) raises -> Bool:
    return out.column_at(col).is_null_at(0)


def _same_bits(got: Float64, want: Float64, what: String) raises:
    assert_true(
        got == want or (isnan(got) and isnan(want)),
        what + ": got " + String(got) + ", want " + String(want),
    )


def _check(ref out: RecordBatch, want: List[Float64], what: String) raises:
    """Every one of the seven equals `want` bit for bit."""
    for i in range(N_AGGS):
        assert_true(not _null(out, i), what + ": column " + String(i) + " NULL")
        _same_bits(_f(out, i), want[i], what + ": column " + String(i))


def _close(ref out: RecordBatch, want: List[Float64], what: String) raises:
    """The quantiles equal `want`; the variances equal it to 1e-12."""
    for i in range(N_AGGS):
        var got = _f(out, i)
        if i == MEDIAN or i == Q1 or i == Q3:
            _same_bits(got, want[i], what + ": column " + String(i))
        else:
            assert_almost_equal(
                got, want[i], rtol=1e-12, msg=what + ": column " + String(i)
            )


def _six_tens() -> List[Float64]:
    """DuckDB's answers over 10, 20, .., 60 (the corpus's cross_int64
    t_full): MEDIAN, STDDEV_SAMP, STDDEV_POP, VAR_SAMP, VAR_POP, the 0.25 and
    0.75 quantiles."""
    return [
        35.0,
        18.708286933869708,
        17.07825127659933,
        350.0,
        291.6666666666667,
        22.5,
        47.5,
    ]


# --- the tests ----------------------------------------------------------------


def test_median_of_odd_and_even_counts() raises:
    var odd = _run(_some(3.0, 1.0, 2.0))
    _same_bits(_f(odd, MEDIAN), 2.0, "MEDIAN of 3, 1, 2")
    var even = _run(_some(4.0, 1.0, 3.0, 2.0))
    _same_bits(_f(even, MEDIAN), 2.5, "MEDIAN of 4, 1, 3, 2")
    var floats = _run(_some(0.5, 0.25), ArrowType.FLOAT64)
    _same_bits(_f(floats, MEDIAN), 0.375, "MEDIAN of 0.5, 0.25")


def test_nulls_are_skipped() raises:
    # The corpus's t_nulls: 10, NULL, 30, 40, NULL, 60.
    var vals = List[Optional[Float64]]()
    vals.append(Optional(10.0))
    vals.append(None)
    vals.append(Optional(30.0))
    vals.append(Optional(40.0))
    vals.append(None)
    vals.append(Optional(60.0))
    var want: List[Float64] = [
        35.0,
        20.816659994661325,
        18.027756377319946,
        433.3333333333333,
        325.0,
        25.0,
        45.0,
    ]
    _check(_run(vals), want, "10, NULL, 30, 40, NULL, 60")
    _close(_run(vals, workers=3), want, "the same on three workers")


def test_only_nulls_and_no_row_give_null() raises:
    var nulls = List[Optional[Float64]]()
    for _ in range(5):
        nulls.append(None)
    var out = _run(nulls, workers=2)
    for i in range(N_AGGS):
        assert_true(_null(out, i), "only NULLs: column " + String(i))
    var nothing = List[Optional[Float64]]()
    var empty = _run(nothing, workers=2)
    assert_equal(empty.num_rows(), 1)
    for i in range(N_AGGS):
        assert_true(_null(empty, i), "no row: column " + String(i))


def test_one_value_gives_null_sample_forms_and_zero_population_forms() raises:
    var vals = List[Optional[Float64]]()
    vals.append(None)
    vals.append(Optional(10.0))
    var out = _run(vals, workers=2)
    assert_true(_null(out, STDDEV_SAMP), "STDDEV_SAMP of one value")
    assert_true(_null(out, VAR_SAMP), "VAR_SAMP of one value")
    _same_bits(_f(out, STDDEV_POP), 0.0, "STDDEV_POP of one value")
    _same_bits(_f(out, VAR_POP), 0.0, "VAR_POP of one value")
    _same_bits(_f(out, MEDIAN), 10.0, "MEDIAN of one value")
    _same_bits(_f(out, Q1), 10.0, "QUANTILE_CONT 0.25 of one value")
    _same_bits(_f(out, Q3), 10.0, "QUANTILE_CONT 0.75 of one value")


def _tens() -> List[Optional[Float64]]:
    return _some(10.0, 20.0, 30.0, 40.0, 50.0, 60.0)


def test_duckdbs_answers_on_any_worker_count_and_dealing() raises:
    var vals = _tens()
    _check(_run(vals), _six_tens(), "one worker")
    for workers in range(2, 4):
        for rev in range(2):
            var what = String(workers) + " workers, reverse " + String(rev)
            _close(
                _run(vals, workers=workers, reverse=rev == 1, morsel=1),
                _six_tens(),
                what,
            )
            _close(
                _run(
                    vals,
                    workers=workers,
                    reverse=rev == 1,
                    by_position=True,
                    morsel=1,
                ),
                _six_tens(),
                what + ", by position",
            )
    # Rows out of order do not change the quantiles.
    _close(
        _run(_some(60.0, 10.0, 50.0, 20.0, 40.0, 30.0), workers=2),
        _six_tens(),
        "shuffled",
    )


def test_integer_and_float_columns_give_the_same_answers() raises:
    var vals = _tens()
    _check(_run(vals, ArrowType.INT32), _six_tens(), "INT32")
    _check(_run(vals, ArrowType.FLOAT64), _six_tens(), "FLOAT64")


def _decimal_batch() raises -> RecordBatch:
    """10.25, 20.50, NULL, 30.75 as DECIMAL(10, 2)."""
    var arr = Decimal128Array.allocate_nullable(4, 10, 2)
    arr.set_i128(0, I128(1025))
    arr.set_i128(1, I128(2050))
    arr.set_null(2)
    arr.set_i128(3, I128(3075))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("x", 10, 2, True))
    rb.add_column(Column.from_decimal128(arr^))
    return rb.build(sb.build())


def test_a_decimal_column_folds_its_variance_from_each_values_double() raises:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_VAR_SAMP))
    aggs.append(_agg(AGG_STDDEV_SAMP))
    aggs.append(_agg(AGG_VAR_POP))
    aggs.append(_agg(AGG_STDDEV_POP))
    var sink = _sink(aggs^)
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(_decimal_batch(), 0, 0))
    var out = _take(sink, 1)
    _same_bits(_f(out, 0), 105.0625, "VAR_SAMP of 10.25, 20.50, 30.75")
    _same_bits(_f(out, 1), 10.25, "STDDEV_SAMP")
    _same_bits(_f(out, 2), 70.04166666666667, "VAR_POP")
    _same_bits(_f(out, 3), 8.369089954509192, "STDDEV_POP")


def test_a_large_mean_and_a_small_spread_keep_their_variance() raises:
    var vals = _some(1000000001.0, 1000000002.0, 1000000003.0, 1000000004.0)
    var one = _run(vals)
    _same_bits(_f(one, VAR_SAMP), 1.6666666666666667, "VAR_SAMP")
    _same_bits(_f(one, STDDEV_SAMP), 1.2909944487358056, "STDDEV_SAMP")
    _same_bits(_f(one, VAR_POP), 1.25, "VAR_POP")
    _same_bits(_f(one, STDDEV_POP), 1.118033988749895, "STDDEV_POP")
    for workers in range(2, 5):
        var out = _run(vals, workers=workers, morsel=1)
        assert_almost_equal(_f(out, VAR_SAMP), 1.6666666666666667, rtol=1e-12)
        assert_almost_equal(_f(out, VAR_POP), 1.25, rtol=1e-12)


def test_quantile_cont_interpolates_and_holds_its_ends() raises:
    var aggs = Slab[AggExpr]()
    aggs.append(_quantile(0.0))
    aggs.append(_quantile(1.0))
    aggs.append(_quantile(0.25))
    aggs.append(_quantile(0.3))
    var sink = _sink(aggs^)
    sink.resize_worker_state(2)
    var vals = _some(10.0, 4.0, 1.0, 3.0, 2.0)
    sink.consume(0, Morsel(_column(vals, 0, 2, ArrowType.INT64), 0, 0))
    sink.consume(1, Morsel(_column(vals, 2, 5, ArrowType.INT64), 1, 0))
    var out = _take(sink, 2)
    _same_bits(_f(out, 0), 1.0, "at 0, the least value")
    _same_bits(_f(out, 1), 10.0, "at 1, the greatest value")
    _same_bits(_f(out, 2), 2.0, "at 0.25, on a value")
    # (5 - 1) * 0.3 = 1.2: between 2 and 3.
    _same_bits(_f(out, 3), 2.2, "at 0.3, between 2 and 3")


def test_nan_sorts_above_every_value_and_is_counted() raises:
    var half = _run(_some(1.0, nan[DType.float64](), 3.0, 2.0), ArrowType.FLOAT64)
    _same_bits(_f(half, MEDIAN), 2.5, "MEDIAN of 1, 2, 3, NaN")
    # The 0.75 quantile falls between 3 and the NaN above it.
    assert_true(isnan(_f(half, Q3)), "QUANTILE_CONT 0.75 of 1, 2, 3, NaN")
    var upper = _some(1.0, nan[DType.float64](), nan[DType.float64](), 2.0)
    var med = _sink_one(AGG_MEDIAN, upper)
    assert_true(isnan(med), "MEDIAN of 1, 2, NaN, NaN is NaN")
    var ends = _some(-inf[DType.float64](), nan[DType.float64](), inf[DType.float64]())
    _same_bits(_sink_one(AGG_MEDIAN, ends), inf[DType.float64](), "-inf, inf, NaN")


def _sink_one(func: UInt8, ref vals: List[Optional[Float64]]) raises -> Float64:
    """`func` of `vals` as one FLOAT64 morsel on one worker."""
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(func))
    var sink = _sink(aggs^)
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(_column(vals, 0, len(vals), ArrowType.FLOAT64), 0, 0))
    return _f(_take(sink, 1), 0)


def test_the_ends_of_the_double_range_interpolate_as_duckdb() raises:
    var big = Float64.MAX
    _same_bits(_sink_one(AGG_MEDIAN, _some(-big, big)), 0.0, "-MAX, MAX")
    var aggs = Slab[AggExpr]()
    aggs.append(_quantile(0.25))
    var sink = _sink(aggs^)
    sink.resize_worker_state(1)
    var wide = _some(big, -big)
    sink.consume(0, Morsel(_column(wide, 0, 2, ArrowType.FLOAT64), 0, 0))
    _same_bits(_f(_take(sink, 1), 0), -8.988465674311578e307, "a quarter")
    var minus = -inf[DType.float64]()
    _same_bits(_sink_one(AGG_MEDIAN, _some(minus, minus)), minus, "-inf, -inf")
    _same_bits(_sink_one(AGG_MEDIAN, _some(5e-324, 5e-324)), 0.0, "subnormals")


def test_a_variance_that_is_not_finite_is_refused_by_name() raises:
    for func in [AGG_VAR_SAMP, AGG_STDDEV_POP]:
        var said = String("")
        try:
            _ = _sink_one(func, _some(1.0, inf[DType.float64]()))
        except e:
            said = String(e)
        assert_true(said.find("is out of range: the answer is not finite") >= 0, said)


def _built_with(var aggs: Slab[AggExpr], var schema: Schema) -> String:
    try:
        _ = AggSink(ungrouped_agg_data(aggs^, schema^), SegmentPool(), 0)
    except e:
        return String(e)
    return String("")


def _one(var agg: AggExpr) -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(agg^)
    return aggs^


def _fraction(var e: Expr) -> AggExpr:
    return AggExpr(AGG_QUANTILE_CONT, Optional(_x()), Optional(e^), None)


def test_what_the_sink_refuses_when_it_is_built() raises:
    var where_ = String("pipeline_exec: the aggregation sink of segment 0")
    assert_equal(
        _built_with(_one(_quantile(1.5)), _doubles(1)),
        where_
        + ": QUANTILE_CONT (output column 0): QUANTILE can only take"
        " parameters in the range [0, 1]",
    )
    assert_equal(
        _built_with(_one(_quantile(-0.25)), _doubles(1)),
        where_
        + ": QUANTILE_CONT (output column 0): QUANTILE can only take"
        " parameters in the range [0, 1]",
    )
    assert_equal(
        _built_with(_one(_fraction(Expr.col_ref("q"))), _doubles(1)),
        where_
        + ": QUANTILE_CONT (output column 0) takes a constant fraction, not"
        " an expression",
    )
    assert_equal(
        _built_with(
            _one(_fraction(Expr.literal(ScalarValue.from_int(1)))), _doubles(1)
        ),
        where_
        + ": QUANTILE_CONT (output column 0) takes a FLOAT64 constant"
        " fraction",
    )
    assert_equal(
        _built_with(_one(_agg(AGG_QUANTILE_CONT)), _doubles(1)),
        where_
        + ": QUANTILE_CONT (output column 0) takes two arguments, a value"
        " and a constant fraction",
    )
    var two = AggExpr(
        AGG_MEDIAN,
        Optional(_x()),
        Optional(Expr.binary(BIN_ADD, _x(), _x())),
        None,
    )
    assert_equal(
        _built_with(_one(two^), _doubles(1)),
        where_ + ": MEDIAN (output column 0) takes one argument",
    )
    assert_equal(
        _built_with(_one(AggExpr(AGG_STDDEV_SAMP, None, None)), _doubles(1)),
        where_ + ": STDDEV_SAMP (output column 0) has no argument",
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("m", ArrowType.INT64, True))
    assert_equal(
        _built_with(_one(_agg(AGG_MEDIAN)), sb.build()),
        "pipeline_exec: MEDIAN (output column 0) cannot produce the declared"
        " output type "
        + String(ArrowType.INT64)
        + " of column 0",
    )
    assert_equal(
        _built_with(_one(_agg(AGG_CORR)), _doubles(1)),
        where_
        + " does not serve aggregate tag 9 (SUM, COUNT, COUNT(DISTINCT), MIN,"
        " MAX, AVG, STDDEV_SAMP, STDDEV_POP, VAR_SAMP, VAR_POP, MEDIAN and"
        " QUANTILE_CONT are)",
    )


def _date_batch() raises -> RecordBatch:
    var c = ColumnBuilder[DType.int32].with_capacity(1)
    c.append(Int32(19000))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.DATE32, True))
    rb.add_column(c^.materialize())
    return rb.build(sb.build())


def _refused_over(func: UInt8, var batch: RecordBatch) raises -> String:
    var sink = _sink(_one(_agg(func)))
    sink.resize_worker_state(1)
    try:
        sink.consume(0, Morsel(batch^, 0, 0))
    except e:
        return String(e)
    return String("")


def test_a_column_type_the_aggregate_does_not_take_is_refused_by_name() raises:
    var tail = String(
        "): SUM, AVG, STDDEV_SAMP, STDDEV_POP, VAR_SAMP and VAR_POP take"
        " signed integers, DECIMAL128, FLOAT32 and FLOAT64; MIN and MAX also"
        " DATE32; MEDIAN and QUANTILE_CONT signed integers and FLOAT64 (over a"
        " DECIMAL128 or a FLOAT32 DuckDB's answer keeps the input's type, not"
        " the DOUBLE the plan declares)"
    )
    assert_equal(
        _refused_over(AGG_MEDIAN, _decimal_batch()),
        "pipeline_exec: MEDIAN (output column 0) is not served over this"
        " column type ("
        + String(ArrowType.DECIMAL128)
        + tail,
    )
    var f32 = _some(1.0, 2.0)
    assert_equal(
        _refused_over(AGG_MEDIAN, _column(f32, 0, 2, ArrowType.FLOAT32)),
        "pipeline_exec: MEDIAN (output column 0) is not served over this"
        " column type ("
        + String(ArrowType.FLOAT32)
        + tail,
    )
    assert_equal(
        _refused_over(AGG_STDDEV_SAMP, _date_batch()),
        "pipeline_exec: STDDEV_SAMP (output column 0) is not served over this"
        " column type ("
        + String(ArrowType.INT32)
        + tail,
    )


def test_kept_values_the_pool_denies_are_refused_by_name() raises:
    var pool = SegmentPool(1024)
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_MEDIAN))
    var sink = AggSink(
        ungrouped_agg_data(aggs^, _doubles(1)), pool.share(), 0
    )
    sink.resize_worker_state(1)
    var vals = List[Optional[Float64]]()
    for r in range(200):
        vals.append(Optional(Float64(r)))
    var said = String("")
    try:
        sink.consume(0, Morsel(_column(vals, 0, 200, ArrowType.INT64), 0, 0))
    except e:
        said = String(e)
    assert_true(
        said.find(
            "the aggregation sink of segment 0 was denied 3200 bytes of the"
            " segment's memory pool for its MEDIAN and QUANTILE_CONT values"
        )
        >= 0,
        said,
    )
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
