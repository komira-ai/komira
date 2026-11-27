# =============================================================================
# Tests for the epoch-count units of `EXPR_EXTRACT` through the column
# evaluator: `EXTRACT_EPOCH` (FLOAT64 seconds), `EXTRACT_EPOCH_MS` and
# `EXTRACT_EPOCH_US` (INT64), over the column types a plan reads them from.
#
# Expected values are DuckDB v1.5.5's for the same instant (quoted beside
# each case). The round-trip cases build the exact expression the SQL binder
# lowers `make_timestamp(n)` and `make_timestamp_ms(n)` to, so a count that
# goes in comes back out unchanged.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.testing import assert_raises

from arrow.primitive_array import PrimitiveArray
from arrow.column import Column
from arrow.arrow_types import ArrowType
from arrow.schema import SchemaBuilder, Field, RecordBatch, RecordBatchBuilder

from plan_expr.expr import (
    Expr, EXTRACT_EPOCH, EXTRACT_EPOCH_MS, EXTRACT_EPOCH_US,
)
from batch_eval.eval_column import _eval_column_expr


def _batch(
    vals: List[Int64], null_row: Int, column_type: ArrowType, field_type: ArrowType
) raises -> RecordBatch:
    """One Int64-stored column named "x", stamped `column_type`, declared
    `field_type` on the schema; row `null_row` is NULL (-1 for none)."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
    if null_row >= 0:
        arr.validity.value().clear(null_row)
        arr.null_count = 1
    var c = Column.from_primitive[DType.int64](arr^)
    c.arrow_type = column_type
    var sb = SchemaBuilder()
    sb.add_field(Field("x", field_type, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _date_batch(vals: List[Int32], null_row: Int) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int32](vals[i]))
    if null_row >= 0:
        arr.validity.value().clear(null_row)
        arr.null_count = 1
    var c = Column.from_primitive[DType.int32](arr^)
    c.arrow_type = ArrowType.DATE32
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.DATE32, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _x() -> Expr:
    return Expr.col_ref(String("x"))


def test_epoch_of_a_timestamp_is_a_float64_column_of_seconds() raises:
    """epoch(TIMESTAMP '2026-09-01 00:00:00.123456') = 1788220800.123456,
    epoch(TIMESTAMP '1969-12-31 23:59:59.9995') = -0.0005, and the column is
    FLOAT64 (DOUBLE), not INT64."""
    var rb = _batch([Int64(1788220800123456), Int64(-500)], -1, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_US)
    var c = _eval_column_expr(Expr.extract(EXTRACT_EPOCH, _x()), rb)
    assert_equal(Int(c.arrow_type.type_id), Int(ArrowType.FLOAT64.type_id))
    var pa = c.as_primitive[DType.float64]()
    assert_equal(pa.get(0), Float64(1788220800.123456))
    assert_equal(pa.get(1), Float64(-0.0005))


def test_epoch_ms_and_epoch_us_are_int64_columns() raises:
    """epoch_ms / epoch_us of TIMESTAMP '1969-12-31 23:59:59.9995' are 0 and
    -500 (BIGINT); of TIMESTAMP '2100-01-01', 4102444800000 and
    4102444800000000 — past 2038 and exact."""
    var rb = _batch([Int64(-500), Int64(4102444800000000)], -1, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_US)
    var ms = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_MS, _x()), rb)
    var us = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_US, _x()), rb)
    assert_equal(Int(ms.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    assert_equal(Int(us.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    assert_equal(ms.as_primitive[DType.int64]().get(0), Int64(0))
    assert_equal(us.as_primitive[DType.int64]().get(0), Int64(-500))
    assert_equal(ms.as_primitive[DType.int64]().get(1), Int64(4102444800000))
    assert_equal(us.as_primitive[DType.int64]().get(1), Int64(4102444800000000))


def test_epoch_ms_round_trips_make_timestamp_ms() raises:
    """make_timestamp_ms(n) lowers to CAST(CAST(n AS TIMESTAMP_MS) AS
    TIMESTAMP_US); epoch_ms of that is n again, before and after 1970, and a
    NULL count stays NULL."""
    var counts: List[Int64] = [Int64(1788220800123), Int64(-1), Int64(0), Int64(-62135596800000)]
    var rb = _batch(counts, 2, ArrowType.INT64, ArrowType.INT64)
    var ts = Expr.cast_to_arrow(Expr.cast_to_arrow(_x(), ArrowType.TIMESTAMP_MS), ArrowType.TIMESTAMP_US)
    var c = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_MS, ts^), rb)
    var pa = c.as_primitive[DType.int64]()
    assert_equal(pa.get(0), counts[0])
    assert_equal(pa.get(1), counts[1])
    assert_true(pa.is_null(2))
    assert_equal(pa.get(3), counts[3])


def test_epoch_us_round_trips_make_timestamp() raises:
    """make_timestamp(n) lowers to CAST(n AS TIMESTAMP_US); epoch_us of that
    is n again, and epoch of it is n / 1e6."""
    var counts: List[Int64] = [Int64(1788220800123456), Int64(-1), Int64(253402300799999999)]
    var rb = _batch(counts, -1, ArrowType.INT64, ArrowType.INT64)
    var us = _eval_column_expr(
        Expr.extract(EXTRACT_EPOCH_US, Expr.cast_to_arrow(_x(), ArrowType.TIMESTAMP_US)), rb
    ).as_primitive[DType.int64]()
    for i in range(len(counts)):
        assert_equal(us.get(i), counts[i])
    var s = _eval_column_expr(
        Expr.extract(EXTRACT_EPOCH, Expr.cast_to_arrow(_x(), ArrowType.TIMESTAMP_US)), rb
    ).as_primitive[DType.float64]()
    assert_equal(s.get(1), Float64(-0.000001))


def test_null_timestamp_gives_null_counts() raises:
    """A NULL TIMESTAMP is a NULL epoch, epoch_ms and epoch_us."""
    var rb = _batch([Int64(0), Int64(1)], 0, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_US)
    for unit in [EXTRACT_EPOCH, EXTRACT_EPOCH_MS, EXTRACT_EPOCH_US]:
        var c = _eval_column_expr(Expr.extract(unit, _x()), rb)
        assert_equal(c.null_count(), 1)
        if unit == EXTRACT_EPOCH:
            assert_true(c.as_primitive[DType.float64]().is_null(0))
            assert_false(c.as_primitive[DType.float64]().is_null(1))
        else:
            assert_true(c.as_primitive[DType.int64]().is_null(0))
            assert_false(c.as_primitive[DType.int64]().is_null(1))


def test_the_tick_unit_comes_from_the_schema_of_a_physical_column() raises:
    """A Parquet scan hands back an INT64-stamped column and declares
    TIMESTAMP_MS on the schema field: epoch_us scales by the declared unit
    (TIMESTAMP_MS '2026-09-01 00:00:00.123' = 1788220800123000 us)."""
    var rb = _batch([Int64(1788220800123)], -1, ArrowType.INT64, ArrowType.TIMESTAMP_MS)
    var c = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_US, _x()), rb)
    assert_equal(c.as_primitive[DType.int64]().get(0), Int64(1788220800123000))


def test_timestamp_ns_and_s_columns() raises:
    """TIMESTAMP_NS '1969-12-31 23:59:59.998999999': epoch_ms -1.
    TIMESTAMP_S '1960-01-01': epoch -315619200.0."""
    var ns = _batch([Int64(-1000001)], -1, ArrowType.TIMESTAMP_NS, ArrowType.TIMESTAMP_NS)
    assert_equal(
        _eval_column_expr(Expr.extract(EXTRACT_EPOCH_MS, _x()), ns).as_primitive[DType.int64]().get(0),
        Int64(-1),
    )
    var s = _batch([Int64(-315619200)], -1, ArrowType.TIMESTAMP_S, ArrowType.TIMESTAMP_S)
    assert_equal(
        _eval_column_expr(Expr.extract(EXTRACT_EPOCH, _x()), s).as_primitive[DType.float64]().get(0),
        Float64(-315619200.0),
    )


def test_a_date_column_counts_whole_days() raises:
    """epoch(DATE '2026-09-01') = 1788220800.0, epoch_ms(DATE '1969-12-31') =
    -86400000, epoch_us(DATE '2026-09-01') = 1788220800000000; NULL stays
    NULL."""
    var rb = _date_batch([Int32(20697), Int32(-1), Int32(0)], 2)
    var s = _eval_column_expr(Expr.extract(EXTRACT_EPOCH, _x()), rb)
    assert_equal(Int(s.arrow_type.type_id), Int(ArrowType.FLOAT64.type_id))
    assert_equal(s.as_primitive[DType.float64]().get(0), Float64(1788220800.0))
    assert_true(s.as_primitive[DType.float64]().is_null(2))
    var ms = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_MS, _x()), rb).as_primitive[DType.int64]()
    assert_equal(ms.get(1), Int64(-86400000))
    var us = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_US, _x()), rb).as_primitive[DType.int64]()
    assert_equal(us.get(0), Int64(1788220800000000))
    assert_true(us.is_null(2))


def test_a_non_temporal_operand_is_refused() raises:
    """An INT64 column the schema also calls INT64 is not an instant: the
    evaluator refuses it instead of reading it as some tick unit."""
    var rb = _batch([Int64(5)], -1, ArrowType.INT64, ArrowType.INT64)
    with assert_raises(contains="EXPR_EXTRACT child must be DATE32 or TIMESTAMP_*"):
        _ = _eval_column_expr(Expr.extract(EXTRACT_EPOCH_US, _x()), rb)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
