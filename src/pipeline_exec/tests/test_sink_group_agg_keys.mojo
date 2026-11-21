# =============================================================================
# The grouped aggregation sink over DATE32, BOOL and DECIMAL128 keys
# =============================================================================
#
# The tests hand the sink morsels, a different worker for each, as
# test_sink_group_agg does. The key of row r is a function of the row number
# alone (below), and the expected COUNT(*) and SUM(v) (v = r * 3 - 50, no
# NULL) per group come from a plain loop over the rows with a `Dict` from the
# key's text to a running tally, never from the engine. What they prove:
#
#   * test_date32_keys_group_by_day_number_with_negative_days_and_nulls: rows
#     over several morsels and three workers, days before the epoch (negative
#     day numbers), 0, -1 and a large day number, and NULL keys: every group
#     has the oracle's COUNT(*) and SUM, the output key column is DATE32 with
#     the day numbers, and the NULL group is one group, distinct from day 0.
#   * test_date32_keys_without_nulls_group_by_day_number: the same without a
#     NULL in the input.
#   * test_bool_keys_are_three_groups_true_false_and_null: true, false and NULL
#     are exactly three groups, morsels of 13 rows (a bit length that is not a
#     whole number of bytes); NULL is not merged with false; the output key
#     column is BOOL.
#   * test_bool_keys_without_nulls_are_two_groups: the same without a NULL.
#   * test_decimal_keys_past_int64_are_told_apart_by_both_words: DECIMAL(30,4)
#     keys whose unscaled value does not fit an INT64, -1 (low and high words
#     all ones) against 2^64 - 1 (low word all ones, high word 0), 2^64 (low
#     word 0, high word 1), -2^64 and zero, with NULL keys: equal values
#     across workers are one group, NULL is a group of its own, the output
#     column is DECIMAL128 with precision 30, scale 4 and the exact unscaled
#     values.
#   * test_decimal_keys_without_nulls_are_told_apart_by_both_words: the same
#     without a NULL.
#   * test_two_decimal_keys_group_by_the_pair_so_swapped_pairs_differ: two
#     DECIMAL(30,4) key columns, so the second key's cells start after the
#     first's two: (x, y) and (y, x) are different groups, with the oracle's
#     counts.
#   * test_two_decimal_keys_with_a_null_in_one_column_only: NULL in the first
#     column only, in the second only and in both are groups of their own.
#   * test_no_row_gives_no_group_and_the_declared_columns_for_each_new_row: a
#     sink of each row that was fed nothing outputs no rows and the declared
#     columns (key type, and the decimal key's precision and scale).
#   * test_a_key_column_of_the_wrong_family_is_refused_when_rows_arrive: the
#     DATE32 row fed an INT32 column, the BOOL row an INT64 column, the
#     DECIMAL128 row an INT64 column and the I64 row a DATE32 column are each
#     refused by the name of what the row keys.
#   * test_a_decimal_key_column_of_another_scale_or_wider_precision_is_refused:
#     DECIMAL(30,2) and DECIMAL(38,4) columns into a declared DECIMAL(30,4).
#   * test_a_decimal_key_column_of_a_narrower_precision_is_accepted: a
#     DECIMAL(20,4) column into a declared DECIMAL(30,4) groups by value and
#     the output keeps (30, 4).
#   * test_a_declared_key_type_its_row_does_not_key_is_refused_when_built: the
#     DATE32 row declaring INT32, the BOOL row declaring INT64 and the
#     DECIMAL128 row declaring DATE32.

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import (
    KEY_DTYPE_BOOL,
    KEY_DTYPE_DATE32,
    KEY_DTYPE_DECIMAL128,
    KEY_DTYPE_I64,
)
from pipeline_exec.group_harness import v_value
from pipeline_exec.plan_harness import grouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_group_agg import GroupAggSink
from plan_expr.agg_expr import AGG_COUNT, AGG_SUM, AggExpr
from plan_expr.expr import Expr
from scalar_arithmetic.decimal_arith import I128


# The kinds of fixture: the key column(s) of a batch.
comptime KIND_DATE: Int = 0
comptime KIND_BOOL: Int = 1
comptime KIND_DECIMAL: Int = 2
comptime KIND_PAIR: Int = 3


