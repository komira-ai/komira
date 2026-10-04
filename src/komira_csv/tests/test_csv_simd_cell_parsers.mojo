# =============================================================================
# Tests for SIMD cell parsers.
# =============================================================================
#
#
# Goal: verify the SIMD fast-path parsers (cell_parsers_simd.mojo) produce
# byte-identical results to the scalar baseline parsers (cell_parsers.mojo)
# on every applicable input AND correctly reject inapplicable inputs.
#
# Test taxonomy:
#   T1  fast_parse_uint_8digit accepts exactly 8 ASCII digits.
#   T2  fast_parse_uint_8digit rejects wrong-length cells.
#   T3  fast_parse_uint_8digit rejects non-digit bytes (sign, decimal, letter).
#   T4  fast_parse_uint_n_digits handles n in [1, 16] with parity vs scalar.
#   T5  fast_parse_int64_simple accepts optional sign + digits.
#   T6  fast_parse_int64_simple rejects empty / sign-only / >17 byte cells.
#   T7  fast_parse_int64_simple equivalence with _try_parse_int64 (random-ish
#       inputs across positive/negative/zero/single-digit/13-digit).
#   T8  fast_parse_float64_simple integer-shape only; rejects decimals/exp.
#   T9  fast_parse_float64_simple equivalence with _try_parse_float64
#       on integer-shaped inputs.
#   T10 cell_is_simple_numeric applicability gate semantics.
#   T11 Lemire 8-digit boundary values: 00000000, 99999999, 12345678.
#   T12 fast_parse_uint_n_digits n=9..16 matches scalar UInt64.
#   T13 fast_parse_int64_simple Int64-near-overflow handling (17 digits
#       rejected; 16 digits accepted).
#   T14 cell_is_simple_numeric rejects 17+ byte cells, quoted cells,
#       cells with letters or whitespace.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv.cell_parsers import (
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_uint64,
)
from komira_csv.cell_parsers_simd import (
    fast_parse_uint_8digit,
    fast_parse_uint_n_digits,
    fast_parse_int64_simple,
    fast_parse_float64_simple,
    cell_is_simple_numeric,
)


# =============================================================================
# Helpers.
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] fixture."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


# =============================================================================
# T1: fast_parse_uint_8digit accepts exactly 8 ASCII digits.
# =============================================================================


def test_t1_uint_8digit_accepts_8_ascii_digits() raises:
    var b1 = _bytes("12345678")
    var v1 = fast_parse_uint_8digit(Span(b1))
    assert_true(v1, "T1: 12345678 should parse")
    assert_equal(Int(v1.value()), 12345678)

    var b2 = _bytes("00000000")
    var v2 = fast_parse_uint_8digit(Span(b2))
    assert_true(v2, "T1: 00000000 should parse")
    assert_equal(Int(v2.value()), 0)

    var b3 = _bytes("99999999")
    var v3 = fast_parse_uint_8digit(Span(b3))
    assert_true(v3, "T1: 99999999 should parse")
    assert_equal(Int(v3.value()), 99999999)


# =============================================================================
# T2: fast_parse_uint_8digit rejects wrong-length cells.
# =============================================================================


def test_t2_uint_8digit_rejects_wrong_length() raises:
    var b_short = _bytes("1234567")
    var v_short = fast_parse_uint_8digit(Span(b_short))
    assert_false(v_short, "T2: 7-byte cell should reject")

    var b_long = _bytes("123456789")
    var v_long = fast_parse_uint_8digit(Span(b_long))
    assert_false(v_long, "T2: 9-byte cell should reject")

    var b_empty = _bytes("")
    var v_empty = fast_parse_uint_8digit(Span(b_empty))
    assert_false(v_empty, "T2: empty cell should reject")


# =============================================================================
# T3: fast_parse_uint_8digit rejects non-digit bytes.
# =============================================================================


def test_t3_uint_8digit_rejects_non_digits() raises:
    var b_sign = _bytes("-1234567")
    assert_false(fast_parse_uint_8digit(Span(b_sign)), "T3: leading - rejected")

    var b_plus = _bytes("+1234567")
    assert_false(fast_parse_uint_8digit(Span(b_plus)), "T3: leading + rejected")

    var b_dot = _bytes("12345.78")
    assert_false(fast_parse_uint_8digit(Span(b_dot)), "T3: decimal rejected")

    var b_letter = _bytes("1234567A")
    assert_false(fast_parse_uint_8digit(Span(b_letter)), "T3: letter rejected")

    var b_space = _bytes("12345 78")
    assert_false(fast_parse_uint_8digit(Span(b_space)), "T3: space rejected")


# =============================================================================
# T4: fast_parse_uint_n_digits handles n in [1, 16] with parity vs scalar.
# =============================================================================


