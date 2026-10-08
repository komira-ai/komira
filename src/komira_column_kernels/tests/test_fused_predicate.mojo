# komira_column_kernels/tests/test_fused_predicate.mojo -- the fused
# multi-conjunct evaluators of `fused_predicate.mojo` (INT64, FLOAT64 and
# mixed), against masks written out by hand.
#
# The fixtures are 21 rows: two full output bytes (the SIMD compare-pack) and
# a 5-row tail (the scalar loop), so every op is checked on both paths. The
# INT64 column's first byte holds 0..7 and its second 15,14,13,12,3,2,1,0, so
# a predicate can be zero on one full byte and not the other. The FLOAT64
# column holds NaN, both infinities, both zeros and values on either side of
# the threshold 2.5. Each expected mask is written element 0 first, one
# character per row, a space between output bytes.
#
# NaN follows IEEE-754, as the module header states: every ordered compare
# with NaN is false. NE with a NaN operand is NOT pinned here: the module
# says it is true, the scalar tail answers true, and the SIMD full-byte path
# answers false (SIMD `.ne` is LLVM's ordered `fcmp one`), so the answer for a
# NaN row depends on its position. NE is checked on a column without NaN.

from std.math import inf
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_column_kernels.fused_predicate import (
    ConjunctDescF64,
    ConjunctDescI64,
    FUSED_OP_EQ,
    FUSED_OP_GE,
    FUSED_OP_GT,
    FUSED_OP_LE,
    FUSED_OP_LT,
    FUSED_OP_NE,
    fused_eval_and_float64,
    fused_eval_and_int64,
    fused_eval_and_mixed,
    fused_op_from_bin_op,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _ints() -> List[Int64]:
    var xs: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7, 15, 14, 13, 12, 3, 2, 1, 0, 3, 2, 3, 4, 1]
    var v = List[Int64]()
    for i in range(len(xs)):
        v.append(Int64(xs[i]))
    return v^


def _nan() -> Float64:
    var zero = Float64(0.0)
    return zero / zero


def _floats(nan_rows: Bool = True) -> List[Float64]:
    # nan_rows=False puts 9.0 where the NaN rows are.
    var nan = _nan() if nan_rows else Float64(9.0)
    var pinf = inf[DType.float64]()
    var v = List[Float64]()
    # byte 0
    v.append(0.5)
    v.append(1.5)
    v.append(2.5)
    v.append(nan)
    v.append(3.5)
    v.append(-pinf)
    v.append(pinf)
    v.append(2.5)
    # byte 1
    v.append(2.5)
    v.append(nan)
    v.append(0.0)
    v.append(-0.0)
    v.append(4.0)
    v.append(2.5)
    v.append(1.0)
    v.append(3.0)
    # tail
    v.append(nan)
    v.append(2.5)
    v.append(2.4999)
    v.append(2.5001)
    v.append(pinf)
    return v^


def _batch(ints: List[Int64], floats: List[Float64]) raises -> RecordBatch:
    """Column 0 INT64, column 1 FLOAT64, column 2 INT64 (`ints` again)."""
    var si = List[Scalar[DType.int64]]()
    for i in range(len(ints)):
        si.append(Scalar[DType.int64](ints[i]))
    var sf = List[Scalar[DType.float64]]()
    for i in range(len(floats)):
        sf.append(Scalar[DType.float64](floats[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(si)))
    builder.add_column(
        Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(sf))
    )
    builder.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(si)))
    return builder.build(schema^)


def _fixture() raises -> RecordBatch:
    return _batch(_ints(), _floats())


def _fixture_without_nan() raises -> RecordBatch:
    return _batch(_ints(), _floats(nan_rows=False))


def _mask(ba: BooleanArray) -> String:
    var out = String()
    for i in range(ba.length):
        if i > 0 and i % 8 == 0:
            out += " "
        out += "1" if ba.data.test(i) else "0"
    return out


def _i(col: Int, op: UInt8, t: Int) -> List[ConjunctDescI64]:
    var v = List[ConjunctDescI64]()
    v.append(ConjunctDescI64(col, op, Int64(t)))
    return v^


def _f(op: UInt8, t: Float64) -> List[ConjunctDescF64]:
    var v = List[ConjunctDescF64]()
    v.append(ConjunctDescF64(1, op, t))
    return v^


# -----------------------------------------------------------------------------
# INT64
# -----------------------------------------------------------------------------


def _int_cases() -> List[Tuple[UInt8, String]]:
    # Column a against 3.
    var v = List[Tuple[UInt8, String]]()
    v.append((FUSED_OP_EQ, String("00010000 00001000 10100")))
    v.append((FUSED_OP_NE, String("11101111 11110111 01011")))
    v.append((FUSED_OP_LT, String("11100000 00000111 01001")))
    v.append((FUSED_OP_LE, String("11110000 00001111 11101")))
    v.append((FUSED_OP_GT, String("00001111 11110000 00010")))
    v.append((FUSED_OP_GE, String("00011111 11111000 10110")))
    return v^