def _day(r: Int) -> Int:
    """The day number of row r (NULL for r % 7 == 0 when the input has NULLs,
    else 365)."""
    var c = r % 7
    if c == 0:
        return 365
    if c == 1:
        return 0
    if c == 2:
        return -1
    if c == 3:
        return -18262
    if c == 4:
        return 20000
    if c == 5:
        return 2932896
    return -719162


def _flag(r: Int) -> Bool:
    """The BOOL key of row r (NULL for r % 5 == 0 when the input has NULLs,
    else true)."""
    var c = r % 5
    return c == 0 or c == 1 or c == 3


def _pow10(n: Int) -> I128:
    var out = I128(1)
    for _ in range(n):
        out = out * I128(10)
    return out


def _two_to_64() -> I128:
    return I128(4294967296) * I128(4294967296)


def _dec_value(c: Int) -> I128:
    """The unscaled value of decimal class c (0 to 7)."""
    if c == 0:
        return I128(5)
    if c == 1:
        return I128(-1)
    if c == 2:
        return _two_to_64() - I128(1)
    if c == 3:
        return _two_to_64()
    if c == 4:
        return I128(0) - _two_to_64()
    if c == 5:
        return _pow10(25) + I128(7)
    if c == 6:
        return I128(0)
    return I128(0) - _pow10(29)


def _class_of(v: I128) -> Int:
    for c in range(8):
        if v == _dec_value(c):
            return c
    return -1


# DECIMAL keys: row r has class r % 8 (NULL for class 0 when the input has
# NULLs, else the value 5). Pair keys: the first column has class 1 + r % 4
# (NULL for r % 5 == 0 with NULLs), the second class 1 + (r // 4) % 4 (NULL
# for r % 7 == 0 with NULLs).
def _pair_a_class(r: Int) -> Int:
    return 1 + r % 4


def _pair_b_class(r: Int) -> Int:
    return 1 + (r // 4) % 4


def _pair_a_null(r: Int, nulls: Bool) -> Bool:
    return nulls and r % 5 == 0


def _pair_b_null(r: Int, nulls: Bool) -> Bool:
    return nulls and r % 7 == 0


def _add_v(
    mut sb: SchemaBuilder, mut rb: RecordBatchBuilder, start: Int, n: Int
) raises:
    var v = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        v.set(i, Int64(v_value(start + i)))
    sb.add_field(Field("v", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](v^))


def _date_batch(start: Int, n: Int, nulls: Bool) raises -> RecordBatch:
    var k = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        var r = start + i
        k.set(i, Int32(_day(r)))
        if nulls and r % 7 == 0:
            k._set_null(i)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.DATE32, True))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            k^, ArrowType.DATE32
        )
    )
    _add_v(sb, rb, start, n)
    return rb.build(sb.build())


def _bool_batch(start: Int, n: Int, nulls: Bool) raises -> RecordBatch:
    var k = BooleanArray.allocate_nullable(n)
    for i in range(n):
        var r = start + i
        k.set(i, _flag(r))
        if nulls and r % 5 == 0:
            k._set_null(i)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.BOOL, True))
    rb.add_column(Column.from_boolean(k^))
    _add_v(sb, rb, start, n)
    return rb.build(sb.build())


def _decimal_batch(start: Int, n: Int, nulls: Bool) raises -> RecordBatch:
    var k = Decimal128Array.allocate_nullable(n, 30, 4)
    for i in range(n):
        var r = start + i
        if nulls and r % 8 == 0:
            k.set_null(i)
        else:
            k.set_i128(i, _dec_value(r % 8))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("k", 30, 4, True))
    rb.add_column(Column.from_decimal128(k^))
    _add_v(sb, rb, start, n)
    return rb.build(sb.build())


