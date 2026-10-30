# =============================================================================
# The ungrouped aggregation sink, over resident batches
# =============================================================================
#
# Plans written as segment descriptors run through `run_plan` and `RealBuilder`
# with an `AggSink` for the sink. The sample table is the harness's (a = r,
# b = r * 10 with NULL where r % 5 == 2). What these tests prove:
#
#   * SUM, COUNT(x), COUNT(*), MIN, MAX and AVG of an INT64 column equal a
#     row-at-a-time evaluation (NULLs skipped), on one, two and seven workers
#     and morsels that cut the table unevenly; the AVG is the same bit pattern
#     on every worker count.
#   * Under a filter that keeps part of a morsel, COUNT(*) counts the selected
#     rows, with and without an aggregate that evaluates an argument.
#   * Over no row (a filter that rejects every row) and over only NULL, COUNT
#     is zero and SUM, MIN, MAX and AVG are NULL, in one output row of the
#     declared schema.
#   * A DECIMAL128 sum is exact in 128 bits: five values of 9e18 cents sum to
#     4.5e19 (outside 64 bits) and the AVG of them is the exactly divided
#     value; MIN and MAX keep the column's scale; a sum that leaves 128 bits,
#     one with more digits than the declared precision, and an integer sum
#     outside the INT64 output are refused by name.
#   * MIN and MAX of a DATE32 column come back as DATE32.
#   * What the sink refuses when it is built: a group-by expression, an
#     aggregate it does not serve, a missing argument, an output schema of the
#     wrong width, an output type the aggregate cannot produce, a NULL result
#     into a column that is not nullable, and an input type it does not fold.
#   * A pool too small for the sink's state fails the query by name and leaves
#     nothing granted; a large one is returned in full after a run.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_physical_plan.physical_plan import AggSinkData, MorselOp, SegmentDescPod
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.plan_harness import (
    agg_list,
    b_is_null,
    batch_segment,
    chain,
    sample_batch,
    ungrouped_agg_data,
    with_agg_sink,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_pipeline_exec.segment_builder import SegmentBuilder
from komira_pipeline_exec.tpch_q6 import LineitemTable, lineitem_batch, q6_table
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_FIRST,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from komira_plan_expr.expr import BIN_GE, BIN_GT, Expr
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _count_star() -> AggExpr:
    return AggExpr(AGG_COUNT, None, None)


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v)))


def _go[B: SegmentBuilder](
    mut builder: B, var desc: SegmentDescPod, workers: Int
) raises -> RecordBatch:
    var descs = List[SegmentDescPod]()
    descs.append(desc^)
    var dispatch = InlineDispatch()
    var out = run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )
    return out.take(0)


def _f64(ref batch: RecordBatch, col: Int) raises -> Float64:
    return batch.column_at(col).as_primitive[DType.float64]().get(0)


def _i64(ref batch: RecordBatch, col: Int) raises -> Int:
    return Int(batch.column_at(col).as_primitive[DType.int64]().get(0))


def _dec(ref batch: RecordBatch, col: Int) raises -> I128:
    return batch.column_at(col).as_decimal128().get_i128(0)


def _int_schema_six() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.INT64, True))
    sb.add_field(Field("cb", ArrowType.INT64, False))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("mn", ArrowType.INT64, True))
    sb.add_field(Field("mx", ArrowType.INT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    return sb.build()


def _six_aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "b"))
    aggs.append(_agg(AGG_COUNT, "b"))
    aggs.append(_count_star())
    aggs.append(_agg(AGG_MIN, "b"))
    aggs.append(_agg(AGG_MAX, "b"))
    aggs.append(_agg(AGG_MEAN, "b"))
    return aggs^


