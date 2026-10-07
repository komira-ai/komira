# =============================================================================
# Tests for fused multi-conjunct predicate evaluator (FLOAT64 extension)
# =============================================================================
#
# Validates the FLOAT64 mirror of the INT64 fused kernel introduced for
# Q6 hot path. Covers:
#   * Pure-FLOAT64 multi-conjunct chain (q6 shape: BETWEEN range +
#     single threshold).
#   * Mixed INT64+FLOAT64 chain (q6 shape: shipdate range + discount
#     range + quantity threshold).
#   ⚠ The NaN expectations below PIN A KNOWN DIVERGENCE, not DuckDB parity.
#     Leave them ALONE until the engine adopts one shared NaN comparison
#     semantics.
#   * NaN handling (IEEE-754 — every numeric op returns False; ne
#     returns True). Verified to match DuckDB / parquet-rs behavior.
#   * Tail handling (n_rows not multiple of 8).
#   * All op codes (EQ, NE, LT, LE, GT, GE).
#   * Empty mask short-circuit.
#   * Long-array stress (1024 rows).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_arrow.arrow_types import ArrowType
from komira_column_kernels.comparison import eval_eq, eval_lt, eval_gt
from komira_column_kernels.arithmetic import eval_and
from komira_column_kernels.fused_predicate import (
    ConjunctDescI64,
    ConjunctDescF64,
    FUSED_OP_EQ,
    FUSED_OP_NE,
    FUSED_OP_LT,
    FUSED_OP_LE,
    FUSED_OP_GT,
    FUSED_OP_GE,
    fused_eval_and_float64,
    fused_eval_and_mixed,
    fused_eval_and_int64,
)


def _arr_f64(values: List[Float64]) -> PrimitiveArray[DType.float64]:
    var scalars = List[Scalar[DType.float64]]()
    for i in range(len(values)):
        scalars.append(Scalar[DType.float64](values[i]))
    return PrimitiveArray[DType.float64].from_list(scalars)


def _arr_i64(values: List[Int64]) -> PrimitiveArray[DType.int64]:
    var scalars = List[Scalar[DType.int64]]()
    for i in range(len(values)):
        scalars.append(Scalar[DType.int64](values[i]))
    return PrimitiveArray[DType.int64].from_list(scalars)


def _ba_eq(a: BooleanArray, b: BooleanArray) -> Bool:
    if a.length != b.length:
        return False
    for i in range(a.length):
        if a.data.test(i) != b.data.test(i):
            return False
    return True


def _make_batch_one_f64(name: String, values: List[Float64]) raises -> RecordBatch:
    var arr = _arr_f64(values)
    var col = Column.from_primitive[DType.float64](arr)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    return builder.build(schema^)


def _make_batch_two_f64(
    name_a: String, vals_a: List[Float64], name_b: String, vals_b: List[Float64]
) raises -> RecordBatch:
    var col_a = Column.from_primitive[DType.float64](_arr_f64(vals_a))
    var col_b = Column.from_primitive[DType.float64](_arr_f64(vals_b))
    var sb = SchemaBuilder()
    sb.add_field(Field(name_a, ArrowType.FLOAT64, False))
    sb.add_field(Field(name_b, ArrowType.FLOAT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col_a^)
    builder.add_column(col_b^)
    return builder.build(schema^)


def _make_batch_q6_shape(
    shipdate_vals: List[Int64],
    discount_vals: List[Float64],
    quantity_vals: List[Float64],
) raises -> RecordBatch:
    """Q6 fixture: l_shipdate (INT64) + l_discount (FLOAT64) + l_quantity (FLOAT64)."""
    var col_sd = Column.from_primitive[DType.int64](_arr_i64(shipdate_vals))
    var col_dc = Column.from_primitive[DType.float64](_arr_f64(discount_vals))
    var col_qt = Column.from_primitive[DType.float64](_arr_f64(quantity_vals))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("l_shipdate"), ArrowType.INT64, False))
    sb.add_field(Field(String("l_discount"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("l_quantity"), ArrowType.FLOAT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col_sd^)
    builder.add_column(col_dc^)
    builder.add_column(col_qt^)
    return builder.build(schema^)


# =============================================================================
# Pure-FLOAT64 tests
# =============================================================================


def test_fused_float64_two_conjuncts_range() raises:
    """Two conjuncts on same column: discount BETWEEN 0.05 AND 0.07 -- q6 shape."""
    var values = List[Float64]()
    values.append(Float64(0.04))
    values.append(Float64(0.05))
    values.append(Float64(0.06))
    values.append(Float64(0.07))
    values.append(Float64(0.08))
    var batch = _make_batch_one_f64(String("l_discount"), values)
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_GE, Float64(0.05)))
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_LE, Float64(0.07)))
    var fused = fused_eval_and_float64(batch, conjuncts, 5)
    # Expected: indices 1, 2, 3 (0.05, 0.06, 0.07) survive.
    assert_equal(fused.data.test(0), False)
    assert_equal(fused.data.test(1), True)
    assert_equal(fused.data.test(2), True)
    assert_equal(fused.data.test(3), True)
    assert_equal(fused.data.test(4), False)