def test_t4_uint_n_digits_parity_with_scalar() raises:
    # n=1
    var b1 = _bytes("5")
    var s1 = fast_parse_uint_n_digits(Span(b1), 1)
    assert_true(s1)
    assert_equal(Int(s1.value()), 5)

    # n=3
    var b3 = _bytes("123")
    var s3 = fast_parse_uint_n_digits(Span(b3), 3)
    assert_true(s3)
    assert_equal(Int(s3.value()), 123)

    # n=7 (just under 8, scalar path)
    var b7 = _bytes("1234567")
    var s7 = fast_parse_uint_n_digits(Span(b7), 7)
    assert_true(s7)
    assert_equal(Int(s7.value()), 1234567)

    # n=8 (Lemire SIMD path)
    var b8 = _bytes("12345678")
    var s8 = fast_parse_uint_n_digits(Span(b8), 8)
    assert_true(s8)
    assert_equal(Int(s8.value()), 12345678)

    # n=10
    var b10 = _bytes("1234567890")
    var s10 = fast_parse_uint_n_digits(Span(b10), 10)
    assert_true(s10)
    assert_equal(Int(s10.value()), 1234567890)

    # n=16 (max SIMD path)
    var b16 = _bytes("1234567890123456")
    var s16 = fast_parse_uint_n_digits(Span(b16), 16)
    assert_true(s16)
    assert_equal(Int(s16.value()), 1234567890123456)

    # n=17 (out of fast-path range)
    var b17 = _bytes("12345678901234567")
    var s17 = fast_parse_uint_n_digits(Span(b17), 17)
    assert_false(s17, "T4: n=17 should reject (out of fast-path range)")


# =============================================================================
# T5: fast_parse_int64_simple accepts optional sign + digits.
# =============================================================================


def test_t5_int64_simple_accepts_signed_digits() raises:
    var b_neg = _bytes("-1234567")
    var v_neg = fast_parse_int64_simple(Span(b_neg))
    assert_true(v_neg)
    assert_equal(Int(v_neg.value()), -1234567)

    var b_plus = _bytes("+42")
    var v_plus = fast_parse_int64_simple(Span(b_plus))
    assert_true(v_plus)
    assert_equal(Int(v_plus.value()), 42)

    var b_zero = _bytes("0")
    var v_zero = fast_parse_int64_simple(Span(b_zero))
    assert_true(v_zero)
    assert_equal(Int(v_zero.value()), 0)

    var b_big = _bytes("9999999999999999")
    var v_big = fast_parse_int64_simple(Span(b_big))
    assert_true(v_big)
    assert_equal(Int(v_big.value()), 9999999999999999)

    var b_neg_big = _bytes("-9999999999999999")
    var v_neg_big = fast_parse_int64_simple(Span(b_neg_big))
    assert_true(v_neg_big)
    assert_equal(Int(v_neg_big.value()), -9999999999999999)


# =============================================================================
# T6: fast_parse_int64_simple rejects empty / sign-only / over-length.
# =============================================================================


def test_t6_int64_simple_rejects_edge_shapes() raises:
    var b_empty = _bytes("")
    assert_false(fast_parse_int64_simple(Span(b_empty)), "T6: empty rejected")

    var b_sign_only = _bytes("-")
    assert_false(fast_parse_int64_simple(Span(b_sign_only)), "T6: sign-only rejected")

    var b_plus_only = _bytes("+")
    assert_false(fast_parse_int64_simple(Span(b_plus_only)), "T6: plus-only rejected")

    # 18-byte cell: rejected (out of fast path).
    var b_18 = _bytes("123456789012345678")
    assert_false(fast_parse_int64_simple(Span(b_18)), "T6: 18 bytes rejected")

    # Decimal/letter rejected at fast-path applicability check.
    var b_dot = _bytes("1.5")
    assert_false(fast_parse_int64_simple(Span(b_dot)), "T6: decimal rejected")


# =============================================================================
# T7: fast_parse_int64_simple equivalence with _try_parse_int64 (parity).
# =============================================================================


def test_t7_int64_simple_parity_with_scalar() raises:
    # For every input where the fast path SAYS yes, the scalar parser
    # must agree on the value. Cover positive / negative / zero /
    # boundary lengths.
    var inputs = List[String]()
    inputs.append(String("0"))
    inputs.append(String("1"))
    inputs.append(String("-1"))
    inputs.append(String("42"))
    inputs.append(String("-42"))
    inputs.append(String("100000000"))   # 9 digits
    inputs.append(String("1234567890"))  # 10 digits
    inputs.append(String("9999999999")) # 10 digits
    inputs.append(String("1234567890123"))  # 13 digits
    inputs.append(String("-1234567890123"))  # 13 digits + sign
    inputs.append(String("9999999999999999"))  # 16 digits
    inputs.append(String("-9999999999999999"))

    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_int64_simple(Span(b))
        var scalar = _try_parse_int64(Span(b))
        assert_true(fast, "T7: fast parser accepts " + inputs[i])
        assert_true(scalar, "T7: scalar parser accepts " + inputs[i])
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "T7: parity for " + inputs[i],
        )
        i = i + 1