def test_integer_aggregates_match_the_row_oracle_on_every_worker_count() raises:
    var sum_b = 0
    var count_b = 0
    var least = -1
    var greatest = -1
    for r in range(100):
        if b_is_null(r):
            continue
        sum_b += r * 10
        count_b += 1
        if least < 0:
            least = r * 10
        greatest = r * 10
    var want_avg = Float64(sum_b) / Float64(count_b)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_six_aggs(), _int_schema_six())
    )
    var worker_counts = List[Int]()
    worker_counts.append(1)
    worker_counts.append(2)
    worker_counts.append(7)
    for k in range(len(worker_counts)):
        var workers = worker_counts[k]
        var batch = _go(
            builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 7), id), workers
        )
        assert_equal(batch.num_rows(), 1)
        assert_equal(batch.num_columns(), 6)
        assert_equal(_i64(batch, 0), sum_b)
        assert_equal(_i64(batch, 1), count_b)
        assert_equal(_i64(batch, 2), 100)
        assert_equal(_i64(batch, 3), least)
        assert_equal(_i64(batch, 4), greatest)
        assert_equal(_f64(batch, 5), want_avg)
        for c in range(6):
            assert_false(batch.column_at(c).is_null_at(0))


def test_count_star_counts_the_selected_rows_of_a_filtered_morsel() raises:
    var want_rows = 0
    var want_nonnull = 0
    var want_sum = 0
    for r in range(100):
        if r >= 50:
            want_rows += 1
            if not b_is_null(r):
                want_nonnull += 1
                want_sum += r * 10
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))

    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, False))
    sb.add_field(Field("nb", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.INT64, True))
    var aggs = Slab[AggExpr]()
    aggs.append(_count_star())
    aggs.append(_agg(AGG_COUNT, "b"))
    aggs.append(_agg(AGG_SUM, "b"))
    var with_args = builder.add_agg_sink(ungrouped_agg_data(aggs^, sb.build()))

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("n", ArrowType.INT64, False))
    var only_star = builder.add_agg_sink(
        ungrouped_agg_data(agg_list(_count_star()), sb2.build())
    )

    # Morsels of 7 rows: the filter keeps part of the morsel holding rows 49-55.
    for workers in range(1, 4):
        var ops = chain(MorselOp.filter(_cmp(BIN_GE, "a", 50)))
        var batch = _go(
            builder, with_agg_sink(batch_segment(0, handle, ops^, 7), with_args), workers
        )
        assert_equal(_i64(batch, 0), want_rows)
        assert_equal(_i64(batch, 1), want_nonnull)
        assert_equal(_i64(batch, 2), want_sum)
        var ops2 = chain(MorselOp.filter(_cmp(BIN_GE, "a", 50)))
        var star = _go(
            builder, with_agg_sink(batch_segment(0, handle, ops2^, 7), only_star), workers
        )
        assert_equal(_i64(star, 0), want_rows)


def test_over_no_row_count_is_zero_and_the_rest_are_null() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 40))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_six_aggs(), _int_schema_six())
    )
    var ops = chain(MorselOp.filter(_cmp(BIN_GT, "a", 1000)))
    var batch = _go(
        builder, with_agg_sink(batch_segment(0, handle, ops^, 8), id), 3
    )
    assert_equal(batch.num_rows(), 1)
    assert_equal(_i64(batch, 1), 0)
    assert_equal(_i64(batch, 2), 0)
    assert_true(batch.column_at(0).is_null_at(0))
    assert_true(batch.column_at(3).is_null_at(0))
    assert_true(batch.column_at(4).is_null_at(0))
    assert_true(batch.column_at(5).is_null_at(0))
    assert_equal(batch.schema.field_name(5), "av")


def test_a_column_of_only_null_counts_the_row_but_not_the_value() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    # Row 2 is the first row whose b is NULL.
    assert_true(b_is_null(2))
    var handle = builder.add_resident(sample_batch(2, 1))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_six_aggs(), _int_schema_six())
    )
    var batch = _go(
        builder, with_agg_sink(batch_segment(0, handle), id), 2
    )
    assert_equal(_i64(batch, 1), 0)
    assert_equal(_i64(batch, 2), 1)
    assert_true(batch.column_at(0).is_null_at(0))
    assert_true(batch.column_at(5).is_null_at(0))


def _decimal_batch(
    values: List[I128], nulls: List[Bool], p: Int, s: Int
) raises -> RecordBatch:
    var arr = Decimal128Array.allocate_nullable(len(values), p, s)
    for i in range(len(values)):
        if nulls[i]:
            arr.set_null(i)
        else:
            arr.set_i128(i, values[i])
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field.decimal128("d", p, s, True))
    builder.add_column(Column.from_decimal128(arr^))
    return builder.build(sb.build())