def _pair_batch(start: Int, n: Int, nulls: Bool) raises -> RecordBatch:
    var a = Decimal128Array.allocate_nullable(n, 30, 4)
    var b = Decimal128Array.allocate_nullable(n, 30, 4)
    for i in range(n):
        var r = start + i
        if _pair_a_null(r, nulls):
            a.set_null(i)
        else:
            a.set_i128(i, _dec_value(_pair_a_class(r)))
        if _pair_b_null(r, nulls):
            b.set_null(i)
        else:
            b.set_i128(i, _dec_value(_pair_b_class(r)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("a", 30, 4, True))
    rb.add_column(Column.from_decimal128(a^))
    sb.add_field(Field.decimal128("b", 30, 4, True))
    rb.add_column(Column.from_decimal128(b^))
    _add_v(sb, rb, start, n)
    return rb.build(sb.build())


def _int_batch[dtype: DType](n: Int, arrow: ArrowType) raises -> RecordBatch:
    """A key column "k" of `arrow` (storage `dtype`) holding r % 3."""
    var k = PrimitiveArray[dtype].allocate(n)
    for i in range(n):
        k.set(i, Scalar[dtype](i % 3))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", arrow, False))
    rb.add_column(Column.from_primitive[dtype](k^))
    _add_v(sb, rb, 0, n)
    return rb.build(sb.build())


def _small_value(r: Int) -> Int:
    if r % 3 == 0:
        return 5
    if r % 3 == 1:
        return -1
    return 123456


def _scaled_batch(n: Int, precision: Int, scale: Int) raises -> RecordBatch:
    """A DECIMAL(precision, scale) key column "k" holding _small_value(r)."""
    var k = Decimal128Array.allocate_nullable(n, precision, scale)
    for i in range(n):
        k.set_i128(i, I128(_small_value(i)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("k", precision, scale, True))
    rb.add_column(Column.from_decimal128(k^))
    _add_v(sb, rb, 0, n)
    return rb.build(sb.build())


def _batch(kind: Int, start: Int, n: Int, nulls: Bool) raises -> RecordBatch:
    if kind == KIND_DATE:
        return _date_batch(start, n, nulls)
    if kind == KIND_BOOL:
        return _bool_batch(start, n, nulls)
    if kind == KIND_DECIMAL:
        return _decimal_batch(start, n, nulls)
    return _pair_batch(start, n, nulls)


def _make_sink(
    mut sb: SchemaBuilder, names: List[String], key_dtype: UInt8
) raises -> GroupAggSink:
    """A sink grouping by the columns `names`, whose output schema starts
    with the key fields already in `sb`, then COUNT(*) and SUM(v)."""
    var keys = Slab[Expr]()
    for i in range(len(names)):
        keys.append(Expr.col_ref(names[i]))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("v")), None))
    sb.add_field(Field("n", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    return GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        key_dtype,
        SegmentPool(),
        0,
    )


def _names(first: String) -> List[String]:
    var out = List[String]()
    out.append(first)
    return out^


def _sink_t(t: ArrowType, key_dtype: UInt8) raises -> GroupAggSink:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", t, True))
    return _make_sink(sb, _names("k"), key_dtype)


def _sink_dec(precision: Int, scale: Int) raises -> GroupAggSink:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("k", precision, scale, True))
    return _make_sink(sb, _names("k"), KEY_DTYPE_DECIMAL128)


def _sink_pair() raises -> GroupAggSink:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("a", 30, 4, True))
    sb.add_field(Field.decimal128("b", 30, 4, True))
    var names = _names("a")
    names.append("b")
    return _make_sink(sb, names, KEY_DTYPE_DECIMAL128)


def _sink_of(kind: Int) raises -> GroupAggSink:
    if kind == KIND_DATE:
        return _sink_t(ArrowType.DATE32, KEY_DTYPE_DATE32)
    if kind == KIND_BOOL:
        return _sink_t(ArrowType.BOOL, KEY_DTYPE_BOOL)
    if kind == KIND_DECIMAL:
        return _sink_dec(30, 4)
    return _sink_pair()


def _combine_and_take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _run(
    kind: Int, rows: Int, morsel: Int, workers: Int, nulls: Bool
) raises -> RecordBatch:
    """Rows 0 .. rows - 1 in morsels of `morsel`, morsel m to worker
    m % workers."""
    var sink = _sink_of(kind)
    sink.resize_worker_state(workers)
    var m = 0
    var start = 0
    while start < rows:
        var n = min(morsel, rows - start)
        sink.consume(m % workers, Morsel(_batch(kind, start, n, nulls), m, 0))
        m += 1
        start += n
    return _combine_and_take(sink, workers)


