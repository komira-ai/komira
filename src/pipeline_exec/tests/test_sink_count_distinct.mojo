# =============================================================================
# COUNT(DISTINCT x) in the ungrouped aggregation sink
# =============================================================================
#
# The tests hand `AggSink` morsels directly, a different worker for each, so
# every worker holds distinct values of its own when `combine` merges them. The
# expected counts come from a plain loop over the values the test built, never
# from the engine. What they prove:
#
#   * test_ints_are_counted_once_across_repeats_morsels_and_workers: a value
#     repeated inside a morsel, across the morsels of one worker and across
#     workers is one value, NULL is not counted.
#   * test_every_integer_width_and_a_date_counts_its_distinct_values: INT8,
#     INT16, INT32, INT64 and DATE32, with the least and greatest value of each
#     width and values that differ only in their high bytes.
#   * test_float64_counts_every_nan_as_one_and_the_zeros_as_one and
#     test_float32_counts_every_nan_as_one_and_the_zeros_as_one: NaNs of
#     different bit patterns, on different workers too, are one value, -0.0 and
#     0.0 are one value, infinities and the neighbours of a value are distinct.
#   * test_decimal_values_differing_in_one_word_are_distinct: DECIMAL128 values
#     that differ only in the high 64 bits, or only in the low ones, are two.
#   * test_strings_count_by_content_and_the_empty_string_is_a_value: strings
#     count by their bytes (a prefix is another value), the empty string is a
#     value and NULL is not.
#   * test_a_dictionary_is_read_by_value_and_mixes_with_flat_strings: two
#     dictionaries that give the same strings different codes, across morsels
#     and workers, count once, and a flat STRING morsel of the same worker
#     counts with them.
#   * test_null_is_not_counted_and_no_value_counts_zero: a column of only NULL
#     (integer, string and dictionary) and a morsel of no row count 0, in one
#     INT64 row that is not NULL.
#   * test_no_row_gives_one_row_of_zero: a sink no morsel reached.
#   * test_it_runs_beside_sum_count_and_count_star: COUNT(DISTINCT) of an
#     integer, a nullable integer and a string beside SUM, COUNT(b) and
#     COUNT(*) equal the row oracle, with a morsel dealt to two workers.
#   * test_two_count_distincts_over_different_columns_keep_their_own_values:
#     the same value under two aggregates is counted by each.
#   * test_a_filter_keeps_rejected_rows_out_of_the_count: under a filter on
#     one to three workers the count is that of the selected rows, and zero
#     when the filter rejects every row.
#   * test_what_the_sink_refuses_when_it_is_built: a COUNT(DISTINCT) without an
#     argument and one declared as a type other than INT64, by exact message.
#   * test_an_argument_type_it_does_not_serve_is_refused_by_name: UINT32, by
#     exact message.
#   * test_a_column_that_changes_type_between_morsels_of_a_worker_is_refused:
#     INT64 then INT32, and DATE32 then INT32 (another type, though the same
#     storage), by exact message.
#   * test_a_column_of_other_types_on_different_workers_is_refused_at_combine:
#     the merge of an INT64 worker and a FLOAT64 worker, by exact message.
#   * test_a_pool_too_small_for_the_distinct_values_is_refused_by_name: a
#     budget that holds the sink's cells and not the first distinct entries, by
#     exact message, for an integer and for a string; the pool is whole after.
#   * test_a_pool_too_small_for_the_merge_is_refused_and_returned: a budget
#     that holds the workers and not the merge is refused in `combine`; with
#     room for the merge the same morsels merge, and the pool is whole.