def _decimal_schema(p: Int, s: Int) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("sum", p, s, True))
    sb.add_field(Field.decimal128("mn", p, s, True))
    sb.add_field(Field.decimal128("mx", p, s, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    return sb.build()


def _decimal_aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "d"))
    aggs.append(_agg(AGG_MIN, "d"))
    aggs.append(_agg(AGG_MAX, "d"))
    aggs.append(_agg(AGG_MEAN, "d"))
    return aggs^


def test_a_decimal_sum_is_exact_beyond_64_bits() raises:
    var values = List[I128]()
    var nulls = List[Bool]()
    for i in range(5):
        values.append(_w(9_000_000_000_000_000_000))
        nulls.append(False)
    # A NULL between them, and a value that is the least.
    values.append(_w(0))
    nulls.append(True)
    values.append(_w(-250))
    nulls.append(False)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(_decimal_batch(values, nulls, 20, 2))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_decimal_aggs(), _decimal_schema(38, 2))
    )
    # 6 non-NULL values: five of 9e18 and -250, in cents.
    var want = _w(9_000_000_000_000_000_000) * _w(5) - _w(250)
    for workers in range(1, 4):
        var batch = _go(
            builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 2), id), workers
        )
        assert_true(_dec(batch, 0) == want)
        assert_true(_dec(batch, 1) == _w(-250))
        assert_true(_dec(batch, 2) == _w(9_000_000_000_000_000_000))
        assert_equal(batch.column_at(0).decimal_scale(), 2)
        assert_equal(batch.column_at(0).decimal_precision(), 38)
        # The sum of the six non-NULL values in cents, 44999999999999999750,
        # converted once to a double (4.5e19: the spacing there is 8192), then
        # divided by 100 and by the count.
        var expect_avg = (Float64(4.5e19) - Float64(250.0)) / Float64(100.0) / Float64(6.0)
        assert_equal(_f64(batch, 3), expect_avg)


def test_a_decimal_sum_that_leaves_128_bits_is_refused() raises:
    var nines = _w(1)
    for _ in range(38):
        nines = nines * _w(10)
    nines = nines - _w(1)
    var values = List[I128]()
    var nulls = List[Bool]()
    for _ in range(2):
        values.append(nines)
        nulls.append(False)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(_decimal_batch(values, nulls, 38, 0))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_decimal_aggs(), _decimal_schema(38, 0))
    )
    # Two workers each fold one value, so the refusal comes from the merge;
    # one worker folds both, so it comes from the fold.
    with assert_raises(contains="left the 128-bit range"):
        _ = _go(builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 1), id), 1)
    with assert_raises(contains="left the 128-bit range"):
        _ = _go(builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 1), id), 2)


def test_a_sum_with_more_digits_than_the_declared_precision_is_refused() raises:
    var values = List[I128]()
    var nulls = List[Bool]()
    for _ in range(5):
        values.append(_w(9_000_000_000_000_000_000))
        nulls.append(False)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(_decimal_batch(values, nulls, 20, 2))
    # 4.5e19 has 20 digits; DECIMAL(19,2) holds fewer.
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_decimal_aggs(), _decimal_schema(19, 2))
    )
    with assert_raises(contains="more digits than the declared DECIMAL(19,2)"):
        _ = _go(builder, with_agg_sink(batch_segment(0, handle), id), 1)


