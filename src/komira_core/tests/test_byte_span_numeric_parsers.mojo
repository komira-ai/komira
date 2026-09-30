# =============================================================================
# Tests for komira_core.parsers.byte_span_numeric — SIMD byte-span numeric
# fast paths.
# =============================================================================
#
# Covers `fast_parse_int64_simple` + `fast_parse_float64_simple` + their
# helpers `fast_parse_uint_8digit` / `fast_parse_uint_n_digits`, shared by the
# CSV cell parsers and the row-typed CSV decoder.
#
# Acceptance categories:
#   §1 — fast_parse_uint_8digit applicability + values across boundaries
#   §2 — fast_parse_uint_n_digits N in [1..16] (incl. boundaries)
#   §3 — fast_parse_int64_simple sign / boundary / out-of-applicability
#   §4 — fast_parse_float64_simple integer-shape acceptance + decimal
#         reject (None) for scalar fallback
#   §5 — End-to-end byte-identity: SIMD result equals what scalar
#         parsing produces (for inputs within SIMD applicability).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.parsers.byte_span_numeric import (
    fast_parse_uint_8digit,
    fast_parse_uint_n_digits,
    fast_parse_int64_simple,
    fast_parse_float64_simple,
    fast_parse_float64_decimal,
)


# =============================================================================
# §1 — fast_parse_uint_8digit
# =============================================================================


def test_uint_8digit_basic() raises:
    """Exactly 8 ASCII digits — happy path."""
    var bytes = String("12345678").as_bytes()
    var v = fast_parse_uint_8digit(bytes)
    assert_true(v)
    assert_equal(v.value(), UInt64(12345678))


def test_uint_8digit_all_zeros() raises:
    """b'00000000' -> 0."""
    var bytes = String("00000000").as_bytes()
    var v = fast_parse_uint_8digit(bytes)
    assert_true(v)
    assert_equal(v.value(), UInt64(0))


def test_uint_8digit_all_nines() raises:
    """b'99999999' -> 99999999 (max 8-digit value)."""
    var bytes = String("99999999").as_bytes()
    var v = fast_parse_uint_8digit(bytes)
    assert_true(v)
    assert_equal(v.value(), UInt64(99999999))


def test_uint_8digit_wrong_length_rejects() raises:
    """Non-8-byte input -> None (caller falls back)."""
    var b7 = String("1234567").as_bytes()
    assert_false(fast_parse_uint_8digit(b7))
    var b9 = String("123456789").as_bytes()
    assert_false(fast_parse_uint_8digit(b9))
    var b0 = String("").as_bytes()
    assert_false(fast_parse_uint_8digit(b0))


def test_uint_8digit_non_digit_rejects() raises:
    """Sign in 8-byte cell -> None (sign-handling is the caller's job)."""
    var with_sign = String("-1234567").as_bytes()
    assert_false(fast_parse_uint_8digit(with_sign))
    # Non-digit byte at any lane rejects.
    var with_letter = String("12a45678").as_bytes()
    assert_false(fast_parse_uint_8digit(with_letter))


# =============================================================================
# §2 — fast_parse_uint_n_digits — N in [1..16]
# =============================================================================


def test_uint_n_digits_n_eq_1() raises:
    """Single-digit case — scalar tight-loop branch."""
    var bytes = String("7").as_bytes()
    var v = fast_parse_uint_n_digits(bytes, 1)
    assert_true(v)
    assert_equal(v.value(), UInt64(7))


def test_uint_n_digits_n_lt_8() raises:
    """N in [1, 7] — scalar branch."""
    var bytes = String("123456").as_bytes()
    var v = fast_parse_uint_n_digits(bytes, 6)
    assert_true(v)
    assert_equal(v.value(), UInt64(123456))


def test_uint_n_digits_n_eq_8() raises:
    """N == 8 — direct Lemire SIMD."""
    var bytes = String("98765432").as_bytes()
    var v = fast_parse_uint_n_digits(bytes, 8)
    assert_true(v)
    assert_equal(v.value(), UInt64(98765432))