def test_int64_every_op_full_bytes_and_tail() raises:
    var batch = _fixture()
    var cases = _int_cases()
    for k in range(len(cases)):
        var got = fused_eval_and_int64(batch, _i(0, cases[k][0], 3), 21)
        assert_equal(got.length, 21)
        assert_equal(_mask(got), cases[k][1], String("int op ") + String(cases[k][0]))


def test_int64_conjuncts_are_and_combined() raises:
    var batch = _fixture()
    # 3 <= a <= 4: the second conjunct runs on bytes the first left non-zero.
    var c = _i(0, FUSED_OP_GE, 3)
    c.append(ConjunctDescI64(0, FUSED_OP_LE, Int64(4)))
    assert_equal(_mask(fused_eval_and_int64(batch, c, 21)), "00011000 00001000 10110")
    # a >= 12 is zero on the first byte; with a second conjunct after it.
    var d = _i(0, FUSED_OP_GE, 12)
    d.append(ConjunctDescI64(0, FUSED_OP_NE, Int64(13)))
    assert_equal(_mask(fused_eval_and_int64(batch, d, 21)), "00000000 11010000 00000")
    # The first conjunct rejects every row; the tail's first failure decides.
    var e = _i(0, FUSED_OP_EQ, 100)
    e.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(0)))
    assert_equal(_mask(fused_eval_and_int64(batch, e, 21)), "00000000 00000000 00000")
    # A conjunct that passes everywhere leaves the other one's mask.
    var g = _i(0, FUSED_OP_GE, 0)
    g.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(3)))
    assert_equal(_mask(fused_eval_and_int64(batch, g, 21)), "11100000 00000111 01001")


def test_int64_reads_the_column_each_conjunct_names() raises:
    # Column 2 holds a's values: a conjunct on it gives a's mask, and one on
    # column 2 with one on column 0 gives their AND.
    var batch = _fixture()
    assert_equal(
        _mask(fused_eval_and_int64(batch, _i(2, FUSED_OP_GT, 3), 21)),
        "00001111 11110000 00010",
    )
    var c = _i(2, FUSED_OP_GT, 2)
    c.append(ConjunctDescI64(0, FUSED_OP_LT, Int64(5)))
    assert_equal(_mask(fused_eval_and_int64(batch, c, 21)), "00011000 00001000 10110")


def test_int64_row_counts() raises:
    var batch = _fixture()
    # n_rows, not the column length, sets the output: a whole number of bytes
    # (no tail), a tail cut from inside a full byte of the column, a tail only,
    # and no rows at all.
    var cases = List[Tuple[Int, String]]()
    cases.append((16, String("00011111 11111000")))
    cases.append((13, String("00011111 11111")))
    cases.append((5, String("00011")))
    cases.append((8, String("00011111")))
    cases.append((0, String("")))
    for k in range(len(cases)):
        var n = cases[k][0]
        var got = fused_eval_and_int64(batch, _i(0, FUSED_OP_GE, 3), n)
        assert_equal(got.length, n)
        assert_equal(_mask(got), cases[k][1], String("n_rows ") + String(n))


def test_int64_signed_extremes() raises:
    var vals = List[Int64]()
    vals.append(Int64.MIN)
    vals.append(Int64(-1))
    vals.append(Int64(0))
    vals.append(Int64(1))
    vals.append(Int64.MAX)
    vals.append(Int64.MIN)
    vals.append(Int64.MAX)
    vals.append(Int64(0))
    vals.append(Int64.MIN)
    vals.append(Int64.MAX)
    var fl = List[Float64]()
    for _ in range(10):
        fl.append(0.0)
    var batch = _batch(vals, fl)
    var c = List[ConjunctDescI64]()
    c.append(ConjunctDescI64(0, FUSED_OP_GT, Int64(-1)))
    assert_equal(_mask(fused_eval_and_int64(batch, c, 10)), "00111011 01")
    var d = List[ConjunctDescI64]()
    d.append(ConjunctDescI64(0, FUSED_OP_LE, Int64.MIN))
    assert_equal(_mask(fused_eval_and_int64(batch, d, 10)), "10000100 10")
    var e = List[ConjunctDescI64]()
    e.append(ConjunctDescI64(0, FUSED_OP_GE, Int64.MAX))
    assert_equal(_mask(fused_eval_and_int64(batch, e, 10)), "00001010 01")


# -----------------------------------------------------------------------------
# FLOAT64
# -----------------------------------------------------------------------------


