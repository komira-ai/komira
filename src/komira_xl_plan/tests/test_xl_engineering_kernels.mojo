# =============================================================================
# test_xl_engineering_kernels.mojo — ★ THE LAST WHOLE CATEGORY AT ZERO, GRADED.
# =============================================================================
#
# ============ ⛔⛔ THE SELECTION RULE: **THE BOUNDARY, NEVER 1+1** ===========
#
# Engineering is where a plausible-but-wrong answer hides best, because the
# naive kernel is EXACTLY RIGHT over most of the domain. Every assertion below
# is at the input where the two implementations first differ, and several are
# paired with the BLIND input that proves the ordinary case discriminates
# nothing:
#
#   HEX2DEC      ★ the whole family's discriminator. Excel's hex door is
#                40-BIT two's complement: `HEX2DEC("FFFFFFFFFF")` is -1 and
#                `HEX2DEC("FFFFFFFF")` is +4294967295. A 32-bit kernel answers
#                -1 for BOTH and agrees with this one on every hex literal of
#                eight digits or fewer.
#   DEC2BIN      `places` is IGNORED for a negative number. A kernel that
#                honours it returns a SHORTER well-formed string, never an
#                error.
#   OCT2BIN      the NARROWING direction: the octal door admits 2^29 and the
#                binary one 512, so the range check is on the DESTINATION.
#   BITLSHIFT    2^48 and not 2^32/2^53, checked on the RESULT: (1,48) is
#                #NUM! and (1,47) is 140737488355328.
#   BITRSHIFT    a NEGATIVE shift shifts the other way — 52, not 13.
#   GESTEP       `GESTEP(-4,-5)` is 1; a magnitude compare answers 0 and is
#                right everywhere both arguments are non-negative.
#   ERF          the two-argument form: `ERF(1,2)` is 0.15262 and a kernel
#                that drops the second argument answers 0.84270, which is a
#                number of exactly the expected shape.
#   IMARGUMENT   `atan2` and not `atan(b/a)`: `IMARGUMENT("-1")` is pi and the
#                quotient form answers 0. The branch cut, at the shortest
#                literal in the family.
#   IMPRODUCT    the MINUS in `ac - bd`: -5, where an adding kernel answers 13.
#   COMPLEX      the coefficient 1 is OMITTED: `"3+i"`, `"-i"`, `"3"`, `"0"` —
#                four strings a naive concatenation gets wrong while being
#                right for `COMPLEX(3,4)`.
#   IM* parsing  a malformed literal is **`#NUM!`**, not `#VALUE!`.
#   suffix       `IMSUM("3+4j","1+2j")` is `"4+6j"`. A kernel that always emits
#                `i` returns the right NUMBER under the wrong spelling and
#                passes any check that parses its own answer back.
#
# ⚠ NO `EngineContext`, NO FILE, NO FIXTURE — this file is welded to
# `komira_xl_plan`, which downstream bindings link, so every assertion is a
# pure function of a `FormulaValue`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NUM,
    XL_ERR_VALUE,
)

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_scalar_engineering import (
    xl_bin2dec,
    xl_bin2hex,
    xl_bin2oct,
    xl_bitand,
    xl_bitlshift,
    xl_bitor,
    xl_bitrshift,
    xl_bitxor,
    xl_complex,
    xl_dec2bin,
    xl_dec2hex,
    xl_dec2oct,
    xl_delta,
    xl_erf,
    xl_erf_precise,
    xl_erfc,
    xl_erfc_precise,
    xl_gestep,
    xl_hex2bin,
    xl_hex2dec,
    xl_hex2oct,
    xl_imabs,
    xl_imaginary,
    xl_imargument,
    xl_imconjugate,
    xl_imcos,
    xl_imcosh,
    xl_imcot,
    xl_imcsc,
    xl_imcsch,
    xl_imdiv,
    xl_imexp,
    xl_imln,
    xl_imlog10,
    xl_imlog2,
    xl_impower,
    xl_improduct,
    xl_imreal,
    xl_imsec,
    xl_imsech,
    xl_imsin,
    xl_imsinh,
    xl_imsqrt,
    xl_imsub,
    xl_imsum,
    xl_imtan,
    xl_oct2bin,
    xl_oct2dec,
    xl_oct2hex,
)


# =============================================================================
# Argument helpers — a kernel takes a `List[FormulaValue]`.
# =============================================================================
def _n1(a: Float64) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    v.append(FormulaValue.number(a))
    return v^


def _n2(a: Float64, b: Float64) -> List[FormulaValue]:
    var v = _n1(a)
    v.append(FormulaValue.number(b))
    return v^


def _s1(a: String) -> List[FormulaValue]:
    var v = List[FormulaValue]()
    v.append(FormulaValue.text_val(a))
    return v^


def _s2(a: String, b: String) -> List[FormulaValue]:
    var v = _s1(a)
    v.append(FormulaValue.text_val(b))
    return v^


def _s3(a: String, b: String, c: String) -> List[FormulaValue]:
    var v = _s2(a, b)
    v.append(FormulaValue.text_val(c))
    return v^


def _sn(a: String, b: Float64) -> List[FormulaValue]:
    var v = _s1(a)
    v.append(FormulaValue.number(b))
    return v^


# =============================================================================
# Assertion helpers.
# =============================================================================
def _txt(r: FormulaValue, want: String, why: String) raises:
    assert_true(r.is_text(), why + " — expected TEXT, got `" + r.render() + "`")
    assert_equal(r.text, want, why)