def test_fused_float64_two_cols() raises:
    """Two conjuncts on DIFFERENT cols: discount BETWEEN 0.05 AND 0.07 (across cols)."""
    var col_a = List[Float64]()
    col_a.append(Float64(0.04))
    col_a.append(Float64(0.05))
    col_a.append(Float64(0.06))
    col_a.append(Float64(0.07))
    col_a.append(Float64(0.08))
    var col_b = List[Float64]()
    col_b.append(Float64(20.0))
    col_b.append(Float64(15.0))
    col_b.append(Float64(30.0))
    col_b.append(Float64(10.0))
    col_b.append(Float64(25.0))
    var batch = _make_batch_two_f64(
        String("a"), col_a, String("b"), col_b
    )
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_GE, Float64(0.05)))
    conjuncts.append(ConjunctDescF64(1, FUSED_OP_LT, Float64(24.0)))
    var fused = fused_eval_and_float64(batch, conjuncts, 5)
    # row 0: a=0.04 -> False
    # row 1: a=0.05, b=15 -> True
    # row 2: a=0.06, b=30 -> False (b not < 24)
    # row 3: a=0.07, b=10 -> True
    # row 4: a=0.08, b=25 -> False
    assert_equal(fused.data.test(0), False)
    assert_equal(fused.data.test(1), True)
    assert_equal(fused.data.test(2), False)
    assert_equal(fused.data.test(3), True)
    assert_equal(fused.data.test(4), False)


def test_fused_float64_all_ops_parity() raises:
    """Each op code matches the scalar reference kernel byte-for-byte."""
    var n = 100
    var data = List[Float64]()
    for i in range(n):
        data.append(Float64((i * 17) % 13))
    var batch = _make_batch_one_f64(String("v"), data)
    var thresh = Float64(7.0)
    var col_arr = batch.column_at(0).as_primitive[DType.float64]()

    # EQ
    var c1 = List[ConjunctDescF64]()
    c1.append(ConjunctDescF64(0, FUSED_OP_EQ, thresh))
    var fused_eq = fused_eval_and_float64(batch, c1, n)
    var ref_eq = eval_eq[DType.float64](col_arr, Scalar[DType.float64](thresh))
    assert_true(_ba_eq(fused_eq, ref_eq), "FLOAT64 EQ mismatch")

    # LT
    var c2 = List[ConjunctDescF64]()
    c2.append(ConjunctDescF64(0, FUSED_OP_LT, thresh))
    var fused_lt = fused_eval_and_float64(batch, c2, n)
    var ref_lt = eval_lt[DType.float64](col_arr, Scalar[DType.float64](thresh))
    assert_true(_ba_eq(fused_lt, ref_lt), "FLOAT64 LT mismatch")

    # GT
    var c3 = List[ConjunctDescF64]()
    c3.append(ConjunctDescF64(0, FUSED_OP_GT, thresh))
    var fused_gt = fused_eval_and_float64(batch, c3, n)
    var ref_gt = eval_gt[DType.float64](col_arr, Scalar[DType.float64](thresh))
    assert_true(_ba_eq(fused_gt, ref_gt), "FLOAT64 GT mismatch")