from std.memory import bitcast
from std.sys import size_of
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
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
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
from physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    SegmentDescPod,
)
from pipeline_exec.agg_fold import AggCell
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.group_table import GroupTable
from pipeline_exec.plan_harness import (
    agg_list,
    b_is_null,
    batch_segment,
    chain,
    sample_batch,
    ungrouped_agg_data,
    with_agg_sink,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from pipeline_exec.string_harness import (
    FORM_DICT,
    FORM_FLAT,
    FORM_SHUFFLED,
    string_column,
)
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import BIN_GE, BIN_GT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from scalar_arithmetic.decimal_arith import I128

comptime NUL: Int = -999999
"""In a list of test values: this row is NULL."""

comptime NULL_STR = "<NULL>"
"""In a list of test strings: this row is NULL."""

comptime NULL_BITS: UInt64 = 0x1234567812345678
"""In a list of float bit patterns: this row is NULL."""


def _cd(col: String) -> AggExpr:
    return AggExpr(AGG_COUNT_DISTINCT, Optional(Expr.col_ref(col)), None)


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _count_schema(n: Int) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(n):
        sb.add_field(Field("n" + String(i), ArrowType.INT64, False))
    return sb.build()


def _sink_x(var pool: SegmentPool) raises -> AggSink:
    """COUNT(DISTINCT x) alone, into one INT64 column that is not NULL."""
    var data = ungrouped_agg_data(agg_list(_cd("x")), _count_schema(1))
    return AggSink(data, pool^, 0)


def _sink_x() raises -> AggSink:
    return _sink_x(SegmentPool())


def _feed(sink: AggSink, w: Int, idx: Int, var batch: RecordBatch) raises:
    sink.consume(w, Morsel(batch^, idx, 0))


def _finish(mut sink: AggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _count_of(ref out: RecordBatch, col: Int = 0) raises -> Int:
    """The count in column `col` of the one output row, which must be an INT64
    that is not NULL."""
    assert_equal(out.num_rows(), 1)
    assert_equal(out.schema.field_arrow_type(col), ArrowType.INT64)
    assert_false(out.column_at(col).is_null_at(0))
    return Int(out.column_at(col).as_primitive[DType.int64]().get(0))


def _failure_of_feed(
    sink: AggSink, w: Int, idx: Int, var batch: RecordBatch
) raises -> String:
    try:
        sink.consume(w, Morsel(batch^, idx, 0))
    except e:
        return String(e)
    return String("")


def _failure_of_finish(mut sink: AggSink, workers: Int) raises -> String:
    try:
        _ = _finish(sink, workers)
    except e:
        return String(e)
    return String("")


# --- the oracle: a loop over the values the test built ----------------------


def _distinct(vals: List[Int]) -> Int:
    """The number of distinct values of `vals` that are not NUL."""
    var seen = List[Int]()
    for i in range(len(vals)):
        if vals[i] == NUL:
            continue
        var found = False
        for j in range(len(seen)):
            if seen[j] == vals[i]:
                found = True
        if not found:
            seen.append(vals[i])
    return len(seen)


def _cat3(a: List[Int], b: List[Int], c: List[Int]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(a)):
        out.append(a[i])
    for i in range(len(b)):
        out.append(b[i])
    for i in range(len(c)):
        out.append(c[i])
    return out^


def _distinct_strs(vals: List[String]) -> Int:
    var seen = List[String]()
    for i in range(len(vals)):
        if vals[i] == NULL_STR:
            continue
        var found = False
        for j in range(len(seen)):
            if seen[j] == vals[i]:
                found = True
        if not found:
            seen.append(vals[i])
    return len(seen)


# --- batches of one column `x` ----------------------------------------------


def _batch_of[
    dtype: DType
](at: ArrowType, vals: List[Scalar[dtype]], valid: List[Bool]) raises -> RecordBatch:
    var b = ColumnBuilder[dtype].with_capacity(len(vals))
    for i in range(len(vals)):
        if valid[i]:
            b.append(vals[i])
        else:
            b.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", at, True))
    rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _int_batch[dtype: DType](at: ArrowType, vals: List[Int]) raises -> RecordBatch:
    var scalars = List[Scalar[dtype]]()
    var valid = List[Bool]()
    for i in range(len(vals)):
        valid.append(vals[i] != NUL)
        scalars.append(Scalar[dtype](0 if vals[i] == NUL else vals[i]))
    return _batch_of[dtype](at, scalars, valid)


def _date_batch(vals: List[Int]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int32].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, Int32(vals[i]))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.DATE32, False))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            arr^, ArrowType.DATE32
        )
    )
    return rb.build(sb.build())


def _f64_batch(bits: List[UInt64]) raises -> RecordBatch:
    var scalars = List[Float64]()
    var valid = List[Bool]()
    for i in range(len(bits)):
        valid.append(bits[i] != NULL_BITS)
        scalars.append(bitcast[DType.float64](bits[i]))
    return _batch_of[DType.float64](ArrowType.FLOAT64, scalars, valid)


def _f32_batch(bits: List[UInt32]) raises -> RecordBatch:
    var scalars = List[Float32]()
    var valid = List[Bool]()
    for i in range(len(bits)):
        valid.append(bits[i] != UInt32(0x12345678))
        scalars.append(bitcast[DType.float32](bits[i]))
    return _batch_of[DType.float32](ArrowType.FLOAT32, scalars, valid)