def _exact(r: FormulaValue, want: Float64, why: String) raises:
    """An EXACT numeric equality. Every base-conversion and bitwise answer is
    an integer below 2^53, so nothing here needs a tolerance and asking for one
    would hide a one-bit width error."""
    assert_true(r.is_number(), why + " — expected a NUMBER, got `"
                + r.render() + "`")
    assert_equal(r.num, want, why)


def _close(r: FormulaValue, want: Float64, why: String) raises:
    """1e-12 RELATIVE (absolute below 1) — five orders of magnitude tighter
    than every divergence this file asserts about, and loose enough that a
    libm difference across platforms cannot red it."""
    assert_true(r.is_number(), why + " — expected a NUMBER, got `"
                + r.render() + "`")
    var d = r.num - want
    if d < 0.0:
        d = -d
    var scale = want if want >= 0.0 else -want
    if scale < 1.0:
        scale = 1.0
    assert_true(d <= scale * 1e-12,
                why + " — got " + String(r.num) + ", want " + String(want))


def _err(r: FormulaValue, code: UInt8, why: String) raises:
    assert_true(r.is_error(), why + " — expected an ERROR, got `"
                + r.render() + "`")
    assert_equal(Int(r.error_code), Int(code), why)


def _cx_close(r: FormulaValue, wre: Float64, wim: Float64,
              why: String) raises:
    """Grade a complex ANSWER by parsing it back through `IMREAL`/`IMAGINARY`.

    ⚠ NOT BY STRING EQUALITY, deliberately: a non-integral coefficient renders
    through Float64's default repr, and pinning that spelling would make this
    file a test of the number formatter. The SPELLING assertions in this file
    are the ones whose coefficients are exact (`"3+i"`, `"-5+12i"`)."""
    assert_true(r.is_text(), why + " — expected TEXT, got `" + r.render() + "`")
    var re = xl_imreal(_s1(r.text))
    var im = xl_imaginary(_s1(r.text))
    _close(re, wre, why + " [real]")
    _close(im, wim, why + " [imag]")


# =============================================================================
# ★★ BASE CONVERSION — THE WIDTH IS THE FUNCTION.
# =============================================================================
def test_hex_is_FORTY_bits_and_eight_digits_is_POSITIVE() raises:
    """⛔⛔ THE DISCRIMINATOR OF THE WHOLE BASE FAMILY, AND THE BLIND CELL IS
    NAMED WITH IT.

    Excel's hex door is 40-bit two's complement. `HEX2DEC("FFFFFFFFFF")` (ten
    digits, the 40-bit sign bit set) is **-1**; `HEX2DEC("FFFFFFFF")` (eight
    digits, that bit CLEAR) is **+4294967295**. A 32-bit-minded kernel — the
    one every reader writes first — answers -1 for BOTH.

    ⚠ AND `HEX2DEC("1F")` = 31 IS THE BLIND CELL: every literal short enough
    to type by hand is positive and small, where the two implementations agree
    exactly. A fixture built from readable inputs cannot tell them apart."""
    _exact(xl_hex2dec(_s1(String("FFFFFFFFFF"))), -1.0,
           "★ TEN hex digits: the 40-bit sign bit is SET, so this is -1")
    _exact(xl_hex2dec(_s1(String("FFFFFFFF"))), 4294967295.0,
           "⛔ EIGHT hex digits is POSITIVE — a 32-bit kernel answers -1")
    _exact(xl_hex2dec(_s1(String("1F"))), 31.0,
           "★ THE BLIND CELL: short and positive, where every width agrees")
    # lower case is accepted on INPUT
    _exact(xl_hex2dec(_s1(String("ff"))), 255.0,
           "lower-case hex is accepted on input")


def test_the_three_bases_carry_THREE_DIFFERENT_widths() raises:
    """10 / 30 / 40 bits. One literal per base at its own sign boundary, and
    the same digit string means a different number in each."""
    _exact(xl_bin2dec(_s1(String("1111111111"))), -1.0,
           "★ TEN binary digits: 10-bit two's complement, -1")
    _exact(xl_bin2dec(_s1(String("111111111"))), 511.0,
           "NINE binary digits is POSITIVE 511")
    _exact(xl_oct2dec(_s1(String("7777777777"))), -1.0,
           "★ TEN octal digits: 30-bit two's complement, -1")
    _exact(xl_oct2dec(_s1(String("777777777"))), 134217727.0,
           "NINE octal digits is POSITIVE")


def test_dec2hex_of_minus_one_is_TEN_Fs_and_not_eight() raises:
    """The render side of the same rule. A 32-bit kernel emits `FFFFFFFF`,
    which is a well-formed hex string that `HEX2DEC` reads back as
    4294967295 — the round trip does NOT catch it, which is why the literal is
    asserted."""
    _txt(xl_dec2hex(_n1(-1.0)), String("FFFFFFFFFF"),
         "★ DEC2HEX(-1) is TEN F's — 40 bits, not 32")
    _txt(xl_dec2oct(_n1(-1.0)), String("7777777777"),
         "DEC2OCT(-1) is TEN 7's — 30 bits")
    _txt(xl_dec2bin(_n1(-1.0)), String("1111111111"),
         "DEC2BIN(-1) is TEN 1's — 10 bits")


def test_places_is_IGNORED_when_the_number_is_NEGATIVE() raises:
    """⛔ EXCEL'S RULE, AND THE WRONG KERNEL RETURNS NO ERROR. `DEC2BIN(-9,4)`
    is the full-width `1111110111`; a kernel that honours `places` there
    returns a four-character string that is well-formed and wrong.

    ⚠ THE POSITIVE HALF IS ASSERTED BESIDE IT so the test cannot pass by
    ignoring `places` altogether."""
    _txt(xl_dec2bin(_sn(String("-9"), 4.0)), String("1111110111"),
         "★ places IGNORED for a negative — full width")
    _txt(xl_dec2bin(_sn(String("9"), 4.0)), String("1001"),
         "★ AND HONOURED for a positive — 1001, zero-padded to 4")
    _txt(xl_dec2bin(_sn(String("9"), 8.0)), String("00001001"),
         "places PADS with leading zeros")