def _row_text(kind: Int, r: Int, nulls: Bool) -> String:
    """The group of row r, as text, from the generators."""
    if kind == KIND_DATE:
        if nulls and r % 7 == 0:
            return "N"
        return String(_day(r))
    if kind == KIND_BOOL:
        if nulls and r % 5 == 0:
            return "N"
        return "T" if _flag(r) else "F"
    if kind == KIND_DECIMAL:
        if nulls and r % 8 == 0:
            return "N"
        return String(r % 8)
    var a = String("N") if _pair_a_null(r, nulls) else String(_pair_a_class(r))
    var b = String("N") if _pair_b_null(r, nulls) else String(_pair_b_class(r))
    return a + "|" + b


def _cell_text(kind: Int, ref out: RecordBatch, k: Int, i: Int) raises -> String:
    """The group key column k of output row i, as text."""
    if out.column_at(k).is_null_at(i):
        return "N"
    if kind == KIND_DATE:
        return String(
            Int(out.column_at(k).as_primitive[DType.int32]().get(i))
        )
    if kind == KIND_BOOL:
        return "T" if out.column_at(k).as_boolean().get(i) else "F"
    var c = _class_of(out.column_at(k).as_decimal128().get_i128(i))
    assert_true(c >= 0, "a decimal key that no input row holds")
    return String(c)


def _check(
    ref out: RecordBatch, kind: Int, rows: Int, nulls: Bool, nk: Int
) raises:
    var want_n = Dict[String, Int]()
    var want_sum = Dict[String, Int]()
    for r in range(rows):
        var key = _row_text(kind, r, nulls)
        want_n[key] = want_n.get(key, 0) + 1
        want_sum[key] = want_sum.get(key, 0) + v_value(r)
    assert_equal(out.num_rows(), len(want_n), "number of groups")
    assert_equal(out.num_columns(), nk + 2)
    var n = out.column_at(nk).as_primitive[DType.int64]()
    var sv = out.column_at(nk + 1).as_primitive[DType.int64]()
    var seen = Dict[String, Bool]()
    for i in range(out.num_rows()):
        var key = _cell_text(kind, out, 0, i)
        if nk == 2:
            key += "|" + _cell_text(kind, out, 1, i)
        assert_true(key in want_n, "unexpected group " + key)
        assert_true(key not in seen, "group " + key + " twice")
        seen[key] = True
        assert_equal(Int(n.get(i)), want_n[key], "COUNT(*) of " + key)
        assert_equal(Int(sv.get(i)), want_sum[key], "SUM(v) of " + key)


def test_date32_keys_group_by_day_number_with_negative_days_and_nulls() raises:
    var out = _run(KIND_DATE, 400, 37, 3, True)
    _check(out, KIND_DATE, 400, True, 1)
    assert_equal(out.schema.field_arrow_type(0), ArrowType.DATE32)
    assert_equal(out.column_at(0).arrow_type, ArrowType.DATE32)
    # Seven classes: NULL, 0, -1, -18262, 20000, 2932896 and -719162.
    assert_equal(out.num_rows(), 7)
    var seen_zero = False
    var seen_null = False
    for i in range(out.num_rows()):
        if out.column_at(0).is_null_at(i):
            seen_null = True
        elif out.column_at(0).as_primitive[DType.int32]().get(i) == 0:
            seen_zero = True
    assert_true(seen_null and seen_zero, "NULL and day 0 are both groups")


def test_date32_keys_without_nulls_group_by_day_number() raises:
    var out = _run(KIND_DATE, 400, 37, 3, False)
    _check(out, KIND_DATE, 400, False, 1)
    assert_equal(out.num_rows(), 7)
    assert_equal(out.column_at(0).null_count(), 0)


def test_bool_keys_are_three_groups_true_false_and_null() raises:
    var out = _run(KIND_BOOL, 100, 13, 3, True)
    _check(out, KIND_BOOL, 100, True, 1)
    assert_equal(out.num_rows(), 3)
    assert_equal(out.schema.field_arrow_type(0), ArrowType.BOOL)
    assert_equal(out.column_at(0).arrow_type, ArrowType.BOOL)
    assert_equal(out.column_at(0).null_count(), 1)


def test_bool_keys_without_nulls_are_two_groups() raises:
    var out = _run(KIND_BOOL, 100, 13, 3, False)
    _check(out, KIND_BOOL, 100, False, 1)
    assert_equal(out.num_rows(), 2)
    assert_equal(out.column_at(0).null_count(), 0)