def _dec_batch(vals: List[I128], valid: List[Bool]) raises -> RecordBatch:
    var arr = Decimal128Array.allocate_nullable(len(vals), 38, 0)
    for i in range(len(vals)):
        if valid[i]:
            arr.set_i128(i, vals[i])
        else:
            arr.set_null(i)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("x", 38, 0, True))
    rb.add_column(Column.from_decimal128(arr^))
    return rb.build(sb.build())


def _str_batch(
    vals: List[String], form: Int = FORM_FLAT, rot: Int = 0
) raises -> RecordBatch:
    var values = List[String]()
    var valid = List[Bool]()
    for i in range(len(vals)):
        valid.append(vals[i] != NULL_STR)
        values.append(String("") if vals[i] == NULL_STR else vals[i])
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    if form == FORM_FLAT:
        sb.add_field(Field("x", ArrowType.STRING, True))
    else:
        sb.add_field(Field.dictionary("x", ArrowType.INT32, True))
    rb.add_column(string_column(values, valid, form, rot))
    return rb.build(sb.build())


def _u32_batch() raises -> RecordBatch:
    var arr = PrimitiveArray[DType.uint32].allocate(2)
    arr.set(0, UInt32(1))
    arr.set(1, UInt32(2))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.UINT32, False))
    rb.add_column(Column.from_primitive[DType.uint32](arr^))
    return rb.build(sb.build())


# --- values -----------------------------------------------------------------


def _count_ints[
    dtype: DType
](at: ArrowType, a: List[Int], b: List[Int], c: List[Int]) raises -> Int:
    """COUNT(DISTINCT x) with `a` and `b` as two morsels of worker 0 and `c`
    as the morsel of worker 1."""
    var sink = _sink_x()
    sink.resize_worker_state(2)
    _feed(sink, 0, 0, _int_batch[dtype](at, a))
    _feed(sink, 0, 1, _int_batch[dtype](at, b))
    _feed(sink, 1, 2, _int_batch[dtype](at, c))
    var out = _finish(sink, 2)
    return _count_of(out)


def test_ints_are_counted_once_across_repeats_morsels_and_workers() raises:
    var a = List[Int]([5, 5, 7, NUL, 7])
    var b = List[Int]([7, 9, NUL])
    var c = List[Int]([5, 11, 11, 9])
    var d = List[Int]([NUL, 13])
    var sink = _sink_x()
    sink.resize_worker_state(3)
    _feed(sink, 0, 0, _int_batch[DType.int64](ArrowType.INT64, a))
    _feed(sink, 0, 1, _int_batch[DType.int64](ArrowType.INT64, b))
    _feed(sink, 1, 2, _int_batch[DType.int64](ArrowType.INT64, c))
    _feed(sink, 2, 3, _int_batch[DType.int64](ArrowType.INT64, d))
    var out = _finish(sink, 3)
    var want = _distinct(_cat3(a, b, _cat3(c, d, List[Int]())))
    assert_equal(want, 5)
    assert_equal(_count_of(out), want)