def test_the_dec2_range_boundaries_are_EXACT_and_one_past_is_NUM() raises:
    """[-512, 511] for binary, [-2^29, 2^29-1] for octal, [-2^39, 2^39-1] for
    hex — asserted AT the boundary and ONE PAST it on both sides."""
    _txt(xl_dec2bin(_n1(511.0)), String("111111111"), "511 is the top")
    _err(xl_dec2bin(_n1(512.0)), XL_ERR_NUM, "512 leaves the binary range")
    _txt(xl_dec2bin(_n1(-512.0)), String("1000000000"), "-512 is the bottom")
    _err(xl_dec2bin(_n1(-513.0)), XL_ERR_NUM, "-513 leaves the binary range")
    _err(xl_dec2oct(_n1(536870912.0)), XL_ERR_NUM, "2^29 leaves octal")
    _txt(xl_dec2oct(_n1(536870911.0)), String("3777777777"), "2^29-1 is the top")
    _err(xl_dec2hex(_n1(549755813888.0)), XL_ERR_NUM, "2^39 leaves hex")


def test_the_cross_conversions_range_check_the_DESTINATION() raises:
    """⛔ NARROWING IS THE CASE THAT BREAKS. `HEX2BIN` reads a 40-bit literal
    and writes a 10-bit one, so the check is on the DESTINATION width: -512 is
    the last value it can express and -513 is `#NUM!`. A kernel that checks
    only the SOURCE answers a truncated string for both."""
    _txt(xl_hex2bin(_s1(String("FFFFFFFE00"))), String("1000000000"),
         "★ -512 through the hex door is the widest NEGATIVE binary")
    _err(xl_hex2bin(_s1(String("FFFFFFFDFF"))), XL_ERR_NUM,
         "⛔ -513 has no 10-bit spelling — DESTINATION range")
    _err(xl_oct2bin(_s1(String("2000"))), XL_ERR_NUM,
         "1024 is a fine octal number and no binary one")
    _txt(xl_oct2bin(_s1(String("777"))), String("111111111"),
         "511 converts through both doors")
    _txt(xl_bin2hex(_s1(String("1111111111"))), String("FFFFFFFFFF"),
         "★ -1 WIDENS: ten binary 1's become ten hex F's, not two")
    _txt(xl_bin2oct(_s1(String("1111111111"))), String("7777777777"),
         "-1 widens into octal the same way")
    _txt(xl_hex2oct(_s1(String("1F"))), String("37"), "31 = 0o37")


def test_a_literal_that_is_not_in_the_base_is_NUM_and_a_long_one_too() raises:
    """Eleven digits is `#NUM!` even when every digit is legal — the ten-
    character limit is part of the format, not an incidental buffer size."""
    _err(xl_bin2dec(_s1(String("2"))), XL_ERR_NUM, "2 is not a binary digit")
    _err(xl_oct2dec(_s1(String("8"))), XL_ERR_NUM, "8 is not an octal digit")
    _err(xl_hex2dec(_s1(String("G"))), XL_ERR_NUM, "G is not a hex digit")
    _err(xl_bin2dec(_s1(String("11111111111"))), XL_ERR_NUM,
         "ELEVEN binary digits — one past the format")
    _err(xl_hex2dec(_s1(String("FFFFFFFFFFF"))), XL_ERR_NUM,
         "ELEVEN hex digits — one past the format")
    _exact(xl_bin2dec(_n1(1100100.0)), 100.0,
           "★ A NUMBER COERCES: BIN2DEC(1100100) is 100, via its general format")
    _err(xl_bin2dec(_n1(-1.0)), XL_ERR_NUM,
         "a NEGATIVE number renders a `-`, which is not a base digit")


def test_places_refuses_three_ways_and_two_of_them_are_DIFFERENT_codes() raises:
    """⚠ `#VALUE!` FOR A NON-NUMERIC `places` AND `#NUM!` FOR A NEGATIVE OR
    TOO-SMALL ONE. Microsoft states the two codes separately and they are not
    the same complaint; collapsing them makes the error a lie about where it
    came from."""
    var v = _s1(String("9"))
    v.append(FormulaValue.text_val(String("x")))
    _err(xl_dec2bin(v), XL_ERR_VALUE, "★ non-numeric places is #VALUE!")
    _err(xl_dec2bin(_sn(String("9"), -1.0)), XL_ERR_NUM,
         "★ negative places is #NUM!")
    _err(xl_dec2bin(_sn(String("9"), 3.0)), XL_ERR_NUM,
         "★ places SMALLER than the answer is #NUM!, never a truncation")
    _err(xl_dec2bin(_sn(String("9"), 11.0)), XL_ERR_NUM,
         "⚠ THIS ENGINE'S CONTRACT, NOT MICROSOFT'S: places past the ten-"
         "character format is refused rather than silently widening it")