# =============================================================================
# T8: fast_parse_float64_simple integer-shape only; rejects decimals/exp.
# =============================================================================


def test_t8_float64_simple_integer_shape_only() raises:
    var b_int = _bytes("12345")
    var v = fast_parse_float64_simple(Span(b_int))
    assert_true(v, "T8: integer-shaped 12345 accepted")
    assert_equal(Int(v.value()), 12345)

    var b_neg = _bytes("-42")
    var v_neg = fast_parse_float64_simple(Span(b_neg))
    assert_true(v_neg)
    assert_equal(Int(v_neg.value()), -42)

    var b_dot = _bytes("1.5")
    assert_false(fast_parse_float64_simple(Span(b_dot)), "T8: decimal rejected")

    var b_exp = _bytes("1e5")
    assert_false(fast_parse_float64_simple(Span(b_exp)), "T8: exponent rejected")

    var b_E = _bytes("1E5")
    assert_false(fast_parse_float64_simple(Span(b_E)), "T8: exp E rejected")


# =============================================================================
# T9: fast_parse_float64_simple parity with _try_parse_float64
# (integer-shaped inputs only).
# =============================================================================


def test_t9_float64_simple_parity_with_scalar() raises:
    var inputs = List[String]()
    inputs.append(String("0"))
    inputs.append(String("1"))
    inputs.append(String("-1"))
    inputs.append(String("12345"))
    inputs.append(String("-12345"))
    inputs.append(String("999999999"))
    inputs.append(String("-999999999"))

    var sep = UInt8(0x2E)  # '.'
    var i = 0
    while i < len(inputs):
        var b = _bytes(inputs[i])
        var fast = fast_parse_float64_simple(Span(b))
        var scalar = _try_parse_float64(Span(b), sep)
        assert_true(fast, "T9: fast accepts " + inputs[i])
        assert_true(scalar, "T9: scalar accepts " + inputs[i])
        # Float equality on integer-shaped inputs is exact.
        var f = Float64(fast.value())
        var s = Float64(scalar.value())
        assert_true(f == s, "T9: parity for " + inputs[i])
        i = i + 1


# =============================================================================
# T10: cell_is_simple_numeric applicability gate semantics.
# =============================================================================


def test_t10_cell_is_simple_numeric_gate() raises:
    # Accepts: digits, sign, decimal.
    var b1 = _bytes("12345")
    assert_true(cell_is_simple_numeric(Span(b1)), "T10: 12345 simple")

    var b2 = _bytes("-12.5")
    assert_true(cell_is_simple_numeric(Span(b2)), "T10: -12.5 simple")

    var b3 = _bytes("+3.14")
    assert_true(cell_is_simple_numeric(Span(b3)), "T10: +3.14 simple")

    # Rejects: empty, too long, letters, whitespace.
    var b_empty = _bytes("")
    assert_false(cell_is_simple_numeric(Span(b_empty)), "T10: empty rejected")

    var b_17 = _bytes("12345678901234567")  # 17 bytes
    assert_false(cell_is_simple_numeric(Span(b_17)), "T10: 17 bytes rejected")

    var b_letter = _bytes("12345a")
    assert_false(cell_is_simple_numeric(Span(b_letter)), "T10: letter rejected")

    var b_exp = _bytes("1e5")
    assert_false(cell_is_simple_numeric(Span(b_exp)), "T10: exponent rejected")

    var b_space = _bytes("12 45")
    assert_false(cell_is_simple_numeric(Span(b_space)), "T10: space rejected")


# =============================================================================
# T11: Lemire 8-digit boundary values.
# =============================================================================


def test_t11_lemire_boundary_values() raises:
    var cases = List[Tuple[String, Int]]()
    cases.append((String("00000000"), 0))
    cases.append((String("00000001"), 1))
    cases.append((String("10000000"), 10000000))
    cases.append((String("99999999"), 99999999))
    cases.append((String("12345678"), 12345678))
    cases.append((String("87654321"), 87654321))
    cases.append((String("01234567"), 1234567))
    cases.append((String("10101010"), 10101010))

    var i = 0
    while i < len(cases):
        var s = cases[i][0]
        var expected = cases[i][1]
        var b = _bytes(s)
        var v = fast_parse_uint_8digit(Span(b))
        assert_true(v, "T11: " + s + " accepted")
        assert_equal(Int(v.value()), expected, "T11: " + s + " value")
        i = i + 1