def _float_cases() -> List[Tuple[UInt8, String]]:
    # Column f against 2.5. Rows 3, 9 and 16 are NaN.
    var v = List[Tuple[UInt8, String]]()
    v.append((FUSED_OP_EQ, String("00100001 10000100 01000")))
    v.append((FUSED_OP_LT, String("11000100 00110010 00100")))
    v.append((FUSED_OP_LE, String("11100101 10110110 01100")))
    v.append((FUSED_OP_GT, String("00001010 00001001 00011")))
    v.append((FUSED_OP_GE, String("00101011 10001101 01011")))
    return v^


def test_float64_every_op_full_bytes_and_tail() raises:
    var batch = _fixture()
    var cases = _float_cases()
    for k in range(len(cases)):
        var got = fused_eval_and_float64(batch, _f(cases[k][0], 2.5), 21)
        assert_equal(got.length, 21)
        assert_equal(_mask(got), cases[k][1], String("float op ") + String(cases[k][0]))


def test_float64_ne_without_nan() raises:
    # f != 2.5 on the column whose NaN rows hold 9.0; on full bytes and tail,
    # through the float kernel and through the mixed one with no int conjunct.
    var batch = _fixture_without_nan()
    var want = "11011110 01111011 10111"
    assert_equal(_mask(fused_eval_and_float64(batch, _f(FUSED_OP_NE, 2.5), 21)), want)
    var no_i = List[ConjunctDescI64]()
    assert_equal(_mask(fused_eval_and_mixed(batch, no_i, _f(FUSED_OP_NE, 2.5), 21)), want)
    # a >= 12 and f != 2.5: byte 0 is zero after the int conjunct.
    assert_equal(
        _mask(fused_eval_and_mixed(batch, _i(0, FUSED_OP_GE, 12), _f(FUSED_OP_NE, 2.5), 21)),
        "00000000 01110000 00000",
    )


def test_float64_zero_signs_and_conjunctions() raises:
    var batch = _fixture()
    # -0.0 == 0.0 under IEEE-754: rows 10 and 11 both match.
    assert_equal(
        _mask(fused_eval_and_float64(batch, _f(FUSED_OP_EQ, 0.0), 21)),
        "00000000 00110000 00000",
    )
    # 2.5 < f <= +inf: +inf itself passes LE +inf; NaN fails both.
    var c = _f(FUSED_OP_GT, 2.5)
    c.append(ConjunctDescF64(1, FUSED_OP_LE, inf[DType.float64]()))
    assert_equal(_mask(fused_eval_and_float64(batch, c, 21)), "00001010 00001001 00011")
    # f != 2.5 and f < 2.5: NE lets the NaN rows through, LT then drops them.
    var d = _f(FUSED_OP_NE, 2.5)
    d.append(ConjunctDescF64(1, FUSED_OP_LT, 2.5))
    assert_equal(_mask(fused_eval_and_float64(batch, d, 21)), "11000100 00110010 00100")
    # The first conjunct rejects every row.
    var e = _f(FUSED_OP_EQ, 99.0)
    e.append(ConjunctDescF64(1, FUSED_OP_NE, 2.5))
    assert_equal(_mask(fused_eval_and_float64(batch, e, 21)), "00000000 00000000 00000")
    # Whole bytes only.
    var got = fused_eval_and_float64(batch, _f(FUSED_OP_GE, 2.5), 16)
    assert_equal(got.length, 16)
    assert_equal(_mask(got), "00101011 10001101")


# -----------------------------------------------------------------------------
# Mixed
# -----------------------------------------------------------------------------


def test_mixed_one_int_one_float() raises:
    var batch = _fixture()
    # a >= 3 and f < 2.5. Tail: row 16 passes a and fails f (NaN), row 17
    # fails a, row 18 passes both.
    assert_equal(
        _mask(fused_eval_and_mixed(batch, _i(0, FUSED_OP_GE, 3), _f(FUSED_OP_LT, 2.5), 21)),
        "00000100 00110000 00100",
    )
    # a < 3 and f > 2.5: the float conjunct zeroes byte 0 the int one left set.
    assert_equal(
        _mask(fused_eval_and_mixed(batch, _i(0, FUSED_OP_LT, 3), _f(FUSED_OP_GT, 2.5), 21)),
        "00000000 00000001 00001",
    )
    # a >= 12 and f >= 1.0: byte 0 is zero after the int conjunct, so the
    # float conjunct is not needed there.
    assert_equal(
        _mask(fused_eval_and_mixed(batch, _i(0, FUSED_OP_GE, 12), _f(FUSED_OP_GE, 1.0), 21)),
        "00000000 10000000 00000",
    )