def test_a_HUGE_argument_answers_NUM_through_every_Int_CONVERSION_SITE() raises:
    """The observable contract at arguments large enough to reach an
    `Int(<Float64>)` conversion, which in Mojo is UNDEFINED outside Int64's
    range.

    ⛔⛔ THIS IS A CONTRACT PIN, NOT A MUTATION PROOF, AND THE ATTEMPT TO MAKE
    IT ONE IS THE FINDING. **The `_INT_EXACT` guard in `_trunc` has NO
    externally observable effect on this kernel set.** Three candidate
    discriminators were written and all three stayed GREEN with the guard
    lowered from 2^53 to 2^32 (measured, BAZEL_RC=0 each time):

      1. `DEC2BIN(1e300)` etc. — the poison value an undefined conversion
         produces (`-9223372036854775808`) fails the SAME range check the
         guard would have failed, so both implementations answer `#NUM!`.
      2. `DEC2HEX(2^39-1)` — an integer either side of any threshold.
      3. `DEC2HEX(2^32 + 0.5)` — the leaked 0.5 becomes `Int(0.5)` = 0 in
         `_render_base`'s digit loop, which is the digit the truncated value
         produces anyway. Identical string.

    ⇒ EVERY PATH WHERE THE GUARD DIFFERS IS RE-ABSORBED BY A DOWNSTREAM
    TRUNCATION OR RANGE CHECK. So the guard is NOT justified by a red here and
    must not be reported as if it were; it is justified by the MEASUREMENT in
    `FormulaValue.number`'s docstring — at `--optimization-level 1` the
    optimiser folded `Float64(Int64(v)) == v` to TRUE for a non-finite `v` and
    SEVEN kernels printed that poison integer as a plausible finite NEGATIVE
    answer with `ISNUMBER` TRUE. UNDEFINED BEHAVIOUR IS NOT OBSERVABLE FROM
    THE OUTSIDE, which is exactly why it has to be removed at the source
    rather than tested for at the boundary.

    ⚠ WHAT THE CELLS BELOW ARE WORTH: they pin the ANSWER at each of the three
    conversion sites, so a future refactor that changes it reds. That is a
    regression guard and it is real; it is simply not evidence about the
    guard."""
    _err(xl_dec2bin(_n1(1.0e300)), XL_ERR_NUM,
         "a huge NUMBER leaves the binary range — #NUM!")
    _err(xl_dec2hex(_n1(1.0e300)), XL_ERR_NUM, "the same through the hex door")
    _err(xl_dec2hex(_n1(-1.0e300)), XL_ERR_NUM, "and from the negative side")
    _err(xl_dec2bin(_sn(String("9"), 1.0e300)), XL_ERR_NUM,
         "a huge `places` is #NUM! — the clamp refuses before converting")
    _err(xl_bitlshift(_n2(4.0, 1.0e300)), XL_ERR_NUM,
         "a huge `shift_amount` is bounded as a FLOAT, before any Int()")
    _err(xl_bitrshift(_n2(4.0, -1.0e300)), XL_ERR_NUM, "and from below")
    _err(xl_bitand(_n2(1.0e300, 1.0)), XL_ERR_NUM,
         "a huge bitwise operand is out of the 2^48 domain")
    _txt(xl_dec2hex(_n1(549755813887.0)), String("7FFFFFFFFF"),
         "2^39-1 — the largest hex-representable positive — still ANSWERS, so "
         "no guard above passes by refusing everything large")
    _txt(xl_dec2hex(_n1(4294967296.5)), String("100000000"),
         "a NON-INTEGRAL argument still TRUNCATES")


def test_zero_renders_as_zero_in_every_base() raises:
    """The one value with no digits to emit. A `while u >= 1` loop writes the
    empty string for it unless it is special-cased."""
    _txt(xl_dec2bin(_n1(0.0)), String("0"), "DEC2BIN(0)")
    _txt(xl_dec2oct(_n1(0.0)), String("0"), "DEC2OCT(0)")
    _txt(xl_dec2hex(_n1(0.0)), String("0"), "DEC2HEX(0)")
    _exact(xl_hex2dec(_s1(String("0"))), 0.0, "HEX2DEC(0)")


def test_the_number_argument_TRUNCATES_toward_zero() raises:
    """⛔ TRUNCATE, NOT FLOOR. `floor(-9.9)` is -10 and truncation gives -9;
    the two agree over the whole positive half, which is the half a fixture
    covers."""
    _txt(xl_dec2bin(_n1(9.9)), String("1001"), "9.9 truncates to 9")
    _txt(xl_dec2bin(_n1(-9.9)), String("1111110111"),
         "★ -9.9 truncates to -9, not floors to -10 (which is 1111110110)")


# =============================================================================
# ★ THE BITWISE FAMILY — THE DOMAIN IS 2^48.
# =============================================================================
def test_the_bitwise_domain_is_2_to_the_48_and_one_past_is_NUM() raises:
    """⛔ NOT 2^32 AND NOT 2^53. 2^48-1 = 281474976710655 is admitted and 2^48
    is `#NUM!`; a 32-bit domain refuses the first and a 2^53 one accepts the
    second, and both agree with this kernel on every small operand."""
    _exact(xl_bitand(_n2(281474976710655.0, 281474976710655.0)),
           281474976710655.0, "★ 2^48-1 is INSIDE the domain")
    _err(xl_bitand(_n2(281474976710656.0, 1.0)), XL_ERR_NUM,
         "⛔ 2^48 is one past it")
    _exact(xl_bitand(_n2(5.0, 3.0)), 1.0,
           "★ THE BLIND CELL: every candidate domain answers 1 here")
    _exact(xl_bitor(_n2(5.0, 3.0)), 7.0, "BITOR")
    _exact(xl_bitxor(_n2(5.0, 3.0)), 6.0, "BITXOR")


def test_the_bitwise_refusals_use_TWO_different_codes() raises:
    """A DOMAIN failure is `#NUM!` and a COERCION failure is `#VALUE!`."""
    _err(xl_bitand(_n2(-1.0, 1.0)), XL_ERR_NUM, "negative operand is #NUM!")
    _err(xl_bitand(_n2(1.5, 1.0)), XL_ERR_NUM,
         "★ a NON-INTEGER operand is #NUM! — never truncated")
    var v = _s1(String("x"))
    v.append(FormulaValue.number(1.0))
    _err(xl_bitand(v), XL_ERR_VALUE, "★ non-numeric TEXT is #VALUE!")