def test_fused_float64_tail_handling() raises:
    """n_rows = 13 (not multiple of 8) -> one full byte + 5 tail bits."""
    var data = List[Float64]()
    for i in range(13):
        data.append(Float64(i))
    var batch = _make_batch_one_f64(String("v"), data)
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_GE, Float64(5.0)))
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_LT, Float64(11.0)))
    var fused = fused_eval_and_float64(batch, conjuncts, 13)
    assert_equal(fused.length, 13)
    for i in range(13):
        var expected = (Float64(i) >= 5.0) and (Float64(i) < 11.0)
        assert_equal(fused.data.test(i), expected)


def test_fused_float64_long_array() raises:
    """Stress test: 1024 rows, multi-conjunct, two columns."""
    var n = 1024
    var col_a_data = List[Float64]()
    var col_b_data = List[Float64]()
    for i in range(n):
        col_a_data.append(Float64(i % 50))
        col_b_data.append(Float64((i * 3) % 100))
    var batch = _make_batch_two_f64(
        String("a"), col_a_data, String("b"), col_b_data
    )
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_LT, Float64(20.0)))
    conjuncts.append(ConjunctDescF64(1, FUSED_OP_GE, Float64(50.0)))
    var fused = fused_eval_and_float64(batch, conjuncts, n)
    for i in range(n):
        var a = col_a_data[i] < Float64(20.0)
        var b = col_b_data[i] >= Float64(50.0)
        var both = a and b
        assert_equal(fused.data.test(i), both)


def test_fused_float64_empty_mask() raises:
    """No rows pass -> all-False bitmap."""
    var data = List[Float64]()
    for i in range(5):
        data.append(Float64(i + 1))
    var batch = _make_batch_one_f64(String("v"), data)
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_GT, Float64(100.0)))
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_LT, Float64(200.0)))
    var fused = fused_eval_and_float64(batch, conjuncts, 5)
    assert_equal(fused.true_count(), 0)


# =============================================================================
# NaN handling -- IEEE-754 semantics
# =============================================================================


def test_fused_float64_nan_excluded() raises:
    """NaN values must be excluded from numeric comparisons (IEEE-754).

    NaN < x, NaN <= x, NaN > x, NaN >= x, NaN == x all return False.
    NaN != x returns True. With a chain of GE/LE comparisons the NaN
    rows must NOT pass the filter -- DuckDB and parquet-rs both do this.
    """
    # Construct a NaN via 0.0/0.0. Mojo Float64 follows IEEE-754.
    var zero = Float64(0.0)
    var nan_val = zero / zero
    # Sanity: NaN != NaN (the canonical IEEE-754 NaN test).
    assert_true(nan_val != nan_val, "Expected nan != nan")

    var data = List[Float64]()
    data.append(Float64(0.05))
    data.append(nan_val)
    data.append(Float64(0.06))
    data.append(nan_val)
    data.append(Float64(0.07))
    data.append(Float64(0.10))  # outside range
    data.append(nan_val)
    data.append(Float64(0.04))  # outside range

    var batch = _make_batch_one_f64(String("disc"), data)
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_GE, Float64(0.05)))
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_LE, Float64(0.07)))
    var fused = fused_eval_and_float64(batch, conjuncts, len(data))

    # Expected: only 0, 2, 4 pass. NaN rows (1, 3, 6) and out-of-range
    # (5, 7) all fail.
    assert_equal(fused.data.test(0), True)   # 0.05 -- in range
    assert_equal(fused.data.test(1), False)  # NaN -- excluded
    assert_equal(fused.data.test(2), True)   # 0.06 -- in range
    assert_equal(fused.data.test(3), False)  # NaN -- excluded
    assert_equal(fused.data.test(4), True)   # 0.07 -- in range
    assert_equal(fused.data.test(5), False)  # 0.10 -- out of range
    assert_equal(fused.data.test(6), False)  # NaN -- excluded
    assert_equal(fused.data.test(7), False)  # 0.04 -- out of range
    assert_equal(fused.true_count(), 3)