def test_uint_n_digits_n_eq_9() raises:
    """N == 9 — Lemire on first 8 + scalar remainder."""
    var bytes = String("123456789").as_bytes()
    var v = fast_parse_uint_n_digits(bytes, 9)
    assert_true(v)
    assert_equal(v.value(), UInt64(123456789))


def test_uint_n_digits_n_eq_16() raises:
    """N == 16 — full Lemire + scalar last-8."""
    var bytes = String("1234567890123456").as_bytes()
    var v = fast_parse_uint_n_digits(bytes, 16)
    assert_true(v)
    assert_equal(v.value(), UInt64(1234567890123456))


def test_uint_n_digits_n_out_of_range_rejects() raises:
    """N == 0 / N > 16 -> None."""
    var bytes = String("17digits1234567890").as_bytes()
    assert_false(fast_parse_uint_n_digits(bytes, 17))
    assert_false(fast_parse_uint_n_digits(bytes[:0], 0))


def test_uint_n_digits_mismatch_len_rejects() raises:
    """`n != len(cell)` -> None."""
    var bytes = String("12345").as_bytes()
    assert_false(fast_parse_uint_n_digits(bytes, 6))
    assert_false(fast_parse_uint_n_digits(bytes, 4))


def test_uint_n_digits_non_digit_byte_rejects() raises:
    """Non-digit byte anywhere -> None."""
    var bytes = String("12a4567890").as_bytes()
    assert_false(fast_parse_uint_n_digits(bytes, 10))


# =============================================================================
# §3 — fast_parse_int64_simple
# =============================================================================


def test_int64_zero() raises:
    """b'0' -> 0."""
    var bytes = String("0").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Int64(0))


def test_int64_single_digit() raises:
    """b'7' -> 7."""
    var bytes = String("7").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Int64(7))


def test_int64_negative() raises:
    """b'-42' -> -42."""
    var bytes = String("-42").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Int64(-42))


def test_int64_positive_with_sign() raises:
    """b'+123' -> 123 (explicit plus sign accepted)."""
    var bytes = String("+123").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Int64(123))


def test_int64_max_safe_16digit() raises:
    """b'9999999999999999' (16-digit max) -> 9999999999999999.

    The SIMD fast path covers up to 16 digits; the 17-19 digit range
    falls through to None (caller -> scalar).
    """
    var bytes = String("9999999999999999").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Int64(9999999999999999))


def test_int64_max_negative_16digit() raises:
    """b'-9999999999999999' -> -9999999999999999."""
    var bytes = String("-9999999999999999").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Int64(-9999999999999999))


def test_int64_18digit_rejects() raises:
    """b'123456789012345678' (18 digits) -> None (> 16-digit cap)."""
    var bytes = String("123456789012345678").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_false(v)


def test_int64_empty_rejects() raises:
    """b'' -> None."""
    var bytes = String("").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_false(v)


def test_int64_lone_minus_rejects() raises:
    """b'-' -> None (sign-only)."""
    var bytes = String("-").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_false(v)


def test_int64_double_minus_rejects() raises:
    """b'--5' -> None (non-digit after sign)."""
    var bytes = String("--5").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_false(v)


def test_int64_alpha_rejects() raises:
    """b'abc' -> None."""
    var bytes = String("abc").as_bytes()
    var v = fast_parse_int64_simple(bytes)
    assert_false(v)


# =============================================================================
# §4 — fast_parse_float64_simple — integer-shape acceptance + decimal reject
# =============================================================================


def test_float64_integer_shape() raises:
    """b'42' -> 42.0 (integer-shape accepted)."""
    var bytes = String("42").as_bytes()
    var v = fast_parse_float64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(42.0))


def test_float64_negative_integer_shape() raises:
    """b'-100' -> -100.0."""
    var bytes = String("-100").as_bytes()
    var v = fast_parse_float64_simple(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(-100.0))


def test_float64_decimal_rejects() raises:
    """b'3.14' -> None (decimal point — fallback to scalar)."""
    var bytes = String("3.14").as_bytes()
    var v = fast_parse_float64_simple(bytes)
    assert_false(v)