def test_every_integer_width_and_a_date_counts_its_distinct_values() raises:
    var a8 = List[Int]([-128, 127, -1, NUL, 127])
    var b8 = List[Int]([0, -1, 1, NUL])
    var c8 = List[Int]([-128, 2, 2, 0])
    assert_equal(_distinct(_cat3(a8, b8, c8)), 6)
    assert_equal(
        _count_ints[DType.int8](ArrowType.INT8, a8, b8, c8),
        _distinct(_cat3(a8, b8, c8)),
    )
    # 256 and 0 differ only above the low byte.
    var a16 = List[Int]([-32768, 32767, 256, NUL])
    var b16 = List[Int]([256, -256, 0, 0])
    var c16 = List[Int]([32767, 1, NUL])
    assert_equal(_distinct(_cat3(a16, b16, c16)), 6)
    assert_equal(
        _count_ints[DType.int16](ArrowType.INT16, a16, b16, c16),
        _distinct(_cat3(a16, b16, c16)),
    )
    var a32 = List[Int]([-2147483648, 2147483647, 65536, NUL, 65536])
    var b32 = List[Int]([0, 65536, -65536, 7])
    var c32 = List[Int]([2147483647, 7, NUL])
    assert_equal(_distinct(_cat3(a32, b32, c32)), 6)
    assert_equal(
        _count_ints[DType.int32](ArrowType.INT32, a32, b32, c32),
        _distinct(_cat3(a32, b32, c32)),
    )
    # 2^32 and 0 differ only in the high word.
    var a64 = List[Int]([Int(Int64.MIN), Int(Int64.MAX), 4294967296, 0, NUL])
    var b64 = List[Int]([0, 4294967296, 1, Int(Int64.MAX)])
    var c64 = List[Int]([-1, Int(Int64.MIN), NUL, 4294967297])
    assert_equal(_distinct(_cat3(a64, b64, c64)), 7)
    assert_equal(
        _count_ints[DType.int64](ArrowType.INT64, a64, b64, c64),
        _distinct(_cat3(a64, b64, c64)),
    )
    # DATE32: a column of days, no NULL.
    var ad = List[Int]([0, 19000, 19000, -1])
    var bd = List[Int]([19001, 0])
    var cd = List[Int]([19000, 20000])
    var sink = _sink_x()
    sink.resize_worker_state(2)
    _feed(sink, 0, 0, _date_batch(ad))
    _feed(sink, 0, 1, _date_batch(bd))
    _feed(sink, 1, 2, _date_batch(cd))
    var out = _finish(sink, 2)
    assert_equal(_distinct(_cat3(ad, bd, cd)), 5)
    assert_equal(_count_of(out), _distinct(_cat3(ad, bd, cd)))


def test_float64_counts_every_nan_as_one_and_the_zeros_as_one() raises:
    # Worker 0: a quiet NaN, a negative NaN, -0.0, NULL, 1.5.
    var a = List[UInt64](
        [UInt64(0x7FF8000000000000),
        UInt64(0xFFF8000000000000),
        UInt64(0x8000000000000000),
        NULL_BITS,
        UInt64(0x3FF8000000000000),]
    )
    # Worker 1: a signalling NaN, a NaN with a payload, 0.0, 1.5, 2.5, and
    # the double just above 1.5.
    var b = List[UInt64](
        [UInt64(0x7FF0000000000001),
        UInt64(0x7FF8000000000123),
        UInt64(0x0000000000000000),
        UInt64(0x3FF8000000000000),
        UInt64(0x4004000000000000),
        UInt64(0x3FF8000000000001),]
    )
    # Worker 2: an all-ones NaN, +inf, -inf, 0.0, NULL.
    var c = List[UInt64](
        [UInt64(0xFFFFFFFFFFFFFFFF),
        UInt64(0x7FF0000000000000),
        UInt64(0xFFF0000000000000),
        UInt64(0x0000000000000000),
        NULL_BITS,]
    )
    var sink = _sink_x()
    sink.resize_worker_state(3)
    _feed(sink, 0, 0, _f64_batch(a))
    _feed(sink, 1, 1, _f64_batch(b))
    _feed(sink, 2, 2, _f64_batch(c))
    var out = _finish(sink, 3)
    # NaN, zero, 1.5, the double above 1.5, 2.5, +inf and -inf.
    assert_equal(_count_of(out), 7)


def test_float32_counts_every_nan_as_one_and_the_zeros_as_one() raises:
    var a = List[UInt32](
        [UInt32(0x7FC00000), UInt32(0xFFC00000), UInt32(0x80000000), UInt32(0x12345678), UInt32(0x3FC00000)]
    )
    var b = List[UInt32](
        [UInt32(0x7F800001), UInt32(0x7FC00123), UInt32(0x00000000), UInt32(0x3FC00000), UInt32(0x40200000), UInt32(0x3FC00001)]
    )
    var c = List[UInt32](
        [UInt32(0xFFFFFFFF), UInt32(0x7F800000), UInt32(0x00000000), UInt32(0x12345678)]
    )
    var sink = _sink_x()
    sink.resize_worker_state(3)
    _feed(sink, 0, 0, _f32_batch(a))
    _feed(sink, 1, 1, _f32_batch(b))
    _feed(sink, 2, 2, _f32_batch(c))
    var out = _finish(sink, 3)
    # NaN, zero, 1.5, the float above 1.5, 2.5 and +inf.
    assert_equal(_count_of(out), 6)


def _two_to_the_64() -> I128:
    return I128(4294967296) * I128(4294967296)