# =============================================================================
# T12: fast_parse_uint_n_digits n=9..16 matches scalar UInt64.
# =============================================================================


def test_t12_uint_n_digits_9_to_16_parity() raises:
    var inputs = List[String]()
    inputs.append(String("123456789"))             # 9
    inputs.append(String("1234567890"))            # 10
    inputs.append(String("12345678901"))           # 11
    inputs.append(String("123456789012"))          # 12
    inputs.append(String("1234567890123"))         # 13
    inputs.append(String("12345678901234"))        # 14
    inputs.append(String("123456789012345"))       # 15
    inputs.append(String("1234567890123456"))      # 16

    var i = 0
    while i < len(inputs):
        var s = inputs[i]
        var b = _bytes(s)
        var fast = fast_parse_uint_n_digits(Span(b), s.byte_length())
        var scalar = _try_parse_uint64(Span(b))
        assert_true(fast, "T12: fast accepts " + s)
        assert_true(scalar, "T12: scalar accepts " + s)
        assert_equal(
            Int(fast.value()),
            Int(scalar.value()),
            "T12: parity for " + s,
        )
        i = i + 1


# =============================================================================
# T13: fast_parse_int64_simple Int64-near-overflow handling.
# =============================================================================


def test_t13_int64_simple_near_overflow() raises:
    # 16 digits: within fast-path range, never overflows Int64.
    var b16 = _bytes("9999999999999999")  # 16 digits = 9.99...e15 < 9.22e18 (Int64.max)
    var v16 = fast_parse_int64_simple(Span(b16))
    assert_true(v16, "T13: 16-digit positive accepted")

    # 17 digits: rejected by fast path (16-digit ceiling). Scalar parser
    # handles 17-19 digits correctly.
    var b17 = _bytes("12345678901234567")  # 17 digits
    var v17 = fast_parse_int64_simple(Span(b17))
    assert_false(v17, "T13: 17-digit fast-path rejected (caller falls back to scalar)")

    # Sign + 16 digits = 17 byte cell. Fast path rejects on length.
    var b_signed_16 = _bytes("-1234567890123456")  # 17 bytes total
    var v_s = fast_parse_int64_simple(Span(b_signed_16))
    # 17 bytes total = sign + 16 digits = digit_count=16 = within fast-path
    # acceptance range. So this should succeed.
    assert_true(v_s, "T13: 17-byte signed (1 sign + 16 digits) accepted")
    assert_equal(Int(v_s.value()), -1234567890123456)


# =============================================================================
# T14: cell_is_simple_numeric rejects non-applicable shapes.
# =============================================================================


def test_t14_cell_is_simple_numeric_rejects_invalid() raises:
    var b_quoted = _bytes("\"123\"")  # quoted cell with internal quotes
    assert_false(cell_is_simple_numeric(Span(b_quoted)), "T14: quoted rejected")

    var b_tab = _bytes("12\t45")
    assert_false(cell_is_simple_numeric(Span(b_tab)), "T14: tab rejected")

    var b_newline = _bytes("12\n45")
    assert_false(cell_is_simple_numeric(Span(b_newline)), "T14: newline rejected")

    var b_18 = _bytes("123456789012345678")  # 18 bytes
    assert_false(cell_is_simple_numeric(Span(b_18)), "T14: 18 bytes rejected")

    var b_letter_mix = _bytes("1234e5")
    assert_false(cell_is_simple_numeric(Span(b_letter_mix)), "T14: exponent letter rejected")

    var b_negative_decimal = _bytes("-12.5")  # valid simple-numeric
    assert_true(cell_is_simple_numeric(Span(b_negative_decimal)), "T14: signed decimal accepted")


# =============================================================================
# Driver.
# =============================================================================


def main() raises:
    test_t1_uint_8digit_accepts_8_ascii_digits()
    test_t2_uint_8digit_rejects_wrong_length()
    test_t3_uint_8digit_rejects_non_digits()
    test_t4_uint_n_digits_parity_with_scalar()
    test_t5_int64_simple_accepts_signed_digits()
    test_t6_int64_simple_rejects_edge_shapes()
    test_t7_int64_simple_parity_with_scalar()
    test_t8_float64_simple_integer_shape_only()
    test_t9_float64_simple_parity_with_scalar()
    test_t10_cell_is_simple_numeric_gate()
    test_t11_lemire_boundary_values()
    test_t12_uint_n_digits_9_to_16_parity()
    test_t13_int64_simple_near_overflow()
    test_t14_cell_is_simple_numeric_rejects_invalid()
    print("test_csv_simd_cell_parsers: all 14 tests PASS")