def test_float64_scientific_rejects() raises:
    """b'1.5e10' -> None (exponent — fallback to scalar)."""
    var bytes = String("1.5e10").as_bytes()
    var v = fast_parse_float64_simple(bytes)
    assert_false(v)


def test_float64_neg_zero_rejects_decimal() raises:
    """b'-0.0' -> None (decimal — scalar handles -0.0 IEEE-754)."""
    var bytes = String("-0.0").as_bytes()
    var v = fast_parse_float64_simple(bytes)
    assert_false(v)


def test_float64_empty_rejects() raises:
    """b'' -> None."""
    var bytes = String("").as_bytes()
    var v = fast_parse_float64_simple(bytes)
    assert_false(v)


# =============================================================================
# §5 — Byte-identity vs scalar reference
# =============================================================================
#
# For inputs within the SIMD applicability gate, the result MUST equal
# what an equivalent scalar parser produces. We hand-compute the scalar
# reference inline (single-pass digit accumulator) and compare to the
# SIMD result. This is the load-bearing test: if SIMD diverges from
# scalar on ANY input, the dispatch HALTs.


@always_inline
def _scalar_i64_ref[bo: Origin[mut=False]](span: Span[UInt8, bo]) raises -> Int64:
    """Scalar reference parser — mirror of _parse_i64_bytes_scalar."""
    var n = len(span)
    if n == 0:
        raise Error("empty")
    var i = 0
    var neg = False
    if span[0] == UInt8(0x2D):
        neg = True
        i = 1
        if i >= n:
            raise Error("sign-only")
    elif span[0] == UInt8(0x2B):
        i = 1
        if i >= n:
            raise Error("sign-only")
    var v: Int64 = 0
    while i < n:
        var b = span[i]
        if b < UInt8(0x30) or b > UInt8(0x39):
            raise Error("non-digit")
        v = v * Int64(10) + Int64(Int(b) - 0x30)
        i = i + 1
    if neg:
        v = -v
    return v


def test_byte_identity_simd_vs_scalar_sweep() raises:
    """For each `applicable` input in a hand-picked set, SIMD == scalar."""
    var cases = List[String]()
    cases.append(String("0"))
    cases.append(String("1"))
    cases.append(String("9"))
    cases.append(String("12"))
    cases.append(String("123"))
    cases.append(String("1234"))
    cases.append(String("12345"))
    cases.append(String("123456"))
    cases.append(String("1234567"))
    cases.append(String("12345678"))            # n == 8 SIMD edge
    cases.append(String("123456789"))           # n == 9 SIMD+scalar combine
    cases.append(String("1234567890"))
    cases.append(String("12345678901234"))
    cases.append(String("1234567890123456"))    # n == 16 SIMD edge (Lemire+scalar)
    cases.append(String("-1"))
    cases.append(String("-9999999999999999"))   # 16-digit negative
    cases.append(String("+42"))                 # explicit plus
    var i = 0
    while i < len(cases):
        var s = cases[i]
        var span = s.as_bytes()
        var simd = fast_parse_int64_simple(span)
        assert_true(simd)  # all of these MUST be in the SIMD applicability range.
        var scalar = _scalar_i64_ref(span)
        assert_equal(simd.value(), scalar)
        i = i + 1


def test_byte_identity_float64_integer_shape() raises:
    """For integer-shaped inputs, fast_parse_float64_simple equals
    Float64(scalar_i64)."""
    var cases = List[String]()
    cases.append(String("0"))
    cases.append(String("100"))
    cases.append(String("-50"))
    cases.append(String("12345678"))            # SIMD width edge
    cases.append(String("+999"))
    var i = 0
    while i < len(cases):
        var s = cases[i]
        var span = s.as_bytes()
        var fast_f = fast_parse_float64_simple(span)
        assert_true(fast_f)
        var scalar_i = _scalar_i64_ref(span)
        assert_equal(fast_f.value(), Float64(Int(scalar_i)))
        i = i + 1


# =============================================================================
# §6 — fast_parse_float64_decimal
# =============================================================================
#
# Acceptance:
#   - `[+/-] int . frac` shape with 1-15 digits each side, total <= 16.
#   - Bit-exact against stdlib Float64(String(...)) for inputs that fit
#     in 15 significant decimal digits.
#
# Reject:
#   - empty / sign-only / leading-dot / trailing-dot
#   - no dot (integer-shape — caller should try fast_parse_float64_simple)
#   - multi-dot / exponent / non-digit byte
#   - > 17 bytes / > 16 mantissa digits