def test_decimal_values_differing_in_one_word_are_distinct() raises:
    var big = _two_to_the_64()
    var zero = I128(0)
    var all_valid = List[Bool]([True, True, True, True])
    var a = List[I128]([zero, big, zero, I128(0) - I128(1)])
    var a_valid = List[Bool]([True, True, False, True])
    var b = List[I128]([big, zero - big, I128(1), zero])
    var c = List[I128]([big + I128(1), zero - I128(1), zero])
    var c_valid = List[Bool]([True, True, False])
    var sink = _sink_x()
    sink.resize_worker_state(2)
    _feed(sink, 0, 0, _dec_batch(a, a_valid))
    _feed(sink, 0, 1, _dec_batch(b, all_valid))
    _feed(sink, 1, 2, _dec_batch(c, c_valid))
    var out = _finish(sink, 2)
    # 0 and 2^64 share their low word; 2^64 and -(2^64) share it too and
    # differ in the high word; 2^64 + 1 differs from 2^64 in the low word.
    # The values are 0, 2^64, -1, -(2^64), 1 and 2^64 + 1.
    assert_equal(_count_of(out), 6)


def test_strings_count_by_content_and_the_empty_string_is_a_value() raises:
    var a = List[String](["pear", "apple", "", NULL_STR, "pear"])
    var b = List[String](["apple", "ab", "abc", "a", ""])
    var c = List[String](["abc", "apple", NULL_STR, "pear "])
    var all = List[String]()
    for i in range(len(a)):
        all.append(a[i])
    for i in range(len(b)):
        all.append(b[i])
    for i in range(len(c)):
        all.append(c[i])
    var sink = _sink_x()
    sink.resize_worker_state(2)
    _feed(sink, 0, 0, _str_batch(a))
    _feed(sink, 0, 1, _str_batch(b))
    _feed(sink, 1, 2, _str_batch(c))
    var out = _finish(sink, 2)
    # pear, apple, the empty string, ab, abc, a and "pear ".
    assert_equal(_distinct_strs(all), 7)
    assert_equal(_count_of(out), _distinct_strs(all))


def test_a_dictionary_is_read_by_value_and_mixes_with_flat_strings() raises:
    var w0a = List[String](["pear", "apple", "pear", NULL_STR])
    var w0b = List[String](["apple", "fig", "pear", "fig", NULL_STR])
    var w1 = List[String](["fig", "kiwi", NULL_STR, "kiwi", "pear"])
    var w2 = List[String](["pear", "zzz"])
    var w0c = List[String](["kiwi"])
    var all = List[String]()
    for i in range(len(w0a)):
        all.append(w0a[i])
    for i in range(len(w0b)):
        all.append(w0b[i])
    for i in range(len(w1)):
        all.append(w1[i])
    for i in range(len(w2)):
        all.append(w2[i])
    for i in range(len(w0c)):
        all.append(w0c[i])
    var sink = _sink_x()
    sink.resize_worker_state(3)
    # Each dictionary numbers its strings differently: in order of first
    # appearance, rotated by one, rotated by two with a second copy of one.
    _feed(sink, 0, 0, _str_batch(w0a, FORM_DICT))
    _feed(sink, 0, 1, _str_batch(w0b, FORM_SHUFFLED, 1))
    _feed(sink, 1, 2, _str_batch(w1, FORM_SHUFFLED, 2))
    _feed(sink, 2, 3, _str_batch(w2, FORM_FLAT))
    _feed(sink, 0, 4, _str_batch(w0c, FORM_FLAT))
    var out = _finish(sink, 3)
    # pear, apple, fig, kiwi and zzz.
    assert_equal(_distinct_strs(all), 5)
    assert_equal(_count_of(out), _distinct_strs(all))


def test_null_is_not_counted_and_no_value_counts_zero() raises:
    var only_null = List[Int]([NUL, NUL, NUL])
    var sink = _sink_x()
    sink.resize_worker_state(2)
    _feed(sink, 0, 0, _int_batch[DType.int64](ArrowType.INT64, only_null))
    _feed(sink, 1, 1, _int_batch[DType.int64](ArrowType.INT64, List[Int]([NUL])))
    _feed(sink, 1, 2, _int_batch[DType.int64](ArrowType.INT64, List[Int]()))
    var ints = _finish(sink, 2)
    assert_equal(_count_of(ints), 0)
    var strs = _sink_x()
    strs.resize_worker_state(2)
    var nulls = List[String]([NULL_STR, NULL_STR])
    _feed(strs, 0, 0, _str_batch(nulls))
    _feed(strs, 1, 1, _str_batch(nulls, FORM_SHUFFLED, 1))
    var strs_out = _finish(strs, 2)
    assert_equal(_count_of(strs_out), 0)
    # A NULL beside a value adds nothing to the value's count.
    var mixed = _sink_x()
    mixed.resize_worker_state(1)
    _feed(
        mixed,
        0,
        0,
        _int_batch[DType.int64](ArrowType.INT64, List[Int]([NUL, 4, NUL])),
    )
    var mixed_out = _finish(mixed, 1)
    assert_equal(_count_of(mixed_out), 1)