def test_decimal_keys_past_int64_are_told_apart_by_both_words() raises:
    var out = _run(KIND_DECIMAL, 400, 37, 3, True)
    _check(out, KIND_DECIMAL, 400, True, 1)
    # Classes 1 to 7 and NULL.
    assert_equal(out.num_rows(), 8)
    assert_equal(out.schema.field_arrow_type(0), ArrowType.DECIMAL128)
    assert_equal(out.column_at(0).decimal_precision(), 30)
    assert_equal(out.column_at(0).decimal_scale(), 4)
    assert_equal(out.schema.field_decimal_precision(0), 30)
    assert_equal(out.schema.field_decimal_scale(0), 4)


def test_decimal_keys_without_nulls_are_told_apart_by_both_words() raises:
    var out = _run(KIND_DECIMAL, 400, 37, 3, False)
    _check(out, KIND_DECIMAL, 400, False, 1)
    assert_equal(out.num_rows(), 8)
    assert_equal(out.column_at(0).null_count(), 0)
    assert_equal(out.column_at(0).decimal_precision(), 30)
    assert_equal(out.column_at(0).decimal_scale(), 4)


def test_two_decimal_keys_group_by_the_pair_so_swapped_pairs_differ() raises:
    var out = _run(KIND_PAIR, 320, 29, 3, False)
    _check(out, KIND_PAIR, 320, False, 2)
    # Every (x, y) of four classes each: sixteen groups, (x, y) and (y, x)
    # among them.
    assert_equal(out.num_rows(), 16)
    for k in range(2):
        assert_equal(out.column_at(k).decimal_precision(), 30)
        assert_equal(out.column_at(k).decimal_scale(), 4)


def test_two_decimal_keys_with_a_null_in_one_column_only() raises:
    var out = _run(KIND_PAIR, 700, 41, 3, True)
    _check(out, KIND_PAIR, 700, True, 2)
    var only_a = False
    var only_b = False
    var both = False
    for i in range(out.num_rows()):
        var a = out.column_at(0).is_null_at(i)
        var b = out.column_at(1).is_null_at(i)
        only_a = only_a or (a and not b)
        only_b = only_b or (b and not a)
        both = both or (a and b)
    assert_true(only_a and only_b and both, "all three NULL shapes occur")


def test_no_row_gives_no_group_and_the_declared_columns_for_each_new_row() raises:
    for kind in range(4):
        var sink = _sink_of(kind)
        sink.resize_worker_state(3)
        var out = _combine_and_take(sink, 3)
        var nk = 2 if kind == KIND_PAIR else 1
        assert_equal(out.num_rows(), 0)
        assert_equal(out.num_columns(), nk + 2)
        if kind == KIND_DATE:
            assert_equal(out.schema.field_arrow_type(0), ArrowType.DATE32)
        elif kind == KIND_BOOL:
            assert_equal(out.schema.field_arrow_type(0), ArrowType.BOOL)
        else:
            for k in range(nk):
                assert_equal(
                    out.schema.field_arrow_type(k), ArrowType.DECIMAL128
                )
                assert_equal(out.schema.field_decimal_precision(k), 30)
                assert_equal(out.schema.field_decimal_scale(k), 4)


def test_a_key_column_of_the_wrong_family_is_refused_when_rows_arrive() raises:
    var date_row = _sink_t(ArrowType.DATE32, KEY_DTYPE_DATE32)
    date_row.resize_worker_state(1)
    with assert_raises(contains="the DATE32 row keys DATE32"):
        date_row.consume(
            0, Morsel(_int_batch[DType.int32](9, ArrowType.INT32), 0, 0)
        )
    var bool_row = _sink_t(ArrowType.BOOL, KEY_DTYPE_BOOL)
    bool_row.resize_worker_state(1)
    with assert_raises(contains="the BOOL row keys BOOL"):
        bool_row.consume(
            0, Morsel(_int_batch[DType.int64](9, ArrowType.INT64), 0, 0)
        )
    var dec_row = _sink_dec(30, 4)
    dec_row.resize_worker_state(1)
    with assert_raises(contains="the DECIMAL128 row keys DECIMAL128"):
        dec_row.consume(
            0, Morsel(_int_batch[DType.int64](9, ArrowType.INT64), 0, 0)
        )
    var int_row = _sink_t(ArrowType.INT64, KEY_DTYPE_I64)
    int_row.resize_worker_state(1)
    with assert_raises(contains="the I64 and I32 rows key INT8 to INT64"):
        int_row.consume(0, Morsel(_date_batch(0, 9, False), 0, 0))