def test_float64_decimal_basic_1_5() raises:
    """b'1.5' -> 1.5."""
    var bytes = String("1.5").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(1.5))


def test_float64_decimal_lineitem_discount() raises:
    """b'0.05' -> 0.05 (l_discount shape)."""
    var bytes = String("0.05").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(0.05))


def test_float64_decimal_lineitem_tax() raises:
    """b'0.07' -> 0.07 (l_tax shape)."""
    var bytes = String("0.07").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(0.07))


def test_float64_decimal_lineitem_extprice() raises:
    """b'1234.56' -> 1234.56 (l_extendedprice shape)."""
    var bytes = String("1234.56").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(1234.56))


def test_float64_decimal_negative() raises:
    """b'-3.14' -> -3.14."""
    var bytes = String("-3.14").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(-3.14))


def test_float64_decimal_plus_sign() raises:
    """b'+1.25' -> 1.25 (explicit plus sign accepted)."""
    var bytes = String("+1.25").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(1.25))


def test_float64_decimal_neg_zero() raises:
    """b'-0.0' -> 0.0 (binary equal; sign bit may differ on -0.0,
    accept either form via numeric equality)."""
    var bytes = String("-0.0").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    # Float64(0.0) == Float64(-0.0) is True under IEEE-754 numeric eq.
    assert_equal(v.value(), Float64(0.0))


def test_float64_decimal_boundary_8int_2frac() raises:
    """b'99999999.99' -> 99999999.99 (10 mantissa digits)."""
    var bytes = String("99999999.99").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_true(v)
    assert_equal(v.value(), Float64(99999999.99))


# --- Reject cases (gate failures -> None, caller falls through) ---


def test_float64_decimal_empty_rejects() raises:
    """b'' -> None."""
    var bytes = String("").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_just_dot_rejects() raises:
    """b'.' -> None (no digits, leading-dot AND trailing-dot)."""
    var bytes = String(".").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_trailing_dot_rejects() raises:
    """b'1.' -> None (no fractional digits)."""
    var bytes = String("1.").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_leading_dot_rejects() raises:
    """b'.5' -> None (no integer digits)."""
    var bytes = String(".5").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_exponent_rejects() raises:
    """b'1.5e10' -> None (exponent — caller falls through to scalar)."""
    var bytes = String("1.5e10").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_double_dot_rejects() raises:
    """b'1..5' -> None (two dots)."""
    var bytes = String("1..5").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_no_dot_rejects() raises:
    """b'42' -> None (integer-shaped — caller should use the integer
    fast path)."""
    var bytes = String("42").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_sign_only_rejects() raises:
    """b'-' / b'+' -> None."""
    var minus = String("-").as_bytes()
    assert_false(fast_parse_float64_decimal(minus))
    var plus = String("+").as_bytes()
    assert_false(fast_parse_float64_decimal(plus))


def test_float64_decimal_too_long_rejects() raises:
    """b'123456789012345.67' -> None (mantissa 17 digits > 16-digit cap)."""
    var bytes = String("123456789012345.67").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


def test_float64_decimal_alpha_byte_rejects() raises:
    """b'1.a5' -> None (non-digit byte in fractional part)."""
    var bytes = String("1.a5").as_bytes()
    var v = fast_parse_float64_decimal(bytes)
    assert_false(v)


# --- Byte-identity vs stdlib reference (the load-bearing test) ---