def test_no_row_gives_one_row_of_zero() raises:
    var sink = _sink_x()
    sink.resize_worker_state(3)
    var out = _finish(sink, 3)
    assert_equal(_count_of(out), 0)
    assert_equal(out.schema.field_name(0), "n0")


def _beside_aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_cd("a"))
    aggs.append(_cd("b"))
    aggs.append(_cd("s"))
    aggs.append(_agg(AGG_SUM, "b"))
    aggs.append(_agg(AGG_COUNT, "b"))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    return aggs^


def _beside_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("da", ArrowType.INT64, False))
    sb.add_field(Field("db", ArrowType.INT64, False))
    sb.add_field(Field("ds", ArrowType.INT64, False))
    sb.add_field(Field("sb", ArrowType.INT64, True))
    sb.add_field(Field("cb", ArrowType.INT64, False))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    return sb.build()


def test_it_runs_beside_sum_count_and_count_star() raises:
    var data = ungrouped_agg_data(_beside_aggs(), _beside_schema())
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(3)
    # Rows 0..29 in three morsels of ten, and rows 0..9 again on worker 2, so
    # ten values are met by two workers.
    var starts = List[Int]([0, 10, 20, 0])
    var workers = List[Int]([0, 1, 2, 2])
    var want_b = List[Int]()
    var want_a = List[Int]()
    var want_s = List[String]()
    var want_sum = 0
    var want_cb = 0
    var want_rows = 0
    for m in range(4):
        _feed(sink, workers[m], m, sample_batch(starts[m], 10))
        for i in range(10):
            var r = starts[m] + i
            want_rows += 1
            want_a.append(r)
            want_s.append(String("s") + String(r % 4))
            if b_is_null(r):
                want_b.append(NUL)
            else:
                want_b.append(r * 10)
                want_sum += r * 10
                want_cb += 1
    var out = _finish(sink, 3)
    assert_equal(_count_of(out, 0), _distinct(want_a))
    assert_equal(_count_of(out, 1), _distinct(want_b))
    assert_equal(_count_of(out, 2), _distinct_strs(want_s))
    assert_equal(_count_of(out, 0), 30)
    assert_equal(_count_of(out, 1), 24)
    assert_equal(_count_of(out, 2), 4)
    assert_equal(_count_of(out, 3), want_sum)
    assert_equal(_count_of(out, 4), want_cb)
    assert_equal(_count_of(out, 5), want_rows)


def _two_column_batch(xs: List[Int], ys: List[Int]) raises -> RecordBatch:
    var x = ColumnBuilder[DType.int64].with_capacity(len(xs))
    var y = ColumnBuilder[DType.int64].with_capacity(len(ys))
    for i in range(len(xs)):
        x.append(Int64(xs[i]))
        y.append(Int64(ys[i]))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    rb.add_column(x^.materialize())
    sb.add_field(Field("y", ArrowType.INT64, True))
    rb.add_column(y^.materialize())
    return rb.build(sb.build())


def test_two_count_distincts_over_different_columns_keep_their_own_values() raises:
    var aggs = Slab[AggExpr]()
    aggs.append(_cd("x"))
    aggs.append(_cd("y"))
    var data = ungrouped_agg_data(aggs^, _count_schema(2))
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(2)
    _feed(
        sink,
        0,
        0,
        _two_column_batch(List[Int]([1, 2, 3]), List[Int]([3, 3, 3])),
    )
    _feed(sink, 1, 1, _two_column_batch(List[Int]([2, 3]), List[Int]([3, 3])))
    var out = _finish(sink, 2)
    # x holds 1, 2 and 3; y holds only 3, a value x holds too.
    assert_equal(_count_of(out, 0), 3)
    assert_equal(_count_of(out, 1), 1)


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(
        op, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v))
    )