def test_the_shift_RESULT_is_range_checked_too() raises:
    """⛔ THE INPUT CHECK IS NOT ENOUGH. `BITLSHIFT(1,48)` has a legal operand
    and a legal shift and an ILLEGAL result, so it is `#NUM!`; `BITLSHIFT(1,47)`
    is 140737488355328. A kernel that checks only its inputs answers 2^48."""
    _exact(xl_bitlshift(_n2(1.0, 47.0)), 140737488355328.0,
           "★ 2^47 is the largest power of two in the domain")
    _err(xl_bitlshift(_n2(1.0, 48.0)), XL_ERR_NUM,
         "⛔ the RESULT leaves the domain, so #NUM!")
    _err(xl_bitlshift(_n2(281474976710655.0, 1.0)), XL_ERR_NUM,
         "2^48-1 shifted once also leaves it")
    _err(xl_bitlshift(_n2(1.0, 54.0)), XL_ERR_NUM,
         "|shift| > 53 is #NUM! on the SHIFT, before the result is computed")


def test_a_NEGATIVE_shift_shifts_the_other_way() raises:
    """⛔ 52, NOT 13. `BITRSHIFT(13,-2)` is `BITLSHIFT(13,2)`. A kernel that
    clamps a negative shift to zero returns the operand unchanged, which is
    right for every non-negative shift anybody writes."""
    _exact(xl_bitrshift(_n2(13.0, -2.0)), 52.0,
           "★ BITRSHIFT with a NEGATIVE shift shifts LEFT")
    _exact(xl_bitlshift(_n2(13.0, -2.0)), 3.0,
           "★ and BITLSHIFT with a negative shift shifts RIGHT: 13>>2 = 3")
    _exact(xl_bitrshift(_n2(13.0, 2.0)), 3.0, "the ordinary direction")
    _exact(xl_bitrshift(_n2(13.0, 0.0)), 13.0, "a zero shift is the identity")
    _exact(xl_bitrshift(_n2(281474976710655.0, 53.0)), 0.0,
           "shifting right past the width is 0, not #NUM!")


# =============================================================================
# ★ DELTA / GESTEP.
# =============================================================================
def test_gestep_is_an_ORDERED_compare_and_not_a_magnitude_one() raises:
    """⛔ `GESTEP(-4,-5)` IS **1**: -4 >= -5. A kernel comparing magnitudes
    answers 0 — and agrees with this one on every input where both arguments
    are non-negative, which is the whole region a hand-written fixture has."""
    _exact(xl_gestep(_n2(-4.0, -5.0)), 1.0,
           "★ -4 >= -5 — the ORDERED compare")
    _exact(xl_gestep(_n2(-5.0, -4.0)), 0.0, "and the other way is 0")
    _exact(xl_gestep(_n2(5.0, 4.0)), 1.0,
           "★ THE BLIND CELL: a magnitude compare agrees here")
    _exact(xl_gestep(_n1(-1.0)), 0.0, "step defaults to 0")
    _exact(xl_gestep(_n2(4.0, 4.0)), 1.0, "GE, not GT — equality is 1")


def test_delta_defaults_its_second_argument_to_zero() raises:
    _exact(xl_delta(_n2(5.0, 5.0)), 1.0, "equal")
    _exact(xl_delta(_n2(5.0, 4.0)), 0.0, "unequal")
    _exact(xl_delta(_n1(0.0)), 1.0, "★ DELTA(0) is 1 — number2 defaults to 0")
    _exact(xl_delta(_n1(0.5)), 0.0, "DELTA(0.5) is 0")


# =============================================================================
# ★ THE ERROR FUNCTION.
# =============================================================================
def test_ERF_takes_an_UPPER_limit_and_ERF_PRECISE_does_not() raises:
    """⛔⛔ THE TWO-ARGUMENT FORM IS THE WHOLE POINT OF THE PAIR. `ERF(1,2)` is
    erf(2)-erf(1) = 0.152621472069238; a kernel that drops the second argument
    answers erf(1) = 0.842700792949715, which is a perfectly plausible number
    in [0,1] and is what `ERF.PRECISE(1)` correctly returns.

    ⚠ ASSERTED AS A PAIR WITH THE BLIND CELL: at ONE argument the two names
    are THE SAME NUMBER, so a one-argument fixture cannot tell them apart."""
    _close(xl_erf(_n2(1.0, 2.0)), 0.15262147206923793,
           "★ ERF(1,2) is erf(2)-erf(1)")
    _close(xl_erf(_n1(1.0)), 0.8427007929497149, "ERF(1) is erf(1)")
    _close(xl_erf_precise(_n1(1.0)), 0.8427007929497149, "ERF.PRECISE(1)")
    _close(xl_erf(_n1(0.0)), 0.0, "erf(0) is exactly 0")
    # ⭐ the pair must actually DIFFER at the discriminating input.
    var two = xl_erf(_n2(1.0, 2.0))
    var one = xl_erf(_n1(1.0))
    var d = two.num - one.num
    if d < 0.0:
        d = -d
    assert_true(d > 0.5,
                "★ the two forms must be FAR apart at (1,2), or the cell "
                "discriminates nothing")