def test_mixed_several_of_each() raises:
    var batch = _fixture()
    # 3 <= a <= 4 and f > 2.5.
    var ic = _i(0, FUSED_OP_GE, 3)
    ic.append(ConjunctDescI64(0, FUSED_OP_LE, Int64(4)))
    assert_equal(
        _mask(fused_eval_and_mixed(batch, ic, _f(FUSED_OP_GT, 2.5), 21)),
        "00001000 00001000 00010",
    )
    # The first int conjunct rejects every row.
    var iz = _i(0, FUSED_OP_EQ, 100)
    iz.append(ConjunctDescI64(0, FUSED_OP_GE, Int64(0)))
    assert_equal(
        _mask(fused_eval_and_mixed(batch, iz, _f(FUSED_OP_NE, 2.5), 21)),
        "00000000 00000000 00000",
    )
    # Every row passes the int conjunct; the first float conjunct rejects all.
    var fz = _f(FUSED_OP_EQ, 99.0)
    fz.append(ConjunctDescF64(1, FUSED_OP_NE, 2.5))
    assert_equal(
        _mask(fused_eval_and_mixed(batch, _i(0, FUSED_OP_GE, 0), fz, 21)),
        "00000000 00000000 00000",
    )
    # Two floats that both apply: f != 2.5 and f >= 1.0 (NaN passes NE, fails GE).
    var ff = _f(FUSED_OP_NE, 2.5)
    ff.append(ConjunctDescF64(1, FUSED_OP_GE, 1.0))
    assert_equal(
        _mask(fused_eval_and_mixed(batch, _i(0, FUSED_OP_GE, 0), ff, 21)),
        "01001010 00001011 00111",
    )
    # Whole bytes only.
    var got = fused_eval_and_mixed(batch, _i(0, FUSED_OP_GE, 3), _f(FUSED_OP_LT, 2.5), 16)
    assert_equal(got.length, 16)
    assert_equal(_mask(got), "00000100 00110000")


def test_mixed_with_one_list_empty_is_the_single_type_kernel() raises:
    var batch = _fixture()
    var no_f = List[ConjunctDescF64]()
    var no_i = List[ConjunctDescI64]()
    var ints = _int_cases()
    for k in range(len(ints)):
        assert_equal(
            _mask(fused_eval_and_mixed(batch, _i(0, ints[k][0], 3), no_f, 21)),
            ints[k][1],
            String("int-only op ") + String(ints[k][0]),
        )
    var floats = _float_cases()
    for k in range(len(floats)):
        assert_equal(
            _mask(fused_eval_and_mixed(batch, no_i, _f(floats[k][0], 2.5), 21)),
            floats[k][1],
            String("float-only op ") + String(floats[k][0]),
        )


# -----------------------------------------------------------------------------
# Op translation and descriptors
# -----------------------------------------------------------------------------


def test_op_from_bin_op() raises:
    # komira_plan_expr's BIN_EQ..BIN_GE are 10..15; anything else is -1.
    var cases = List[Tuple[Int, Int]]()
    cases.append((10, Int(FUSED_OP_EQ)))
    cases.append((11, Int(FUSED_OP_NE)))
    cases.append((12, Int(FUSED_OP_LT)))
    cases.append((13, Int(FUSED_OP_LE)))
    cases.append((14, Int(FUSED_OP_GT)))
    cases.append((15, Int(FUSED_OP_GE)))
    cases.append((9, -1))
    cases.append((16, -1))
    cases.append((0, -1))
    cases.append((255, -1))
    for k in range(len(cases)):
        assert_equal(
            fused_op_from_bin_op(UInt8(cases[k][0])), cases[k][1], String("bin op ") + String(cases[k][0])
        )
    # The six fused codes are 0..5 in this order.
    var codes = List[UInt8]()
    codes.append(FUSED_OP_EQ)
    codes.append(FUSED_OP_NE)
    codes.append(FUSED_OP_LT)
    codes.append(FUSED_OP_LE)
    codes.append(FUSED_OP_GT)
    codes.append(FUSED_OP_GE)
    for k in range(len(codes)):
        assert_equal(Int(codes[k]), k)


def test_descriptor_copy_keeps_every_field() raises:
    var i = _i(4, FUSED_OP_LE, -7)
    i.append(ConjunctDescI64(1, FUSED_OP_NE, Int64.MAX))
    for k in range(len(i)):
        var c = i[k].copy()
        assert_equal(c.col_idx, i[k].col_idx)
        assert_equal(c.op, i[k].op)
        assert_equal(c.thresh, i[k].thresh)
    assert_equal(i[0].copy().thresh, Int64(-7))
    var f = _f(FUSED_OP_GT, -1.25)
    for k in range(len(f)):
        var c = f[k].copy()
        assert_equal(c.col_idx, 1)
        assert_equal(c.op, FUSED_OP_GT)
        assert_equal(c.thresh, f[k].thresh)
        assert_equal(c.thresh, Float64(-1.25))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