def test_an_integer_sum_outside_int64_is_refused_and_min_max_are_not() raises:
    var arr = PrimitiveArray[DType.int64].allocate(3)
    arr.set(0, 9_000_000_000_000_000_000)
    arr.set(1, 9_000_000_000_000_000_000)
    arr.set(2, -5)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("b", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](arr^))
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(rb.build(sb.build()))
    var sum_schema = SchemaBuilder()
    sum_schema.add_field(Field("s", ArrowType.INT64, True))
    var sum_id = builder.add_agg_sink(
        ungrouped_agg_data(agg_list(_agg(AGG_SUM, "b")), sum_schema.build())
    )
    with assert_raises(contains="outside the 64-bit range of its declared INT64"):
        _ = _go(builder, with_agg_sink(batch_segment(0, handle), sum_id), 1)
    var mm = SchemaBuilder()
    mm.add_field(Field("mn", ArrowType.INT64, True))
    mm.add_field(Field("mx", ArrowType.INT64, True))
    var mm_id = builder.add_agg_sink(
        ungrouped_agg_data(agg_list(_agg(AGG_MIN, "b"), _agg(AGG_MAX, "b")), mm.build())
    )
    var batch = _go(builder, with_agg_sink(batch_segment(0, handle), mm_id), 1)
    assert_equal(_i64(batch, 0), -5)
    assert_equal(_i64(batch, 1), 9_000_000_000_000_000_000)


def test_min_and_max_of_a_date_and_a_decimal_keep_their_types() raises:
    var t = q6_table(0)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(lineitem_batch(t, 0, t.rows()))
    var sb = SchemaBuilder()
    sb.add_field(Field("first_day", ArrowType.DATE32, True))
    sb.add_field(Field("last_day", ArrowType.DATE32, True))
    sb.add_field(Field.decimal128("dearest", 15, 2, True))
    sb.add_field(Field.decimal128("total", 38, 2, True))
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_MIN, "l_shipdate"))
    aggs.append(_agg(AGG_MAX, "l_shipdate"))
    aggs.append(_agg(AGG_MAX, "l_extendedprice"))
    aggs.append(_agg(AGG_SUM, "l_quantity"))
    var id = builder.add_agg_sink(ungrouped_agg_data(aggs^, sb.build()))
    var batch = _go(builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 4), id), 2)
    var first = t.shipdate[0]
    var last = t.shipdate[0]
    var dearest = 0
    var total = 0
    for r in range(t.rows()):
        first = min(first, t.shipdate[r])
        last = max(last, t.shipdate[r])
        total += t.quantity[r]
        if not t.price_null[r]:
            dearest = max(dearest, t.price[r])
    assert_true(batch.column_at(0).arrow_type == ArrowType.DATE32)
    assert_equal(
        Int(batch.column_at(0).as_primitive[DType.int32]().get(0)), first
    )
    assert_equal(
        Int(batch.column_at(1).as_primitive[DType.int32]().get(0)), last
    )
    assert_true(_dec(batch, 2) == _w(dearest))
    assert_true(_dec(batch, 3) == _w(total))


def _built_with(
    var data: AggSinkData, handle_rows: Int = 10
) raises -> String:
    """Run `data` over ten sample rows and return the error it raised, or
    the empty string."""
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, handle_rows))
    var id = builder.add_agg_sink(data^)
    try:
        _ = _go(builder, with_agg_sink(batch_segment(0, handle), id), 1)
    except e:
        return String(e)
    return String("")


def _one_field(t: ArrowType, nullable: Bool = True) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", t, nullable))
    return sb.build()


def test_what_the_sink_refuses_when_it_is_built() raises:
    # A group-by expression: this is the ungrouped sink.
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("a"))
    var grouped = AggSinkData(keys^, agg_list(_agg(AGG_SUM, "b")), _one_field(ArrowType.INT64))
    assert_true(
        "has group-by expressions" in _built_with(grouped^)
    )
    # An aggregate the sink does not serve.
    assert_true(
        "does not serve aggregate tag"
        in _built_with(
            ungrouped_agg_data(agg_list(_agg(AGG_FIRST, "b")), _one_field(ArrowType.INT64))
        )
    )
    assert_true(
        "does not serve aggregate tag"
        in _built_with(
            ungrouped_agg_data(agg_list(_agg(AGG_COUNT_DISTINCT, "b")), _one_field(ArrowType.INT64))
        )
    )
    # SUM with no argument.
    assert_true(
        "has no argument"
        in _built_with(
            ungrouped_agg_data(
                agg_list(AggExpr(AGG_SUM, None, None)), _one_field(ArrowType.INT64)
            )
        )
    )
    # Two aggregates, one output column.
    assert_true(
        "declares 1 output columns for 2 aggregates"
        in _built_with(
            ungrouped_agg_data(
                agg_list(_agg(AGG_SUM, "b"), _agg(AGG_MAX, "b")), _one_field(ArrowType.INT64)
            )
        )
    )
    # No aggregate.
    assert_true(
        "has no aggregate"
        in _built_with(ungrouped_agg_data(Slab[AggExpr](), Schema()))
    )
    # An output type the aggregate cannot produce.
    assert_true(
        "cannot produce the declared output type"
        in _built_with(
            ungrouped_agg_data(agg_list(_agg(AGG_SUM, "b")), _one_field(ArrowType.FLOAT64))
        )
    )
    assert_true(
        "cannot produce the declared output type"
        in _built_with(
            ungrouped_agg_data(agg_list(_agg(AGG_MEAN, "b")), _one_field(ArrowType.INT64))
        )
    )
    assert_true(
        "cannot produce the declared output type"
        in _built_with(
            ungrouped_agg_data(agg_list(_count_star()), _one_field(ArrowType.FLOAT64))
        )
    )