def test_ERFC_accepts_a_NEGATIVE_argument_and_complements_ERF() raises:
    """⚠ `ERFC(-1)` is 1.842700792949715. Excel before 2010 refused a negative
    argument with `#NUM!`; the modern function does not, and a kernel that kept
    the old guard reds only on the negative half."""
    _close(xl_erfc(_n1(1.0)), 0.15729920705028513, "ERFC(1)")
    _close(xl_erfc(_n1(-1.0)), 1.8427007929497148,
           "★ a NEGATIVE argument is accepted, not #NUM!")
    _close(xl_erfc_precise(_n1(-1.0)), 1.8427007929497148, "ERFC.PRECISE(-1)")
    _close(xl_erfc(_n1(0.0)), 1.0, "erfc(0) is exactly 1")
    # the complement identity, at a point where neither side cancels
    var a = xl_erf(_n1(0.5))
    var b = xl_erfc(_n1(0.5))
    _close(FormulaValue.number(a.num + b.num), 1.0,
           "erf(x) + erfc(x) == 1")


# =============================================================================
# ★★ COMPLEX NUMBERS.
# =============================================================================
def test_COMPLEX_omits_the_coefficient_one_and_a_zero_part() raises:
    """⛔ FOUR STRINGS A NAIVE CONCATENATION GETS WRONG while being right for
    `COMPLEX(3,4)`. `"3+1i"`, `"0+-1i"`, `"3+0i"` and `"0+0i"` are all
    well-formed complex literals this engine would even parse back correctly —
    they are simply not what Excel writes."""
    _txt(xl_complex(_n2(3.0, 4.0)), String("3+4i"),
         "★ THE BLIND CELL: every implementation gets this one right")
    _txt(xl_complex(_n2(3.0, 1.0)), String("3+i"),
         "★ the coefficient 1 is OMITTED — not `3+1i`")
    _txt(xl_complex(_n2(3.0, -1.0)), String("3-i"), "and -1 is just `-`")
    _txt(xl_complex(_n2(0.0, 1.0)), String("i"), "a zero REAL part vanishes")
    _txt(xl_complex(_n2(0.0, -1.0)), String("-i"), "★ COMPLEX(0,-1) is `-i`")
    _txt(xl_complex(_n2(3.0, 0.0)), String("3"),
         "a zero IMAGINARY part vanishes — not `3+0i`")
    _txt(xl_complex(_n2(0.0, 0.0)), String("0"), "and both zero is `0`")
    _txt(xl_complex(_n2(0.0, 4.0)), String("4i"), "a bare coefficient")
    _txt(xl_complex(_n2(3.0, -4.0)), String("3-4i"),
         "a negative coefficient carries its own sign")


def test_the_COMPLEX_suffix_is_i_or_j_and_anything_else_is_VALUE() raises:
    """⚠ `#VALUE!` HERE AND `#NUM!` NEXT DOOR. This is the one argument in the
    category whose complaint is about a TYPE rather than about a malformed
    complex literal, and Microsoft states the two codes differently."""
    var v = _n2(3.0, 4.0)
    v.append(FormulaValue.text_val(String("j")))
    _txt(xl_complex(v), String("3+4j"), "an explicit `j` suffix")
    var w = _n2(3.0, 4.0)
    w.append(FormulaValue.text_val(String("k")))
    _err(xl_complex(w), XL_ERR_VALUE, "★ an unrecognised suffix is #VALUE!")
    var u = _n2(3.0, 4.0)
    u.append(FormulaValue.text_val(String("I")))
    _err(xl_complex(u), XL_ERR_VALUE,
         "★ UPPER-CASE `I` is rejected — Excel requires lower case")


def test_a_malformed_complex_literal_is_NUM_and_NOT_VALUE() raises:
    """⛔ THE ERROR CODE MOST READERS GUESS WRONG. Microsoft states it on every
    consumer: "If inumber is not in the form x+yi or x+yj … returns the #NUM!
    error value". `#VALUE!` is what a text-coercion failure gives, so both are
    reachable and they mean different things."""
    _err(xl_imabs(_s1(String("3+4k"))), XL_ERR_NUM,
         "★ an unrecognised suffix in a LITERAL is #NUM!")
    _err(xl_imreal(_s1(String("3+4"))), XL_ERR_NUM,
         "★ `3+4` has a separator and no suffix — not in the form x+yi")
    _err(xl_imreal(_s1(String("abc"))), XL_ERR_NUM, "plain junk is #NUM!")
    _err(xl_imreal(_s1(String("3+4I"))), XL_ERR_NUM,
         "★ UPPER-CASE `I` is not a suffix")


def test_the_parser_reads_every_documented_SHAPE() raises:
    """`x+yi`, `x`, `yi`, a bare `i`, a signed bare `i`, and — the one that
    breaks a naive separator scan — a coefficient in SCIENTIFIC NOTATION."""
    _exact(xl_imreal(_s1(String("3+4i"))), 3.0, "x+yi: real")
    _exact(xl_imaginary(_s1(String("3+4i"))), 4.0, "x+yi: imaginary")
    _exact(xl_imreal(_s1(String("-3-4i"))), -3.0,
           "★ a LEADING sign is not a separator")
    _exact(xl_imaginary(_s1(String("-3-4i"))), -4.0, "and the tail keeps its")
    _exact(xl_imaginary(_s1(String("i"))), 1.0, "a bare `i` is coefficient 1")
    _exact(xl_imaginary(_s1(String("-i"))), -1.0, "`-i` is -1")
    _exact(xl_imaginary(_s1(String("+i"))), 1.0, "`+i` is 1")
    _exact(xl_imreal(_s1(String("5"))), 5.0, "a purely real literal")
    _exact(xl_imaginary(_s1(String("5"))), 0.0, "with a zero imaginary part")
    _exact(xl_imaginary(_s1(String("4j"))), 4.0, "the `j` spelling")
    _close(xl_imreal(_s1(String("1.5e-3+2i"))), 0.0015,
           "⛔ SCIENTIFIC NOTATION: the `-` after an `e` is NOT the separator")
    _exact(xl_imaginary(_s1(String("1.5e-3+2i"))), 2.0,
           "and the imaginary part survives it")
    _exact(xl_imreal(_n1(-3.0)), -3.0,
           "a NUMBER argument coerces through its general format")