def _count_under_filter(op: UInt8, bound: Int, workers: Int) raises -> RecordBatch:
    """COUNT(DISTINCT a), COUNT(DISTINCT b), COUNT(DISTINCT s) over the
    hundred sample rows with the filter `a op bound`, in morsels of seven."""
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var handle = builder.add_resident(sample_batch(0, 100))
    var aggs = Slab[AggExpr]()
    aggs.append(_cd("a"))
    aggs.append(_cd("b"))
    aggs.append(_cd("s"))
    var id = builder.add_agg_sink(
        ungrouped_agg_data(aggs^, _count_schema(3))
    )
    var ops = chain(MorselOp.filter(_cmp(op, "a", bound)))
    var descs = List[SegmentDescPod]()
    descs.append(
        with_agg_sink(batch_segment(0, handle, ops^, 7), id)
    )
    var dispatch = InlineDispatch()
    var out = run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )
    return out.take(0)


def test_a_filter_keeps_rejected_rows_out_of_the_count() raises:
    var want_a = 0
    var want_b = List[Int]()
    var want_s = List[String]()
    for r in range(50, 100):
        want_a += 1
        want_s.append(String("s") + String(r % 4))
        want_b.append(NUL if b_is_null(r) else r * 10)
    for workers in range(1, 4):
        var out = _count_under_filter(BIN_GE, 50, workers)
        assert_equal(_count_of(out, 0), want_a)
        assert_equal(_count_of(out, 1), _distinct(want_b))
        assert_equal(_count_of(out, 2), _distinct_strs(want_s))
        assert_equal(_count_of(out, 1), 40)
        var none = _count_under_filter(BIN_GT, 1000, workers)
        assert_equal(_count_of(none, 0), 0)
        assert_equal(_count_of(none, 1), 0)
        assert_equal(_count_of(none, 2), 0)


def _built_with(var data: AggSinkData) raises -> String:
    """The error building the sink over `data` raises, or the empty string."""
    try:
        _ = AggSink(data, SegmentPool(), 0)
    except e:
        return String(e)
    return String("")


def _one_count(t: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("n0", t, False))
    return sb.build()


def test_what_the_sink_refuses_when_it_is_built() raises:
    assert_equal(
        _built_with(
            ungrouped_agg_data(
                agg_list(AggExpr(AGG_COUNT_DISTINCT, None, None)),
                _count_schema(1),
            )
        ),
        "pipeline_exec: the aggregation sink of segment 0: COUNT(DISTINCT)"
        " (output column 0) has no argument",
    )
    assert_equal(
        _built_with(
            ungrouped_agg_data(
                agg_list(_cd("x")), _one_count(ArrowType.FLOAT64)
            )
        ),
        "pipeline_exec: COUNT(DISTINCT) (output column 0) cannot produce the"
        " declared output type float64 of column 0",
    )
    assert_equal(
        _built_with(
            ungrouped_agg_data(
                agg_list(_cd("x")), _one_count(ArrowType.INT32)
            )
        ),
        "pipeline_exec: COUNT(DISTINCT) (output column 0) cannot produce the"
        " declared output type int32 of column 0",
    )
    # INT64 is what it produces.
    assert_equal(
        _built_with(
            ungrouped_agg_data(agg_list(_cd("x")), _one_count(ArrowType.INT64))
        ),
        "",
    )


def test_an_argument_type_it_does_not_serve_is_refused_by_name() raises:
    var sink = _sink_x()
    sink.resize_worker_state(1)
    assert_equal(
        _failure_of_feed(sink, 0, 0, _u32_batch()),
        "pipeline_exec: COUNT(DISTINCT) (output column 0) is not served over"
        " this column type (uint32): COUNT(DISTINCT) takes INT8 to INT64,"
        " DATE32, FLOAT32, FLOAT64, DECIMAL128 and strings",
    )


def test_a_column_that_changes_type_between_morsels_of_a_worker_is_refused() raises:
    var changed = (
        "pipeline_exec: COUNT(DISTINCT) (output column 0) saw a column of"
        " another type than the morsels before it"
    )
    var sink = _sink_x()
    sink.resize_worker_state(1)
    assert_equal(
        _failure_of_feed(
            sink, 0, 0, _int_batch[DType.int64](ArrowType.INT64, List[Int]([1]))
        ),
        "",
    )
    assert_equal(
        _failure_of_feed(
            sink, 0, 1, _int_batch[DType.int32](ArrowType.INT32, List[Int]([1]))
        ),
        changed,
    )
    # DATE32 and INT32 are one storage and two types.
    var days = _sink_x()
    days.resize_worker_state(1)
    assert_equal(_failure_of_feed(days, 0, 0, _date_batch(List[Int]([1]))), "")
    assert_equal(
        _failure_of_feed(
            days, 0, 1, _int_batch[DType.int32](ArrowType.INT32, List[Int]([1]))
        ),
        changed,
    )