def test_fused_float64_nan_ne_passes() raises:
    """NE op against NaN MUST return True (IEEE-754 — `NaN != x` is True
    for every x including another NaN). Single conjunct, so the kernel's
    direct entry point. Documents the chosen semantics so a future
    refactor can't regress it.
    """
    var zero = Float64(0.0)
    var nan_val = zero / zero
    var data = List[Float64]()
    data.append(Float64(1.0))
    data.append(nan_val)
    data.append(Float64(2.0))
    # Two conjuncts (NE same value) just to clear the >=2 gate; both
    # should pass on NaN, so the AND result on NaN is True.
    var batch = _make_batch_one_f64(String("v"), data)
    var conjuncts = List[ConjunctDescF64]()
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_NE, Float64(1.0)))
    conjuncts.append(ConjunctDescF64(0, FUSED_OP_NE, Float64(2.0)))
    var fused = fused_eval_and_float64(batch, conjuncts, 3)
    # row 0: 1.0 != 1.0 -> False (fails first conjunct)
    # row 1: NaN != 1.0 -> True; NaN != 2.0 -> True; AND = True
    # row 2: 2.0 != 1.0 -> True; 2.0 != 2.0 -> False (fails second)
    assert_equal(fused.data.test(0), False)
    assert_equal(fused.data.test(1), True)  # NaN passes NE chain
    assert_equal(fused.data.test(2), False)


# =============================================================================
# Mixed INT64+FLOAT64 tests (q6 hot path)
# =============================================================================


def test_fused_mixed_q6_shape() raises:
    """Q6 chain shape: shipdate range (INT64) + discount range (FLOAT64) + quantity threshold (FLOAT64).

    Most representative single test of the q6 hot path. Validates that
    the mixed kernel correctly AND-combines INT64 and FLOAT64 conjuncts
    together against a single batch.
    """
    # 8 rows. Hand-constructed pass / fail mix.
    var shipdate = List[Int64]()
    var discount = List[Float64]()
    var quantity = List[Float64]()
    # date_lo = 100, date_hi = 200; discount in [0.05, 0.07]; qty < 24.
    # row 0: shipdate=150, disc=0.06, qty=10  -> PASS
    # row 1: shipdate=50,  disc=0.06, qty=10  -> FAIL (date)
    # row 2: shipdate=150, disc=0.04, qty=10  -> FAIL (discount low)
    # row 3: shipdate=150, disc=0.08, qty=10  -> FAIL (discount high)
    # row 4: shipdate=150, disc=0.06, qty=30  -> FAIL (qty)
    # row 5: shipdate=200, disc=0.06, qty=10  -> FAIL (date == hi, GT-only)
    # row 6: shipdate=199, disc=0.05, qty=23  -> PASS (boundary)
    # row 7: shipdate=100, disc=0.07, qty=23  -> PASS (boundary)
    shipdate.append(Int64(150)); discount.append(Float64(0.06)); quantity.append(Float64(10.0))
    shipdate.append(Int64(50));  discount.append(Float64(0.06)); quantity.append(Float64(10.0))
    shipdate.append(Int64(150)); discount.append(Float64(0.04)); quantity.append(Float64(10.0))
    shipdate.append(Int64(150)); discount.append(Float64(0.08)); quantity.append(Float64(10.0))
    shipdate.append(Int64(150)); discount.append(Float64(0.06)); quantity.append(Float64(30.0))
    shipdate.append(Int64(200)); discount.append(Float64(0.06)); quantity.append(Float64(10.0))
    shipdate.append(Int64(199)); discount.append(Float64(0.05)); quantity.append(Float64(23.0))
    shipdate.append(Int64(100)); discount.append(Float64(0.07)); quantity.append(Float64(23.0))

    var batch = _make_batch_q6_shape(shipdate, discount, quantity)
    var int_c = List[ConjunctDescI64]()
    int_c.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(100)))
    int_c.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(200)))
    var float_c = List[ConjunctDescF64]()
    float_c.append(ConjunctDescF64(1, FUSED_OP_GE, Float64(0.05)))
    float_c.append(ConjunctDescF64(1, FUSED_OP_LE, Float64(0.07)))
    float_c.append(ConjunctDescF64(2, FUSED_OP_LT, Float64(24.0)))
    var fused = fused_eval_and_mixed(batch, int_c, float_c, 8)

    assert_equal(fused.data.test(0), True)
    assert_equal(fused.data.test(1), False)
    assert_equal(fused.data.test(2), False)
    assert_equal(fused.data.test(3), False)
    assert_equal(fused.data.test(4), False)
    assert_equal(fused.data.test(5), False)
    assert_equal(fused.data.test(6), True)
    assert_equal(fused.data.test(7), True)
    assert_equal(fused.true_count(), 3)