def test_IMARGUMENT_is_atan2_and_the_branch_cut_is_the_finding() raises:
    """⛔⛔ `IMARGUMENT("-1")` IS **pi**. A kernel spelled `atan(b/a)` answers
    **0** — it throws the quadrant away — and agrees with this one everywhere
    the real part is positive, which is the whole first-and-fourth-quadrant
    region a fixture built from `3+4i` covers.

    ⚠ ZERO IS `#DIV/0!` AND NOT `#NUM!`, and it is the only `#DIV/0!` in the
    Engineering category."""
    _close(xl_imargument(_s1(String("-1"))), 3.141592653589793,
           "★ THE BRANCH CUT: arg(-1) is pi, and atan(0/-1) is 0")
    _close(xl_imargument(_s1(String("i"))), 1.5707963267948966,
           "★ arg(i) is pi/2 — atan(1/0) is not even finite")
    _close(xl_imargument(_s1(String("-i"))), -1.5707963267948966,
           "arg(-i) is -pi/2")
    _close(xl_imargument(_s1(String("3+4i"))), 0.9272952180016122,
           "★ THE BLIND CELL: first quadrant, where the quotient form agrees")
    _err(xl_imargument(_s1(String("0"))), XL_ERR_DIV0,
         "★ IMARGUMENT(0) is #DIV/0!, not #NUM!")


def test_IMPRODUCT_subtracts_in_the_real_part() raises:
    """⛔ `(ac - bd)`. `IMPRODUCT("2+3i","2+3i")` is `-5+12i`; a kernel that
    ADDS answers `13+12i`, and both are plausible complex numbers. The
    arithmetic here is EXACT in binary64, so the string is asserted."""
    _txt(xl_improduct(_s2(String("2+3i"), String("2+3i"))), String("-5+12i"),
         "★ the MINUS: -5, where an adding kernel answers 13")
    _txt(xl_imsum(_s2(String("3+4i"), String("1+2i"))), String("4+6i"), "IMSUM")
    _txt(xl_imsub(_s2(String("3+4i"), String("1+2i"))), String("2+2i"), "IMSUB")
    _txt(xl_imdiv(_s2(String("-5+12i"), String("2+3i"))), String("2+3i"),
         "★ IMDIV inverts IMPRODUCT exactly on this pair")
    _txt(xl_imconjugate(_s1(String("3+4i"))), String("3-4i"), "IMCONJUGATE")
    _exact(xl_imabs(_s1(String("3+4i"))), 5.0, "IMABS is the 3-4-5 modulus")
    _err(xl_imdiv(_s2(String("1"), String("0"))), XL_ERR_NUM,
         "★ IMDIV by zero is #NUM! — where IMARGUMENT(0) is #DIV/0!")


def test_the_SUFFIX_rides_through_an_operation_and_MIXING_is_VALUE() raises:
    """⛔ `IMSUM("3+4j","1+2j")` IS `"4+6j"`. A kernel that always emits `i`
    returns the RIGHT COMPLEX NUMBER under the WRONG SPELLING, and passes any
    check that parses its own answer back — which is how this one would have
    shipped.

    ⚠ A PURELY REAL OPERAND STATES NO SPELLING, so `IMSUM("3","4j")` is `"7j"`
    and is NOT a suffix conflict."""
    _txt(xl_imsum(_s2(String("3+4j"), String("1+2j"))), String("4+6j"),
         "★ the `j` spelling RIDES THROUGH")
    _txt(xl_improduct(_s2(String("2+3j"), String("2+3j"))), String("-5+12j"),
         "and through a product")
    _txt(xl_imsum(_s2(String("3"), String("4j"))), String("3+4j"),
         "★ a purely REAL operand carries no spelling — not a conflict")
    _err(xl_imsum(_s2(String("3+4i"), String("1+2j"))), XL_ERR_VALUE,
         "★ MIXED suffixes are #VALUE!")
    _err(xl_imsub(_s2(String("3+4i"), String("1+2j"))), XL_ERR_VALUE,
         "and the binary forms refuse the same way")


def test_the_variadic_pair_are_variadic_and_their_identities_are_right() raises:
    """`IMSUM` starts at 0 and `IMPRODUCT` at 1. A product seeded with 0
    answers 0 for every input."""
    var three = _s2(String("1+i"), String("2+2i"))
    three.append(FormulaValue.text_val(String("3+3i")))
    _txt(xl_imsum(three), String("6+6i"), "IMSUM over THREE arguments")
    var t2 = _s2(String("2"), String("3"))
    t2.append(FormulaValue.text_val(String("4")))
    _txt(xl_improduct(t2), String("24"),
         "★ IMPRODUCT over three — a 0 seed would answer 0")
    _txt(xl_imsum(_s1(String("3+4i"))), String("3+4i"), "IMSUM of one")