def test_a_column_of_other_types_on_different_workers_is_refused_at_combine() raises:
    var sink = _sink_x()
    sink.resize_worker_state(2)
    _feed(sink, 0, 0, _int_batch[DType.int64](ArrowType.INT64, List[Int]([1])))
    _feed(sink, 1, 1, _f64_batch(List[UInt64]([UInt64(0x3FF8000000000000)])))
    assert_equal(
        _failure_of_finish(sink, 2),
        "pipeline_exec: COUNT(DISTINCT) (output column 0) saw columns of"
        " different types on different workers",
    )
    # A worker that saw no morsel is no other type.
    var idle = _sink_x()
    idle.resize_worker_state(2)
    _feed(idle, 1, 0, _f64_batch(List[UInt64]([UInt64(0x3FF8000000000000)])))
    var idle_out = _finish(idle, 2)
    assert_equal(_count_of(idle_out), 1)


def test_a_pool_too_small_for_the_distinct_values_is_refused_by_name() raises:
    var state = size_of[AggCell]()
    var entries = 64 * GroupTable(4, 0).per_group_bytes()
    # The cells of the sink fit, the first 64 distinct entries do not.
    var budget = state + entries // 2
    var pool = SegmentPool(budget)
    var sink = _sink_x(pool.share())
    sink.resize_worker_state(1)
    assert_equal(
        _failure_of_feed(
            sink,
            0,
            0,
            _int_batch[DType.int64](ArrowType.INT64, List[Int]([1, 2, 3])),
        ),
        "MEMORY_BUDGET_EXCEEDED: pipeline_exec: the aggregation sink of"
        " segment 0 was denied "
        + String(entries)
        + " bytes of the segment's memory pool for its COUNT(DISTINCT) values"
        " (budget "
        + String(budget)
        + ", granted "
        + String(state)
        + ")",
    )
    _ = sink^
    assert_equal(pool.granted(), 0)
    # The same for the strings the values are interned as.
    var small = state + 1000
    var spool = SegmentPool(small)
    var strs = _sink_x(spool.share())
    strs.resize_worker_state(1)
    var failure = _failure_of_feed(
        strs, 0, 0, _str_batch(List[String](["a", "b"]))
    )
    assert_true(
        "pipeline_exec: the aggregation sink of segment 0 was denied "
        in failure,
        failure,
    )
    assert_true(
        "bytes of the segment's memory pool for its COUNT(DISTINCT) values"
        " (budget "
        + String(small)
        + ", granted "
        + String(state)
        + ")"
        in failure,
        failure,
    )
    _ = strs^
    assert_equal(spool.granted(), 0)


def _two_workers(ref pool: SegmentPool) raises -> AggSink:
    """A sink whose two workers hold the distinct values 1 to 3 and 3 to 5."""
    var sink = _sink_x(pool.share())
    sink.resize_worker_state(2)
    _feed(
        sink, 0, 0, _int_batch[DType.int64](ArrowType.INT64, List[Int]([1, 2, 3]))
    )
    _feed(
        sink, 1, 1, _int_batch[DType.int64](ArrowType.INT64, List[Int]([3, 4, 5]))
    )
    return sink^


def test_a_pool_too_small_for_the_merge_is_refused_and_returned() raises:
    # Measure what the two workers hold, whatever the block size is.
    var probe = SegmentPool(1 << 20)
    var measured = _two_workers(probe)
    var held = probe.granted()
    _ = measured^
    assert_equal(probe.granted(), 0)
    # Room for the workers and nothing for the merge's table.
    var tight = SegmentPool(held)
    var sink = _two_workers(tight)
    assert_equal(tight.granted(), held)
    with assert_raises(contains="for its COUNT(DISTINCT) values"):
        _ = _finish(sink, 2)
    _ = sink^
    assert_equal(tight.granted(), 0)
    # With room for the merge the same morsels merge: 1 to 5.
    var roomy = SegmentPool(held + 65536)
    var ok = _two_workers(roomy)
    var ok_out = _finish(ok, 2)
    assert_equal(_count_of(ok_out), 5)
    assert_equal(roomy.granted(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