def test_a_decimal_key_column_of_another_scale_or_wider_precision_is_refused() raises:
    var other_scale = _sink_dec(30, 4)
    other_scale.resize_worker_state(1)
    with assert_raises(
        contains=(
            "is a DECIMAL(30, 2) column, and the sink declares the key"
            " DECIMAL(30, 4)"
        )
    ):
        other_scale.consume(0, Morsel(_scaled_batch(9, 30, 2), 0, 0))
    var wider = _sink_dec(30, 4)
    wider.resize_worker_state(1)
    with assert_raises(
        contains=(
            "is a DECIMAL(38, 4) column, and the sink declares the key"
            " DECIMAL(30, 4)"
        )
    ):
        wider.consume(0, Morsel(_scaled_batch(9, 38, 4), 0, 0))


def test_a_decimal_key_column_of_a_narrower_precision_is_accepted() raises:
    var sink = _sink_dec(30, 4)
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(_scaled_batch(30, 20, 4), 0, 0))
    sink.consume(1, Morsel(_scaled_batch(30, 20, 4), 1, 0))
    var out = _combine_and_take(sink, 2)
    assert_equal(out.num_rows(), 3)
    assert_equal(out.column_at(0).decimal_precision(), 30)
    assert_equal(out.column_at(0).decimal_scale(), 4)
    var keys = out.column_at(0).as_decimal128()
    var n = out.column_at(1).as_primitive[DType.int64]()
    var sv = out.column_at(2).as_primitive[DType.int64]()
    var want_n = Dict[Int, Int]()
    var want_sum = Dict[Int, Int]()
    for r in range(30):
        var key = _small_value(r)
        # Each of the two workers holds rows 0 to 29.
        want_n[key] = want_n.get(key, 0) + 2
        want_sum[key] = want_sum.get(key, 0) + 2 * v_value(r)
    for i in range(3):
        var found = False
        for j in range(3):
            var key = _small_value(j)
            if keys.get_i128(i) == I128(key):
                found = True
                assert_equal(Int(n.get(i)), want_n[key], "COUNT(*)")
                assert_equal(Int(sv.get(i)), want_sum[key], "SUM(v)")
        assert_true(found, "a group key that no row holds")


def test_a_declared_key_type_its_row_does_not_key_is_refused_when_built() raises:
    with assert_raises(contains="which its row does not key"):
        _ = _sink_t(ArrowType.INT32, KEY_DTYPE_DATE32)
    with assert_raises(contains="which its row does not key"):
        _ = _sink_t(ArrowType.INT64, KEY_DTYPE_BOOL)
    with assert_raises(contains="which its row does not key"):
        _ = _sink_t(ArrowType.DATE32, KEY_DTYPE_DECIMAL128)


def main() raises:
    var suite = TestSuite()
    suite.test[test_date32_keys_group_by_day_number_with_negative_days_and_nulls]()
    suite.test[test_date32_keys_without_nulls_group_by_day_number]()
    suite.test[test_bool_keys_are_three_groups_true_false_and_null]()
    suite.test[test_bool_keys_without_nulls_are_two_groups]()
    suite.test[test_decimal_keys_past_int64_are_told_apart_by_both_words]()
    suite.test[test_decimal_keys_without_nulls_are_told_apart_by_both_words]()
    suite.test[test_two_decimal_keys_group_by_the_pair_so_swapped_pairs_differ]()
    suite.test[test_two_decimal_keys_with_a_null_in_one_column_only]()
    suite.test[test_no_row_gives_no_group_and_the_declared_columns_for_each_new_row]()
    suite.test[test_a_key_column_of_the_wrong_family_is_refused_when_rows_arrive]()
    suite.test[test_a_decimal_key_column_of_another_scale_or_wider_precision_is_refused]()
    suite.test[test_a_decimal_key_column_of_a_narrower_precision_is_accepted]()
    suite.test[test_a_declared_key_type_its_row_does_not_key_is_refused_when_built]()
    suite^.run()