def test_the_transcendental_complex_functions_at_a_known_point() raises:
    """Graded by PARSING THE ANSWER BACK, because the coefficients are not
    exactly representable. Each point is one where the formula's two terms are
    both non-zero, so a dropped term is visible."""
    # e^(i*pi) = -1 — the identity, and the imaginary part is ~1.2e-16.
    _cx_close(xl_imexp(_s1(String("3.141592653589793i"))), -1.0, 0.0,
              "★ IMEXP(i*pi) is -1")
    _cx_close(xl_imexp(_s1(String("1"))), 2.718281828459045, 0.0, "IMEXP(1)")
    # sin(1+i) = sin1 cosh1 + i cos1 sinh1
    _cx_close(xl_imsin(_s1(String("1+i"))), 1.2984575814159773,
              0.6349639147847361, "★ IMSIN(1+i) — both terms non-zero")
    # cos(1+i) = cos1 cosh1 - i sin1 sinh1 — the MINUS is the discriminator
    _cx_close(xl_imcos(_s1(String("1+i"))), 0.8337300251311491,
              -0.9888977057628651,
              "★ IMCOS(1+i) — the imaginary part is NEGATIVE")
    _cx_close(xl_imsinh(_s1(String("1+i"))), 0.6349639147847361,
              1.2984575814159773,
              "★ IMSINH(1+i) is IMSIN(1+i) with its parts SWAPPED")
    _cx_close(xl_imcosh(_s1(String("1+i"))), 0.8337300251311491,
              0.9888977057628651,
              "★ IMCOSH(1+i) — PLUS, where the circular cosine takes a minus")
    _cx_close(xl_imln(_s1(String("i"))), 0.0, 1.5707963267948966,
              "★ IMLN(i) is i*pi/2 — the branch again")
    _cx_close(xl_imlog10(_s1(String("100"))), 2.0, 0.0, "IMLOG10(100)")
    _cx_close(xl_imlog2(_s1(String("8"))), 3.0, 0.0, "IMLOG2(8)")
    _err(xl_imln(_s1(String("0"))), XL_ERR_NUM, "IMLN(0) is #NUM!")


def test_IMPOWER_and_IMSQRT_share_one_branch() raises:
    """`IMSQRT` is `IMPOWER(z, 0.5)` and both take the PRINCIPAL branch. The
    discriminating input is a NEGATIVE real, whose square root is on the
    imaginary axis — a real-only kernel answers `#NUM!` there."""
    _cx_close(xl_imsqrt(_s1(String("-4"))), 0.0, 2.0,
              "★ sqrt(-4) is 2i — the principal branch")
    _cx_close(xl_impower(_s2(String("-4"), String("0.5"))), 0.0, 2.0,
              "IMPOWER(-4, 0.5) is the same number")
    _cx_close(xl_impower(_s2(String("2+3i"), String("2"))), -5.0, 12.0,
              "★ IMPOWER(z,2) agrees with IMPRODUCT(z,z)")
    _cx_close(xl_imsqrt(_s1(String("4"))), 2.0, 0.0,
              "★ THE BLIND CELL: a positive real, where a real-only kernel "
              "agrees")
    _err(xl_impower(_s2(String("0"), String("-1"))), XL_ERR_NUM,
         "0 to a negative power is #NUM!")


def test_the_reciprocal_family_is_the_RECIPROCAL_and_not_the_inverse() raises:
    """⛔ `IMSEC` is `1/IMCOS`, NOT `arccos`. The two are different functions
    that both answer a complex number for the same input."""
    _cx_close(xl_imsec(_s1(String("1+i"))), 0.4983370305551869,
              0.591083841721045, "★ IMSEC(1+i) is 1/IMCOS(1+i)")
    _cx_close(xl_imcsc(_s1(String("1+i"))), 0.6215180171704285,
              -0.30393100162842646, "IMCSC(1+i) is 1/IMSIN(1+i)")
    _cx_close(xl_imsech(_s1(String("1+i"))), 0.4983370305551869,
              -0.591083841721045, "IMSECH(1+i) is 1/IMCOSH(1+i)")
    _cx_close(xl_imcsch(_s1(String("1+i"))), 0.3039310016284264,
              -0.6215180171704287, "IMCSCH(1+i) is 1/IMSINH(1+i)")
    _cx_close(xl_imtan(_s1(String("1+i"))), 0.2717525853195117,
              1.0839233273386946, "IMTAN(1+i) is IMSIN/IMCOS")
    _cx_close(xl_imcot(_s1(String("1+i"))), 0.21762156185440268,
              -0.8680141428959249, "IMCOT(1+i) is IMCOS/IMSIN")


# =============================================================================
# ★ THE ERROR ALGEBRA — one class, asserted once per shape.
# =============================================================================
def test_every_engineering_kernel_propagates_the_LEFTMOST_error() raises:
    """`ERRH_PROPAGATE_DOMINANT`: an error argument returns ITSELF, and the
    LEFTMOST one wins. Asserted at each argument SHAPE rather than per name —
    the shapes are what differ."""
    var e = FormulaValue.error(XL_ERR_DIV0)
    var a = List[FormulaValue]()
    a.append(e.copy())
    _err(xl_dec2bin(a), XL_ERR_DIV0, "DEC2BIN of an error")
    _err(xl_hex2dec(a), XL_ERR_DIV0, "HEX2DEC of an error")
    _err(xl_imabs(a), XL_ERR_DIV0, "IMABS of an error")
    _err(xl_erf(a), XL_ERR_DIV0, "ERF of an error")
    var b = List[FormulaValue]()
    b.append(e.copy())
    b.append(FormulaValue.number(1.0))
    _err(xl_bitand(b), XL_ERR_DIV0, "BITAND with the error FIRST")
    var c = List[FormulaValue]()
    c.append(FormulaValue.number(1.0))
    c.append(e.copy())
    _err(xl_bitand(c), XL_ERR_DIV0,
         "★ an error in a LATER argument still stops the call")
    var d = List[FormulaValue]()
    d.append(FormulaValue.text_val(String("3+4i")))
    d.append(e.copy())
    _err(xl_imsum(d), XL_ERR_DIV0, "IMSUM stops at the error operand")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