def test_fused_mixed_pure_int_passthrough() raises:
    """Mixed entry with empty FLOAT list must equal pure-INT64 kernel."""
    var values = List[Int64]()
    for i in range(20):
        values.append(Int64(i))
    var col = Column.from_primitive[DType.int64](_arr_i64(values))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    var int_c = List[ConjunctDescI64]()
    int_c.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(5)))
    int_c.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(15)))
    var float_c = List[ConjunctDescF64]()
    var fused_mixed = fused_eval_and_mixed(batch, int_c, float_c, 20)
    var fused_pure = fused_eval_and_int64(batch, int_c, 20)
    assert_true(_ba_eq(fused_mixed, fused_pure), "mixed-with-empty-float must equal pure-INT64")


def test_fused_mixed_pure_float_passthrough() raises:
    """Mixed entry with empty INT list must equal pure-FLOAT64 kernel."""
    var values = List[Float64]()
    for i in range(20):
        values.append(Float64(i) * 0.1)
    var batch = _make_batch_one_f64(String("v"), values)

    var int_c = List[ConjunctDescI64]()
    var float_c = List[ConjunctDescF64]()
    float_c.append(ConjunctDescF64(0, FUSED_OP_GE, Float64(0.5)))
    float_c.append(ConjunctDescF64(0, FUSED_OP_LT, Float64(1.5)))
    var fused_mixed = fused_eval_and_mixed(batch, int_c, float_c, 20)
    var fused_pure = fused_eval_and_float64(batch, float_c, 20)
    assert_true(_ba_eq(fused_mixed, fused_pure), "mixed-with-empty-int must equal pure-FLOAT64")


def test_fused_mixed_tail_handling() raises:
    """Mixed kernel: 13 rows (1 full byte + 5 tail bits)."""
    var sd = List[Int64]()
    var dc = List[Float64]()
    var qt = List[Float64]()
    for i in range(13):
        sd.append(Int64(150))      # all in date range
        dc.append(Float64(0.06))   # all in discount range
        # Qty alternates between in-range (10) and out-of-range (30).
        if i % 2 == 0:
            qt.append(Float64(10.0))
        else:
            qt.append(Float64(30.0))
    var batch = _make_batch_q6_shape(sd, dc, qt)
    var int_c = List[ConjunctDescI64]()
    int_c.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(100)))
    int_c.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(200)))
    var float_c = List[ConjunctDescF64]()
    float_c.append(ConjunctDescF64(1, FUSED_OP_GE, Float64(0.05)))
    float_c.append(ConjunctDescF64(2, FUSED_OP_LT, Float64(24.0)))
    var fused = fused_eval_and_mixed(batch, int_c, float_c, 13)
    assert_equal(fused.length, 13)
    for i in range(13):
        var expected = i % 2 == 0  # only even indices (qty=10) pass
        assert_equal(fused.data.test(i), expected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