def test_what_the_sink_refuses_when_it_runs() raises:
    # SUM over a string column.
    var over_string = _built_with(
        ungrouped_agg_data(agg_list(_agg(AGG_SUM, "s")), _one_field(ArrowType.INT64))
    )
    assert_true("is not served over this column type" in over_string, over_string)
    # SUM into a DECIMAL output over an integer column.
    var wrong_out = _built_with(
        ungrouped_agg_data(agg_list(_agg(AGG_SUM, "a")), _one_field(ArrowType.DECIMAL128))
    )
    assert_true(
        "cannot fill the declared output type" in wrong_out, wrong_out
    )
    # AVG into FLOAT64 is served over an integer column.
    assert_equal(
        _built_with(
            ungrouped_agg_data(agg_list(_agg(AGG_MEAN, "a")), _one_field(ArrowType.FLOAT64))
        ),
        "",
    )
    # A NULL result into a column that cannot hold NULL: b is NULL at row 2.
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(2, 1))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(
            agg_list(_agg(AGG_MAX, "b")), _one_field(ArrowType.INT64, False)
        )
    )
    with assert_raises(contains="declared output column is not nullable"):
        _ = _go(builder, with_agg_sink(batch_segment(0, handle), id), 1)
    # Sink data the builder does not hold.
    var missing = with_agg_sink(batch_segment(0, handle), 7)
    with assert_raises(contains="names aggregation sink data 7, and the builder holds 1"):
        _ = _go(builder, missing^, 1)


def test_a_pool_too_small_fails_the_query_and_a_large_one_is_returned() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(_six_aggs(), _int_schema_six())
    )
    builder.set_memory_budget(1)
    with assert_raises(contains="was denied"):
        _ = _go(builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 7), id), 3)
    assert_equal(builder.pool_granted(), 0)
    builder.set_memory_budget(1 << 20)
    var batch = _go(builder, with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 7), id), 3)
    assert_equal(_i64(batch, 2), 100)
    assert_equal(builder.pool_granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_integer_aggregates_match_the_row_oracle_on_every_worker_count]()
    suite.test[test_count_star_counts_the_selected_rows_of_a_filtered_morsel]()
    suite.test[test_over_no_row_count_is_zero_and_the_rest_are_null]()
    suite.test[test_a_column_of_only_null_counts_the_row_but_not_the_value]()
    suite.test[test_a_decimal_sum_is_exact_beyond_64_bits]()
    suite.test[test_a_decimal_sum_that_leaves_128_bits_is_refused]()
    suite.test[test_a_sum_with_more_digits_than_the_declared_precision_is_refused]()
    suite.test[test_an_integer_sum_outside_int64_is_refused_and_min_max_are_not]()
    suite.test[test_min_and_max_of_a_date_and_a_decimal_keep_their_types]()
    suite.test[test_what_the_sink_refuses_when_it_is_built]()
    suite.test[test_what_the_sink_refuses_when_it_runs]()
    suite.test[test_a_pool_too_small_fails_the_query_and_a_large_one_is_returned]()
    suite^.run()