def test_float64_decimal_byte_identity_vs_stdlib() raises:
    """For each decimal-shaped input, fast_parse_float64_decimal
    equals Float64(String(StringSlice(unsafe_from_utf8=span))) under
    binary equality. The stdlib path is what the row decoder's
    fallback arm uses, so byte-identity here is the correctness
    contract for the SIMD-first dispatch."""
    var cases = List[String]()
    cases.append(String("0.0"))
    cases.append(String("0.1"))
    cases.append(String("0.5"))
    cases.append(String("1.0"))
    cases.append(String("1.5"))
    cases.append(String("0.05"))            # discount
    cases.append(String("0.07"))            # tax
    cases.append(String("1234.56"))         # extprice
    cases.append(String("-3.14"))
    cases.append(String("+2.5"))
    cases.append(String("99999999.99"))
    cases.append(String("12345.6789"))
    cases.append(String("1.0000000000"))    # 10-digit zero-padded
    var i = 0
    while i < len(cases):
        var s = cases[i]
        var span = s.as_bytes()
        var fast = fast_parse_float64_decimal(span)
        assert_true(fast)
        var stdlib_ref = Float64(String(StringSlice(unsafe_from_utf8=span)))
        # IEEE-754 binary equality — same bit pattern.
        assert_equal(fast.value(), stdlib_ref)
        i = i + 1


def main() raises:
    var suite = TestSuite()
    # §1
    suite.test[test_uint_8digit_basic]()
    suite.test[test_uint_8digit_all_zeros]()
    suite.test[test_uint_8digit_all_nines]()
    suite.test[test_uint_8digit_wrong_length_rejects]()
    suite.test[test_uint_8digit_non_digit_rejects]()
    # §2
    suite.test[test_uint_n_digits_n_eq_1]()
    suite.test[test_uint_n_digits_n_lt_8]()
    suite.test[test_uint_n_digits_n_eq_8]()
    suite.test[test_uint_n_digits_n_eq_9]()
    suite.test[test_uint_n_digits_n_eq_16]()
    suite.test[test_uint_n_digits_n_out_of_range_rejects]()
    suite.test[test_uint_n_digits_mismatch_len_rejects]()
    suite.test[test_uint_n_digits_non_digit_byte_rejects]()
    # §3
    suite.test[test_int64_zero]()
    suite.test[test_int64_single_digit]()
    suite.test[test_int64_negative]()
    suite.test[test_int64_positive_with_sign]()
    suite.test[test_int64_max_safe_16digit]()
    suite.test[test_int64_max_negative_16digit]()
    suite.test[test_int64_18digit_rejects]()
    suite.test[test_int64_empty_rejects]()
    suite.test[test_int64_lone_minus_rejects]()
    suite.test[test_int64_double_minus_rejects]()
    suite.test[test_int64_alpha_rejects]()
    # §4
    suite.test[test_float64_integer_shape]()
    suite.test[test_float64_negative_integer_shape]()
    suite.test[test_float64_decimal_rejects]()
    suite.test[test_float64_scientific_rejects]()
    suite.test[test_float64_neg_zero_rejects_decimal]()
    suite.test[test_float64_empty_rejects]()
    # §5
    suite.test[test_byte_identity_simd_vs_scalar_sweep]()
    suite.test[test_byte_identity_float64_integer_shape]()
    # §6 — fast_parse_float64_decimal
    suite.test[test_float64_decimal_basic_1_5]()
    suite.test[test_float64_decimal_lineitem_discount]()
    suite.test[test_float64_decimal_lineitem_tax]()
    suite.test[test_float64_decimal_lineitem_extprice]()
    suite.test[test_float64_decimal_negative]()
    suite.test[test_float64_decimal_plus_sign]()
    suite.test[test_float64_decimal_neg_zero]()
    suite.test[test_float64_decimal_boundary_8int_2frac]()
    suite.test[test_float64_decimal_empty_rejects]()
    suite.test[test_float64_decimal_just_dot_rejects]()
    suite.test[test_float64_decimal_trailing_dot_rejects]()
    suite.test[test_float64_decimal_leading_dot_rejects]()
    suite.test[test_float64_decimal_exponent_rejects]()
    suite.test[test_float64_decimal_double_dot_rejects]()
    suite.test[test_float64_decimal_no_dot_rejects]()
    suite.test[test_float64_decimal_sign_only_rejects]()
    suite.test[test_float64_decimal_too_long_rejects]()
    suite.test[test_float64_decimal_alpha_byte_rejects]()
    suite.test[test_float64_decimal_byte_identity_vs_stdlib]()
    suite^.run()
