# =============================================================================
# test_xl_scalar_kernels.mojo — ★ THE ASSERTIONS THAT COULD NOT HAVE EXISTED
#                                 IF THESE KERNELS HAD BEEN WRITTEN WHERE THEY
#                                 "BELONG".
# =============================================================================
#
# ⛔ EVERY TEST BELOW IS ABOUT A CASE WHERE THE OBVIOUS IMPLEMENTATION IS
# WRONG. That is the selection rule, not "one test per function":
#
#   ROUND      half AWAY from zero, not the IEEE half-to-EVEN of `round()`
#   INT        FLOOR, not truncation — the two differ only on negatives
#   MOD        takes the DIVISOR's sign, not C `fmod`'s dividend sign
#   ROUNDUP    away from zero, which is `floor` on the negative side
#   CEILING    six sign cases, one of which is `#NUM!`
#   PRODUCT    skips blanks (coercing them would make any product 0)
#   FIND       case-SENSITIVE where SEARCH is case-INSENSITIVE
#   EXACT      case-SENSITIVE, because Excel's own `=` on text is not
#   PROPER     word boundary is any NON-LETTER, so `2nd` -> `2Nd`
#   ISNUMBER   a TYPE test, not a coercibility test
#   ISBLANK    FALSE for `""`
#   ISERROR    MANUAL error class — it must not propagate its argument
#   XOR        PARITY, not "exactly one" (they agree at arity 2)
#
# ⚠ NO `EngineContext`, NO FILE, NO FIXTURE — this file is welded to
# `komira_xl_plan`, which downstream bindings link, so a slow or flaky member
# here would block everything that links it. Every
# assertion is a pure function of a `FormulaValue`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.plan.excel_error_code import (
    XL_ERR_DIV0,
    XL_ERR_NA,
    XL_ERR_NUM,
    XL_ERR_VALUE,
)

from komira_xl_plan.formula_value import FormulaValue
from komira_xl_plan.xl_date_serial import _date_to_serial
from komira_xl_plan.xl_scalar_math import (
    _half_away_from_zero,
    xl_round,
    xl_roundup,
    xl_rounddown,
    xl_abs,
    xl_int,
    xl_sign,
    xl_mod,
    xl_power,
    xl_sqrt,
    xl_ceiling,
    xl_floor,
    xl_product,
)
from komira_xl_plan.xl_scalar_exact import (
    xl_fact,
    xl_factdouble,
    xl_combin,
    xl_combina,
    xl_sumsq,
    xl_base,
    xl_decimal,
    xl_ceiling_precise,
    xl_floor_precise,
    xl_multinomial,
    xl_iso_ceiling,
    xl_roman,
    xl_arabic,
)
from komira_xl_plan.xl_scalar_text import (
    xl_concatenate,
    xl_unichar,
    xl_unicode,
    xl_rept,
    xl_char,
    xl_code,
    xl_clean,
    xl_t,
    xl_n,
    xl_upper,
    xl_lower,
    xl_proper,
    xl_find,
    xl_search,
    xl_replace,
    xl_exact,
    xl_value,
    xl_char_count,
    xl_substr_chars,
    xl_textbefore,
    xl_textafter,
    xl_valuetotext,
)
from komira_xl_plan.xl_scalar_ref import (
    xl_address,
    xl_hyperlink,
)
from komira_xl_plan.xl_scalar_numeric import (
    xl_exp,
    xl_ln,
    xl_log,
    xl_log10,
    xl_pi,
    xl_trunc,
    xl_even,
    xl_odd,
    xl_quotient,
    xl_sin,
    xl_cos,
    xl_tan,
    xl_asin,
    xl_acos,
    xl_atan,
    xl_atan2,
    xl_sinh,
    xl_cosh,
    xl_tanh,
    xl_degrees,
    xl_radians,
    xl_isodd,
    xl_iseven,
    xl_gcd,
    xl_lcm,
    xl_mround,
    xl_sec,
    xl_csc,
    xl_cot,
    xl_sech,
    xl_csch,
    xl_coth,
    xl_acot,
    xl_acoth,
    xl_asinh,
    xl_acosh,
    xl_atanh,
    xl_sqrtpi,
)
from komira_xl_plan.xl_scalar_date import (
    xl_isoweeknum,
    xl_time,
    xl_hour,
    xl_minute,
    xl_second,
    xl_days360,
    xl_timevalue,
    xl_datevalue,
)
from komira_xl_plan.xl_scalar_info import (
    xl_choose,
    xl_isnontext,
    xl_type,
    xl_error_type,
    xl_true,
    xl_false,
    xl_iserr,
    xl_isblank,
    xl_isnumber,
    xl_istext,
    xl_islogical,
    xl_iserror,
    xl_isna,
    xl_na,
    xl_xor,
)


# =============================================================================
# Argument helpers — a kernel takes a `List[FormulaValue]`.
# =============================================================================
def _n(v: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(v))
    return a^


def _nn(a0: Float64, a1: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    a.append(FormulaValue.number(a1))
    return a^


def _t(v: String) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(v))
    return a^


def _nnn(a0: Float64, a1: Float64, a2: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(a0))
    a.append(FormulaValue.number(a1))
    a.append(FormulaValue.number(a2))
    return a^


def _time3(h: Float64, m: Float64, sec: Float64) raises -> FormulaValue:
    """`TIME(h, m, s)` over three numeric arguments — the fixture the whole
    time-of-day family is built on."""
    return xl_time(_nnn(h, m, sec))


def _tn(t0: String, n1: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(t0))
    a.append(FormulaValue.number(n1))
    return a^


def _serial(y: Int, m: Int, d: Int) raises -> Int:
    """A calendar date as an Excel serial, via the same builder `DATE` uses.

    ⚠ THE ISO-WEEK TESTS NAME DATES, NOT SERIALS, ON PURPOSE. A hand-computed
    serial in an assertion is a second implementation of the thing under test,
    and the two would be wrong together."""
    return _date_to_serial(y, m, d)


def _time_sec(sec: Float64) raises -> FormulaValue:
    """`SECOND(TIME(0, 0, sec))` — the round trip that the rounding guards."""
    return xl_second(_n(_time3(0.0, 0.0, sec).num))


def _tt(a0: String, a1: String) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(a0))
    a.append(FormulaValue.text_val(a1))
    return a^


def _assert_text(r: FormulaValue, want: String, why: String) raises:
    """A TEXT value equal to `want`.

    ⚠ IT ASSERTS THE **KIND** FIRST, AND THAT IS NOT A FORMALITY. `ROMAN` is
    the only kernel here that returns TEXT from NUMERIC arguments, so a kernel
    that answered a NUMBER would be compared through `.text` — which is the
    EMPTY STRING on a number — and the row would pass for any `want` that is
    also empty. `ROMAN(0)` legitimately IS the empty string, so without the
    kind check that cell cannot tell a working ROMAN from one that returns 0."""
    assert_true(
        r.is_text(),
        why + " — expected TEXT, got `" + r.render() + "`",
    )
    assert_equal(r.text, want, why)


def _assert_num(r: FormulaValue, want: Float64, why: String) raises:
    assert_true(
        r.is_number(),
        why + " — expected a NUMBER, got `" + r.render() + "`",
    )
    assert_equal(r.num, want, why)


def _assert_close(r: FormulaValue, want: Float64, why: String) raises:
    """A NUMBER equal to `want` to within 1e-12 ABSOLUTE.

    ⚠⚠ IT EXISTS FOR EXACTLY ONE FAMILY AND IS NOT A GENERAL LOOSENING. Every
    other assertion in this file is EXACT, deliberately: `ROUND`, `MOD`,
    `QUOTIENT`, `TIME` and the whole integer-shaping family compute values that
    ARE exactly representable, and an epsilon there would hide a real defect.

    ★ THE TRANSCENDENTALS ARE DIFFERENT, AND THE MEASURED CASE IS
    `SIN(RADIANS(30))`, WHICH IS **0.49999999999999994** AND NOT 0.5. Two
    correctly-rounded libm calls compose to something one ulp below the exact
    answer, and no kernel work closes that. ⚠ EXCEL PRINTS 0.5 FOR IT — its
    display renders 15 significant decimal digits, so the same binary64 value
    looks exact in a sheet. The same class of divergence `_round_note` already
    records for `ROUND(1.005, 2)` (⚠ IT SAID `ROUND(2.675, 2)` UNTIL
    2026-09-14; measured, that input AGREES with Excel at 2.68).

    ⛔ AND AN EXACT ASSERTION HERE WOULD BE BRITTLE FOR A SECOND REASON: the
    last bit of a libm result is not guaranteed identical between the macOS
    developer boxes and linux hosts."""
    assert_true(r.is_number(), why + " (expected a NUMBER)")
    var d = r.num - want
    if d < 0.0:
        d = -d
    assert_true(
        d < 1e-12,
        why + " — got " + String(r.num) + ", want " + String(want) + " +/- 1e-12",
    )


def _assert_err(r: FormulaValue, code: UInt8, why: String) raises:
    assert_true(
        r.is_error(), why + " — expected an ERROR, got `" + r.render() + "`"
    )
    assert_equal(Int(r.error_code), Int(code), why)


# =============================================================================
# ★★ ROUND — half AWAY from zero
# =============================================================================


def test_round_is_half_AWAY_from_zero_and_not_half_to_even() raises:
    """★ THE TWO VALUES THAT SEPARATE THE RULES. IEEE half-to-even — which is
    what a language `round()` gives you — answers 2 for 2.5 and 0 for 0.5.
    Excel answers 3 and 1. Testing only 1.5 (where both rules give 2) or 2.4
    would be green under the wrong implementation."""
    _assert_num(xl_round(_nn(2.5, 0.0)), 3.0, "ROUND(2.5,0) is 3 in Excel; 2 under half-to-even")
    _assert_num(xl_round(_nn(0.5, 0.0)), 1.0, "ROUND(0.5,0) is 1 in Excel; 0 under half-to-even")
    _assert_num(xl_round(_nn(1.5, 0.0)), 2.0, "the value both rules agree on")
    _assert_num(xl_round(_nn(-2.5, 0.0)), -3.0, "away from zero on the negative side too")


def test_round_digits_work_in_both_directions() raises:
    """A positive digit count rounds to the right of the decimal point, a
    NEGATIVE one to the left. `_pow10` handles both, and a sign bug there is
    invisible at digits=0 — which is every other test in this section."""
    _assert_num(xl_round(_nn(3.14159, 2.0)), 3.14, "ROUND to 2 places")
    _assert_num(xl_round(_nn(1234.5, -2.0)), 1200.0, "ROUND to the hundreds")
    _assert_num(xl_round(_n(2.7)), 3.0, "the digits argument defaults to 0")


def test_roundup_and_rounddown_are_MAGNITUDE_directions_not_ceil_and_floor() raises:
    """★ THE NEGATIVE SIDE IS THE WHOLE TEST. On positives ROUNDUP is `ceil`
    and ROUNDDOWN is `floor`, so a suite of positive numbers cannot tell the
    right implementation from the wrong one. Excel's "up" means "in
    magnitude": ROUNDUP(-1.1) is -2, which is `floor`."""
    _assert_num(xl_roundup(_nn(1.1, 0.0)), 2.0, "ROUNDUP(1.1)")
    _assert_num(xl_roundup(_nn(-1.1, 0.0)), -2.0, "★ ROUNDUP(-1.1) is -2, not -1")
    _assert_num(xl_rounddown(_nn(1.9, 0.0)), 1.0, "ROUNDDOWN(1.9)")
    _assert_num(xl_rounddown(_nn(-1.9, 0.0)), -1.0, "★ ROUNDDOWN(-1.9) is -1, not -2")


# =============================================================================
# ★★ INT — FLOOR, not truncation
# =============================================================================


def test_int_FLOORS_and_the_control_is_rounddown_which_truncates() raises:
    """★ THE PAIR IS THE ASSERTION. `INT(-3.5)` is -4 and `ROUNDDOWN(-3.5,0)`
    is -3, over the SAME input. A truncating INT would make the two equal, and
    no single-function test can see that."""
    _assert_num(xl_int(_n(3.9)), 3.0, "INT(3.9)")
    _assert_num(xl_int(_n(-3.5)), -4.0, "★ INT FLOORS: INT(-3.5) is -4")
    _assert_num(
        xl_rounddown(_nn(-3.5, 0.0)),
        -3.0,
        "★ THE CONTROL: ROUNDDOWN truncates, so it answers -3 where INT"
        " answers -4. If these two ever agree on a negative, INT has stopped"
        " flooring",
    )


# =============================================================================
# ★★ MOD — the DIVISOR's sign
# =============================================================================


def test_mod_takes_the_DIVISOR_sign_not_the_dividend_sign() raises:
    """★ C's `fmod(-3,2)` is -1; Excel's `MOD(-3,2)` is 1. The two disagree
    only when the operands' signs differ, so an all-positive suite is blind."""
    _assert_num(xl_mod(_nn(3.0, 2.0)), 1.0, "the case both rules agree on")
    _assert_num(xl_mod(_nn(-3.0, 2.0)), 1.0, "★ MOD(-3,2) is 1 in Excel, -1 in C")
    _assert_num(xl_mod(_nn(3.0, -2.0)), -1.0, "★ MOD(3,-2) is -1 in Excel, 1 in C")
    _assert_num(xl_mod(_nn(-3.0, -2.0)), -1.0, "both negative")


def test_mod_by_zero_is_div0() raises:
    _assert_err(xl_mod(_nn(3.0, 0.0)), XL_ERR_DIV0, "MOD(x,0)")


# =============================================================================
# POWER / SQRT / ABS / SIGN
# =============================================================================


def test_power_and_its_two_error_cases() raises:
    """`POWER(0,-1)` is a division by zero in disguise; a NEGATIVE base with a
    NON-INTEGER exponent has no real answer and `**` would return NaN, which
    travels as a number through every comparison above it."""
    _assert_num(xl_power(_nn(2.0, 10.0)), 1024.0, "POWER(2,10)")
    _assert_num(xl_power(_nn(-2.0, 3.0)), -8.0, "an INTEGER exponent on a negative base is fine")
    _assert_err(xl_power(_nn(0.0, -1.0)), XL_ERR_DIV0, "POWER(0,-1)")
    _assert_err(xl_power(_nn(-8.0, 0.5)), XL_ERR_NUM, "★ a fractional exponent on a negative base is #NUM!, never NaN")


def test_sqrt_of_a_negative_is_NUM_and_not_nan() raises:
    _assert_num(xl_sqrt(_n(9.0)), 3.0, "SQRT(9)")
    _assert_err(xl_sqrt(_n(-1.0)), XL_ERR_NUM, "★ SQRT(-1) must not be NaN")
    _assert_num(
        xl_sqrt(_n(2.0)), 1.4142135623730951,
        "★ SQRT(2) — a kernel answering x/3 gives 0.667 here and 3 at 9",
    )


def test_abs_and_sign() raises:
    _assert_num(xl_abs(_n(-3.5)), 3.5, "ABS of a negative")
    _assert_num(
        xl_abs(_n(3.5)), 3.5,
        "★ ABS of a POSITIVE is unchanged — a NEGATING kernel answers -3.5",
    )
    _assert_num(xl_abs(_n(0.0)), 0.0, "ABS(0) is 0")
    _assert_num(xl_sign(_n(-3.0)), -1.0, "SIGN of a negative")
    _assert_num(xl_sign(_n(0.0)), 0.0, "SIGN of zero is 0, not 1")
    _assert_num(xl_sign(_n(3.0)), 1.0, "SIGN of a positive")


# =============================================================================
# ★★ CEILING / FLOOR — the six sign cases
# =============================================================================


def test_ceiling_covers_all_six_sign_cases() raises:
    """★ FIVE ANSWERS AND ONE REFUSAL, and each pair of them is a different
    rounding DIRECTION. A one-case test (`CEILING(4.5,2)`) is green under
    `ceil(x/s)*abs(s)`, under `ceil(x)`, and under three other wrong forms."""
    _assert_num(xl_ceiling(_nn(4.5, 2.0)), 6.0, "both positive -> away from zero")
    _assert_num(xl_ceiling(_nn(-4.5, 2.0)), -4.0, "★ signs differ -> TOWARD zero")
    _assert_num(xl_ceiling(_nn(-4.5, -2.0)), -6.0, "★ both negative -> away from zero")
    _assert_num(xl_ceiling(_nn(4.5, 0.0)), 0.0, "a zero significance is 0")
    _assert_err(
        xl_ceiling(_nn(4.5, -2.0)),
        XL_ERR_NUM,
        "★ a POSITIVE number with a NEGATIVE significance is the one"
        " combination Excel refuses",
    )


def test_floor_is_the_other_direction_over_the_same_table() raises:
    _assert_num(xl_floor(_nn(4.5, 2.0)), 4.0, "both positive -> toward zero")
    _assert_num(xl_floor(_nn(-4.5, 2.0)), -6.0, "★ signs differ -> AWAY from zero")
    _assert_num(xl_floor(_nn(-4.5, -2.0)), -4.0, "both negative -> toward zero")
    _assert_err(xl_floor(_nn(4.5, -2.0)), XL_ERR_NUM, "the same refusal")


# =============================================================================
# ★★ PRODUCT — blanks are SKIPPED
# =============================================================================


def test_product_skips_blanks_rather_than_coercing_them_to_zero() raises:
    """★ A BLANK COERCES TO 0 IN ARITHMETIC, so a `coerce_number` over every
    argument makes ANY product containing an empty cell 0 — a confidently wrong
    number that a test over three literals never sees."""
    var three = List[FormulaValue]()
    three.append(FormulaValue.number(2.0))
    three.append(FormulaValue.number(3.0))
    three.append(FormulaValue.number(4.0))
    _assert_num(xl_product(three), 24.0, "PRODUCT(2,3,4)")

    var with_blank = List[FormulaValue]()
    with_blank.append(FormulaValue.number(2.0))
    with_blank.append(FormulaValue.blank())
    with_blank.append(FormulaValue.number(3.0))
    _assert_num(
        xl_product(with_blank),
        6.0,
        "★ a blank in the middle must be SKIPPED. 0 here means the blank was"
        " coerced, which is the failure this test exists for",
    )

    var only_blank = List[FormulaValue]()
    only_blank.append(FormulaValue.blank())
    _assert_num(
        xl_product(only_blank),
        0.0,
        "★ a product of NO non-blank arguments is 0 in Excel, not the"
        " multiplicative identity 1 an accumulator would return",
    )


def test_a_math_kernel_propagates_the_leftmost_error() raises:
    """The DOMINANT error class, asserted once for the family."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.error(XL_ERR_NA))
    a.append(FormulaValue.number(0.0))
    _assert_err(xl_round(a), XL_ERR_NA, "an error argument dominates")


# =============================================================================
# TEXT
# =============================================================================


def test_upper_and_lower() raises:
    assert_equal(xl_upper(_t(String("aBc"))).text, String("ABC"))
    assert_equal(xl_lower(_t(String("aBc"))).text, String("abc"))


def test_propers_word_boundary_is_any_NON_LETTER() raises:
    """★ THE SURPRISING ANSWER IS THE CORRECT ONE. Excel capitalises after a
    digit or an apostrophe, not only after a space — so `2nd place` becomes
    `2Nd Place`, which looks wrong and is what Excel returns. An
    "after a space" implementation disagrees with Excel on exactly the inputs a
    user notices."""
    assert_equal(xl_proper(_t(String("hello world"))).text, String("Hello World"))
    assert_equal(
        xl_proper(_t(String("o'neil"))).text,
        String("O'Neil"),
        "★ an apostrophe is a word boundary",
    )
    assert_equal(
        xl_proper(_t(String("2nd place"))).text,
        String("2Nd Place"),
        "★ a DIGIT is a word boundary too — `2Nd` is Excel's answer",
    )
    assert_equal(
        xl_proper(_t(String("McDONALD"))).text,
        String("Mcdonald"),
        "every non-initial letter is LOWER-cased, not left alone",
    )


def test_find_is_case_SENSITIVE_and_search_is_not() raises:
    """★ THE PAIR IS THE ONLY THING THAT DISTINGUISHES THEM. Testing each
    separately with a matching-case needle passes under either implementation."""
    _assert_num(xl_find(_tt(String("A"), String("ABC"))), 1.0, "FIND matches the same case")
    _assert_err(
        xl_find(_tt(String("a"), String("ABC"))),
        XL_ERR_VALUE,
        "★ FIND is case-SENSITIVE: a lower-case needle must NOT match",
    )
    _assert_num(
        xl_search(_tt(String("a"), String("ABC"))),
        1.0,
        "★ SEARCH is case-INSENSITIVE and must match",
    )


def test_find_positions_are_ONE_based_and_honour_start_num() raises:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(String("b")))
    a.append(FormulaValue.text_val(String("abcb")))
    a.append(FormulaValue.number(3.0))
    _assert_num(xl_find(a), 4.0, "the SECOND `b`, found because start_num is 3")

    var b = List[FormulaValue]()
    b.append(FormulaValue.text_val(String("b")))
    b.append(FormulaValue.text_val(String("abcb")))
    _assert_num(xl_find(b), 2.0, "without start_num the FIRST match")

    var c = List[FormulaValue]()
    c.append(FormulaValue.text_val(String("b")))
    c.append(FormulaValue.text_val(String("abcb")))
    c.append(FormulaValue.number(0.0))
    _assert_err(
        xl_find(c),
        XL_ERR_VALUE,
        "start_num < 1 is #VALUE! in Excel, not a clamp to the beginning",
    )


def test_replace_replaces_by_POSITION_and_substitute_would_not() raises:
    """`REPLACE(old, start, num_chars, new)`. The near-duplicate is
    `SUBSTITUTE`, which replaces by CONTENT; picking the wrong one is a silent
    wrong string."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(String("abcdef")))
    a.append(FormulaValue.number(2.0))
    a.append(FormulaValue.number(3.0))
    a.append(FormulaValue.text_val(String("XY")))
    assert_equal(xl_replace(a).text, String("aXYef"))


def test_exact_is_case_sensitive_where_excels_own_equals_is_not() raises:
    """★ THE REASON THE FUNCTION EXISTS. `"a"="A"` is TRUE in a sheet."""
    var r = xl_exact(_tt(String("a"), String("A")))
    assert_true(r.is_logical(), "EXACT returns a LOGICAL")
    assert_false(r.logical, "★ EXACT('a','A') is FALSE")
    assert_true(xl_exact(_tt(String("a"), String("a"))).logical, "same case is TRUE")


def test_value_parses_text_and_refuses_non_numeric_text() raises:
    _assert_num(xl_value(_t(String("3.5"))), 3.5, "VALUE parses")
    _assert_err(xl_value(_t(String("x"))), XL_ERR_VALUE, "non-numeric text")
    var blank = List[FormulaValue]()
    blank.append(FormulaValue.blank())
    _assert_num(
        xl_value(blank),
        0.0,
        "a BLANK is 0 and not an error — the distinction FV_BLANK carries",
    )


# =============================================================================
# ★★ THE IS* FAMILY — MANUAL error class
# =============================================================================


def test_iserror_INSPECTS_its_argument_instead_of_propagating_it() raises:
    """⛔ THE ASSERTION THIS WHOLE FAMILY TURNS ON. Registered with the DOMINANT
    error class, `ISERROR(#DIV/0!)` would return `#DIV/0!` — a function whose
    entire purpose is to look at an error, returning the error. It must return
    TRUE."""
    var e = List[FormulaValue]()
    e.append(FormulaValue.error(XL_ERR_DIV0))
    var r = xl_iserror(e)
    assert_true(r.is_logical(), "★ ISERROR must return a LOGICAL, not the error it was handed")
    assert_true(r.logical, "ISERROR(#DIV/0!) is TRUE")

    var ok = List[FormulaValue]()
    ok.append(FormulaValue.number(1.0))
    assert_false(xl_iserror(ok).logical, "ISERROR of a number is FALSE")


def test_isna_is_the_code_filtered_half_of_iserror() raises:
    """`ISNA` is `#N/A` ONLY; `ISERROR` is every error. Asserting both over the
    SAME two inputs is what separates them — one input cannot."""
    var na = List[FormulaValue]()
    na.append(FormulaValue.error(XL_ERR_NA))
    var val = List[FormulaValue]()
    val.append(FormulaValue.error(XL_ERR_VALUE))
    assert_true(xl_isna(na).logical, "ISNA(#N/A) is TRUE")
    assert_false(xl_isna(val).logical, "★ ISNA(#VALUE!) is FALSE")
    assert_true(xl_iserror(val).logical, "★ but ISERROR(#VALUE!) is TRUE")


def test_isblank_is_FALSE_for_the_empty_string() raises:
    """★ AN EMPTY CELL AND A ZERO-LENGTH STRING ARE DIFFERENT THINGS. A kernel
    testing `byte_length() == 0` answers TRUE for both, and nobody writes the
    `""` case by accident."""
    var blank = List[FormulaValue]()
    blank.append(FormulaValue.blank())
    assert_true(xl_isblank(blank).logical, "ISBLANK(<empty cell>) is TRUE")
    assert_false(
        xl_isblank(_t(String(""))).logical,
        '★ ISBLANK("") is FALSE in Excel',
    )


def test_the_type_predicates_are_TYPE_tests_and_not_coercibility_tests() raises:
    """★ `ISNUMBER("3")` is FALSE even though `"3"+2` is 5. A kernel asking
    `coerce_number().is_error()` answers TRUE and is wrong on the one input
    anybody tests."""
    assert_true(xl_isnumber(_n(3.0)).logical, "ISNUMBER(3)")
    assert_false(
        xl_isnumber(_t(String("3"))).logical,
        '★ ISNUMBER("3") is FALSE — coercibility is not type',
    )
    assert_true(xl_istext(_t(String("3"))).logical, "ISTEXT of the same value is TRUE")
    assert_false(
        xl_istext(_n(3.0)).logical,
        "★ ISTEXT(3) is FALSE — without this line a constant-TRUE kernel passes",
    )
    var lg = List[FormulaValue]()
    lg.append(FormulaValue.logical_val(True))
    assert_true(xl_islogical(lg).logical, "ISLOGICAL(TRUE)")
    assert_false(
        xl_islogical(_n(1.0)).logical,
        "★ ISLOGICAL(1) is FALSE even though 1 coerces to TRUE",
    )


def test_na_returns_the_na_error_value() raises:
    var empty = List[FormulaValue]()
    _assert_err(xl_na(empty), XL_ERR_NA, "NA() is the #N/A value itself")


# =============================================================================
# ★★ XOR — parity
# =============================================================================


def test_xor_is_PARITY_and_not_exactly_one() raises:
    """★ THE TWO DEFINITIONS AGREE AT ARITY 2, which is the arity everyone
    tests, so "exactly one" survives a two-argument suite intact. Three TRUEs
    is what separates them."""
    var t2 = List[FormulaValue]()
    t2.append(FormulaValue.logical_val(True))
    t2.append(FormulaValue.logical_val(True))
    assert_false(xl_xor(t2).logical, "XOR(TRUE,TRUE) is FALSE under both rules")

    var t3 = List[FormulaValue]()
    t3.append(FormulaValue.logical_val(True))
    t3.append(FormulaValue.logical_val(True))
    t3.append(FormulaValue.logical_val(True))
    assert_true(
        xl_xor(t3).logical,
        '★ XOR(TRUE,TRUE,TRUE) is TRUE — parity. "Exactly one" answers FALSE',
    )

    var t1 = List[FormulaValue]()
    t1.append(FormulaValue.logical_val(True))
    assert_true(xl_xor(t1).logical, "one TRUE")


# =============================================================================
# ★★ THE 2026-09-04 NUMERIC WAVE — twenty-one names the census could not
#    previously say it did not have.
#
# ⛔ SELECTION RULE, UNCHANGED: one test per case where the OBVIOUS
# implementation is wrong. There is no test here for `SIN(0) == 0`.
# =============================================================================


def test_atan2_takes_EXCELS_argument_order_which_is_the_REVERSE_of_C() raises:
    """⛔⛔ THE SINGLE MOST DANGEROUS ROW IN THE WAVE. Excel is
    `ATAN2(x, y)`; libm and this repo's own SQL `atan2` are `atan2(y, x)`.

    ★ AND THE DIAGONAL IS WHERE THE BUG HIDES: `ATAN2(1, 1)` is 0.785 under
    BOTH orders, and it is the first case anybody writes. The discriminating
    inputs are the AXES — `ATAN2(1, 0)` is 0 (pointing along +x) and
    `ATAN2(0, 1)` is pi/2 (pointing along +y). A swapped kernel returns
    a plausible angle for every input and an error for none.

    ⚠ A CROSS-SURFACE MATRIX CELL CANNOT CATCH THIS. The SQL door and the
    Excel door take their arguments in opposite orders BY SPECIFICATION, so a
    cell feeding both the same pair and comparing outputs asserts that the bug
    EXISTS."""
    _assert_num(xl_atan2(_nn(1.0, 0.0)), 0.0, "★ ATAN2(x=1, y=0) is 0 — along +x")
    _assert_num(
        xl_atan2(_nn(0.0, 1.0)),
        1.5707963267948966,
        "★ ATAN2(x=0, y=1) is pi/2 — along +y. A swapped kernel answers 0",
    )
    _assert_num(
        xl_atan2(_nn(-1.0, 0.0)),
        3.141592653589793,
        "ATAN2(x=-1, y=0) is pi",
    )
    _assert_err(
        xl_atan2(_nn(0.0, 0.0)),
        XL_ERR_DIV0,
        "★ ATAN2(0,0) is #DIV/0! in Excel where C's atan2(0,0) is 0.0",
    )


def test_ln_and_log10_REFUSE_the_domain_where_libm_returns_a_number() raises:
    """★ `log(0.0)` is `-inf` in C and `log(-1.0)` is `NaN`. Both are Float64
    values that keep travelling — `-inf` compares, sorts and sums; `NaN` makes
    every comparison above it FALSE without raising anything. Excel answers
    `#NUM!`, which STOPS.

    ⚠ AN ALL-POSITIVE FIXTURE CANNOT TELL THIS GUARD FROM ITS ABSENCE, which
    is exactly why the negative and the zero are both asserted here."""
    _assert_num(xl_ln(_n(1.0)), 0.0, "LN(1) is 0")
    _assert_close(
        xl_ln(_n(100.0)), 4.605170185988092,
        "★ LN(100) is 4.6052 — a kernel calling log10 answers 2.0, which is"
        " exactly the SQL surface's one-argument base-10 `log`",
    )
    _assert_err(xl_ln(_n(0.0)), XL_ERR_NUM, "★ LN(0) is #NUM!, not -inf")
    _assert_err(xl_ln(_n(-1.0)), XL_ERR_NUM, "★ LN(-1) is #NUM!, not NaN")
    _assert_num(xl_log10(_n(1000.0)), 3.0, "LOG10(1000) is 3")
    _assert_err(xl_log10(_n(0.0)), XL_ERR_NUM, "★ LOG10(0) is #NUM!")
    _assert_err(xl_log10(_n(-2.0)), XL_ERR_NUM, "★ LOG10(-2) is #NUM!")


def test_log_is_TWO_argument_with_base_ten_default_unlike_the_sql_log() raises:
    """★ TWO WAYS TO GET THIS SILENTLY WRONG AND THEY POINT OPPOSITE WAYS.
    Forwarding to `ln` makes `LOG(100)` answer 4.605 instead of 2; ignoring the
    second argument makes `LOG(8, 2)` answer 0.903 instead of 3. Both are
    plausible positive numbers, and this repo's SQL surface really does have a
    one-argument base-10 `log`, which is where the first mistake comes from."""
    _assert_num(xl_log(_n(100.0)), 2.0, "★ LOG(100) defaults to base 10 — not ln")
    _assert_num(xl_log(_nn(8.0, 2.0)), 3.0, "★ LOG(8,2) is 3 — the base is READ")
    _assert_err(xl_log(_n(0.0)), XL_ERR_NUM, "LOG(0) is #NUM!")
    _assert_err(
        xl_log(_nn(8.0, 1.0)),
        XL_ERR_DIV0,
        "base 1 is an exact division by LN(1)=0",
    )
    _assert_err(xl_log(_nn(8.0, -2.0)), XL_ERR_NUM, "a negative base is #NUM!")


def test_trunc_TRUNCATES_where_int_FLOORS_and_they_agree_on_positives() raises:
    """★ THE TWO FUNCTIONS DIFFER ON EVERY NEGATIVE NON-INTEGER AND ON NOTHING
    ELSE. A fixture with no negative numbers cannot tell them apart, so both
    are asserted over the same value here — this is the `signedmix` argument
    written as a test rather than as a fixture choice."""
    _assert_num(xl_trunc(_n(8.9)), 8.0, "TRUNC(8.9) is 8")
    _assert_num(xl_trunc(_n(-8.9)), -8.0, "★ TRUNC(-8.9) is -8 — toward zero")
    _assert_num(xl_int(_n(-8.9)), -9.0, "★ INT(-8.9) is -9 — FLOOR. The control")
    _assert_num(xl_trunc(_nn(3.14159, 2.0)), 3.14, "TRUNC honours num_digits")
    _assert_num(
        xl_trunc(_nn(-3.14159, 2.0)),
        -3.14,
        "★ and truncates toward zero at that digit too — a floor gives -3.15",
    )


def test_even_and_odd_move_AWAY_from_zero_and_change_a_matching_integer() raises:
    """⛔ `EVEN(3)` IS 4 AND `ODD(0)` IS 1. Neither is a round-to-nearest: they
    move away from zero until they land on an integer of the right parity, so
    an odd integer handed to `EVEN` is CHANGED, and zero — the one input where
    "away from zero" has no direction — is +1 for `ODD`.

    An implementation built on IEEE round-half-to-even gets every assertion
    below wrong."""
    _assert_num(xl_even(_n(3.0)), 4.0, "★ EVEN(3) is 4 — an odd INTEGER moves")
    _assert_num(xl_even(_n(2.0)), 2.0, "EVEN(2) is 2 — already even, stays")
    _assert_num(xl_even(_n(1.5)), 2.0, "EVEN(1.5) is 2")
    _assert_num(xl_even(_n(-1.5)), -2.0, "★ EVEN(-1.5) is -2 — away from zero is DOWN")
    _assert_num(xl_even(_n(0.0)), 0.0, "EVEN(0) is 0")
    _assert_num(xl_odd(_n(0.0)), 1.0, "★ ODD(0) is 1, not 0")
    _assert_num(xl_odd(_n(2.0)), 3.0, "★ ODD(2) is 3")
    _assert_num(xl_odd(_n(3.0)), 3.0, "ODD(3) is 3 — already odd, stays")
    _assert_num(xl_odd(_n(1.5)), 3.0, "ODD(1.5) is 3")
    _assert_num(xl_odd(_n(-2.0)), -3.0, "★ ODD(-2) is -3")


def test_quotient_TRUNCATES_while_mod_FLOORS_so_the_identity_BREAKS() raises:
    """⛔ EXCEL'S OWN INCONSISTENCY, ASSERTED RATHER THAN SMOOTHED OVER.
    `QUOTIENT(-5,2)` is -2 (truncate) and `MOD(-5,2)` is 1 (divisor's sign), so
    `QUOTIENT(n,d)*d + MOD(n,d)` is -3 and not -5. Anyone who "fixes"
    `QUOTIENT` to floor will make it agree with `MOD` and disagree with every
    spreadsheet on earth — so the broken identity is the assertion."""
    _assert_num(xl_quotient(_nn(5.0, 2.0)), 2.0, "QUOTIENT(5,2) is 2")
    _assert_num(xl_quotient(_nn(-5.0, 2.0)), -2.0, "★ QUOTIENT(-5,2) is -2, not -3")
    _assert_num(xl_mod(_nn(-5.0, 2.0)), 1.0, "★ MOD(-5,2) is 1 — the divisor's sign")
    var q = xl_quotient(_nn(-5.0, 2.0))
    var r = xl_mod(_nn(-5.0, 2.0))
    assert_equal(
        q.num * 2.0 + r.num,
        -3.0,
        "★ the division identity gives -3, NOT the -5 it reconstructs in any"
        " language where the two agree. This is Excel's bug and we keep it",
    )


def test_the_inverse_trig_domain_is_NUM_and_not_nan() raises:
    """★ C's `asin(2.0)` is `NaN`, a Float64 that keeps travelling."""
    _assert_num(xl_asin(_n(0.0)), 0.0, "ASIN(0) is 0")
    _assert_err(xl_asin(_n(2.0)), XL_ERR_NUM, "★ ASIN(2) is #NUM!, not NaN")
    _assert_err(xl_asin(_n(-1.5)), XL_ERR_NUM, "★ ASIN(-1.5) is #NUM!")
    _assert_err(xl_acos(_n(2.0)), XL_ERR_NUM, "★ ACOS(2) is #NUM!")


def test_the_trig_family_reads_RADIANS_and_degrees_round_trips() raises:
    """★ `SIN(30)` IS NOT 0.5 — the argument is in radians, which is the thing
    every spreadsheet user gets wrong first. `RADIANS`/`DEGREES` are the
    conversion, and they round-trip."""
    var s30 = xl_sin(_n(30.0))
    assert_true(
        s30.num < 0.0,
        "★ SIN(30) is -0.988 — RADIANS. A degrees kernel answers +0.5",
    )
    var conv = xl_radians(_n(30.0))
    # ⚠ `_assert_close`, NOT `_assert_num`, AND THE REASON IS A MEASURED FACT
    # RATHER THAN CAUTION: this composition is **0.49999999999999994**, one ulp
    # below 0.5, because two correctly-rounded libm calls compose that way.
    # Excel PRINTS 0.5 for it — its display renders 15 significant decimal
    # digits, so the identical binary64 value looks exact in a sheet.
    _assert_close(
        xl_sin(_n(conv.num)),
        0.5,
        "★ SIN(RADIANS(30)) is 0.49999999999999994, and Excel's 0.5 is a"
        " DISPLAY of the same double",
    )
    _assert_close(xl_degrees(_n(conv.num)), 30.0, "DEGREES round-trips RADIANS")
    # ⛔⛔ THE SIX LINES BELOW PIN THAT THE KERNEL RETURNS A NUMBER AT ITS FIXED
    # POINT. THEY DO NOT PIN **WHICH FUNCTION IT IS**, AND READING THEM AS
    # COVERAGE IS WHAT LET EIGHT WRONG KERNELS SHIP. `sin`, `tan`, `atan`,
    # `asin`, `sinh` and `tanh` are all 0.0 at 0, and `cos` and `cosh` are both
    # 1.0 there — every one of these assertions is satisfied by five other
    # members of its own family. The identity of each kernel is pinned by
    # `test_the_transcendentals_are_pinned_OFF_ZERO_...` and nowhere else; do
    # not delete that test on the belief that these lines cover it.
    _assert_num(xl_cos(_n(0.0)), 1.0, "COS(0) is 1")
    _assert_num(xl_tan(_n(0.0)), 0.0, "TAN(0) is 0")
    _assert_num(xl_atan(_n(0.0)), 0.0, "ATAN(0) is 0")
    _assert_num(xl_sinh(_n(0.0)), 0.0, "SINH(0) is 0")
    _assert_num(xl_cosh(_n(0.0)), 1.0, "★ COSH(0) is 1, not 0 — the pair differ here")
    _assert_num(xl_tanh(_n(0.0)), 0.0, "TANH(0) is 0")


def test_the_transcendentals_are_pinned_OFF_ZERO_because_at_zero_EIGHT_of_them_are_the_SAME_FUNCTION() raises:
    """⛔⛔ THE TEST THAT MAKES THE OTHER TRIG ASSERTIONS MEAN ANYTHING.

    ⇒ The first block below asserts the collision itself, so that the REASON
    this test exists lives in the repo as an executable fact rather than as a
    sentence somebody can delete. If a future Mojo/libm change ever made those
    eight distinguishable at 0, this block goes red and says so.
    Exact equality here would be a flake, not a stronger test."""
    # ---- the collision, asserted rather than asserted-about -----------------
    _assert_num(xl_sin(_n(0.0)), 0.0, "SIN(0) is 0")
    _assert_num(xl_tan(_n(0.0)), 0.0, "TAN(0) is 0 — the SAME 0 as SIN's")
    _assert_num(xl_atan(_n(0.0)), 0.0, "ATAN(0) is 0 — the same 0 again")
    _assert_num(xl_asin(_n(0.0)), 0.0, "ASIN(0) is 0 — and again")
    _assert_num(xl_sinh(_n(0.0)), 0.0, "SINH(0) is 0 — and again")
    _assert_num(xl_tanh(_n(0.0)), 0.0, "TANH(0) is 0 — six functions, one value")
    _assert_num(xl_cos(_n(0.0)), 1.0, "COS(0) is 1")
    _assert_num(xl_cosh(_n(0.0)), 1.0, "COSH(0) is 1 — two functions, one value")

    # ---- and now a witness that identifies each one ------------------------
    _assert_close(
        xl_sin(_n(1.0)), 0.8414709848078965,
        "★ SIN(1) is 0.8415 — TAN answers 1.5574, TANH 0.7616, SINH 1.1752",
    )
    _assert_close(
        xl_cos(_n(1.0)), 0.5403023058681398,
        "★ COS(1) is 0.5403 — COSH answers 1.5431. At 0 they are BOTH 1",
    )
    _assert_close(
        xl_tan(_n(1.0)), 1.557407724654902,
        "★ TAN(1) is 1.5574 — SIN answers 0.8415, COSH 1.5431. At 0 both are 0",
    )
    _assert_close(
        xl_asin(_n(0.5)), 0.5235987755982988,
        "★ ASIN(0.5) is pi/6 — ATAN answers 0.4636. The DOMAIN guard above is"
        " satisfied by either, so it pins nothing about which function ran",
    )
    _assert_close(
        xl_acos(_n(0.5)), 1.0471975511965976,
        "★ ACOS(0.5) is pi/3 — ASIN answers 0.5236. ACOS had NO value"
        " assertion at all before 2026-09-05, only its #NUM! domain refusal",
    )
    _assert_close(
        xl_atan(_n(1.0)), 0.7853981633974483,
        "★ ATAN(1) is pi/4 — SIN answers 0.8415, TANH 0.7616",
    )
    _assert_close(
        xl_sinh(_n(1.0)), 1.1752011936438014,
        "★ SINH(1) is 1.1752 — SIN answers 0.8415. At 0 they are both 0",
    )
    _assert_close(
        xl_cosh(_n(1.0)), 1.5430806348152437,
        "★ COSH(1) is 1.5431 — COS answers 0.5403, TAN 1.5574",
    )
    _assert_close(
        xl_tanh(_n(1.0)), 0.7615941559557649,
        "★ TANH(1) is 0.7616 — TAN answers 1.5574, ATAN 0.7854. ATAN is only"
        " 0.0238 away, which is still 10^10 times the 1e-12 tolerance",
    )


def test_exp_and_pi_are_the_exact_pair() raises:
    """`EXP(0)` is 1 and `EXP(1)` is e. `PI()` takes NO arguments and still
    receives the list, because every registry thunk has one signature."""
    _assert_num(xl_exp(_n(0.0)), 1.0, "EXP(0) is 1")
    _assert_num(xl_exp(_n(1.0)), 2.718281828459045, "EXP(1) is e")
    var empty = List[FormulaValue]()
    _assert_num(xl_pi(empty), 3.141592653589793, "PI() is pi")


def test_the_parity_predicates_TRUNCATE_and_PROPAGATE_errors() raises:
    """⛔ TWO THINGS AT ONCE, AND BOTH ARE ASYMMETRIES AGAINST THEIR OWN
    FAMILY. `ISEVEN(-1.5)` truncates to -1 and is FALSE (a floor would give -2
    and answer TRUE); and unlike every other `IS*`, these PROPAGATE an error
    argument, because Excel's `ISODD(1/0)` is `#DIV/0!` rather than FALSE."""
    assert_true(xl_isodd(_n(3.0)).logical, "ISODD(3)")
    assert_false(xl_isodd(_n(4.0)).logical, "ISODD(4) is FALSE")
    assert_true(xl_isodd(_n(3.7)).logical, "ISODD(3.7) truncates to 3")
    assert_false(
        xl_iseven(_n(-1.5)).logical,
        "★ ISEVEN(-1.5) truncates to -1 and is FALSE. A FLOOR gives -2 → TRUE",
    )
    assert_true(xl_iseven(_n(-2.0)).logical, "ISEVEN(-2)")
    var div0 = List[FormulaValue]()
    div0.append(FormulaValue.error(XL_ERR_DIV0))
    _assert_err(
        xl_isodd(div0),
        XL_ERR_DIV0,
        "★ ISODD PROPAGATES its error — it is not an inspector like ISERROR",
    )


# =============================================================================
# ★★ ISERR — the third member of the error-predicate triple
# =============================================================================


def test_iserr_partitions_the_error_space_against_iserror_and_isna() raises:
    """★ THE THREE PREDICATES PARTITION THE VALUE SPACE, and asserting the
    PARTITION is what catches the wrong implementations. A kernel that just
    returned `is_error()` — i.e. an alias for `ISERROR`, which is the one thing
    the absence reason said not to do — passes any test that only feeds it
    `#DIV/0!` and a number. `#N/A` is the discriminating input."""
    var na = List[FormulaValue]()
    na.append(FormulaValue.error(XL_ERR_NA))
    var div0 = List[FormulaValue]()
    div0.append(FormulaValue.error(XL_ERR_DIV0))

    assert_true(xl_iserror(na).logical, "ISERROR(#N/A) is TRUE")
    assert_true(xl_isna(na).logical, "ISNA(#N/A) is TRUE")
    assert_false(
        xl_iserr(na).logical,
        "★ ISERR(#N/A) is FALSE — this is the ONLY input that separates ISERR"
        " from ISERROR, and an alias passes every other case",
    )

    assert_true(xl_iserror(div0).logical, "ISERROR(#DIV/0!) is TRUE")
    assert_false(xl_isna(div0).logical, "ISNA(#DIV/0!) is FALSE")
    assert_true(xl_iserr(div0).logical, "ISERR(#DIV/0!) is TRUE")

    assert_false(xl_iserror(_n(1.0)).logical, "ISERROR(1) is FALSE")
    assert_false(xl_isna(_n(1.0)).logical, "ISNA(1) is FALSE")
    assert_false(xl_iserr(_n(1.0)).logical, "ISERR(1) is FALSE")


# =============================================================================
# ★★ THE TIME-OF-DAY FAMILY — and the fixture problem it had to solve first
# =============================================================================


def test_time_MANUFACTURES_a_fraction_from_three_arguments_and_no_clock() raises:
    """★ THE RECORD THAT KEPT THIS FUNCTION OUT SAID IT "reads the FRACTIONAL
    part of a serial, and this engine has no clock". It reads nothing. It takes
    three numbers and PRODUCES a fraction, and this assertion is what makes the
    other three testable at all — without it every `HOUR` test would read an
    INTEGER serial, where 0 is the right answer whether the kernel works or
    not."""
    _assert_num(_time3(12.0, 0.0, 0.0), 0.5, "★ TIME(12,0,0) is 0.5 — noon")
    _assert_num(_time3(18.0, 0.0, 0.0), 0.75, "TIME(18,0,0) is 0.75")
    _assert_num(_time3(0.0, 0.0, 0.0), 0.0, "TIME(0,0,0) is 0")


def test_time_WRAPS_at_24_hours_and_carries_the_smaller_fields_first() raises:
    """★ `TIME(27,0,0)` IS 03:00, NOT `#NUM!` — Excel wraps rather than
    refusing. And the carry happens BEFORE the wrap, so `TIME(0,90,0)` is
    01:30 rather than an error about a 90th minute."""
    _assert_num(_time3(27.0, 0.0, 0.0), 0.125, "★ TIME(27,0,0) wraps to 03:00")
    _assert_num(_time3(0.0, 90.0, 0.0), 0.0625, "★ TIME(0,90,0) is 01:30")
    _assert_num(_time3(0.0, 0.0, 3600.0), 1.0 / 24.0, "TIME(0,0,3600) is 01:00")


def test_a_negative_time_component_is_NUM_and_does_not_borrow() raises:
    """★ `TIME(1,-30,0)` IS AN ERROR, NOT 00:30. Excel refuses each field below
    zero rather than borrowing from the one above it — the arithmetic
    interpretation is the plausible wrong answer."""
    _assert_err(_time3(1.0, -30.0, 0.0), XL_ERR_NUM, "★ a negative minute refuses")
    _assert_err(_time3(-1.0, 0.0, 0.0), XL_ERR_NUM, "a negative hour refuses")
    _assert_err(_time3(0.0, 0.0, -1.0), XL_ERR_NUM, "a negative second refuses")


def test_hour_minute_second_read_the_fraction_of_a_TIME_built_serial() raises:
    """★ COMPOSED WITH `TIME` ON PURPOSE. Reading an INTEGER serial would make
    every answer 0, which is right whether the kernel works or not — the
    all-timestamps-in-1970 failure. `TIME` is the only thing in this tree that
    can manufacture a fractional serial, so it is the fixture."""
    var t = _time3(13.0, 30.0, 45.0)
    _assert_num(xl_hour(_n(t.num)), 13.0, "★ HOUR(TIME(13,30,45)) is 13")
    _assert_num(xl_minute(_n(t.num)), 30.0, "★ MINUTE(...) is 30")
    _assert_num(xl_second(_n(t.num)), 45.0, "★ SECOND(...) is 45")
    # And over a serial with a DATE part, so the whole-day component is dropped
    # rather than leaking into the hour.
    _assert_num(
        xl_hour(_n(45000.0 + t.num)),
        13.0,
        "★ the DATE part is dropped — 45000 days does not change the hour",
    )
    # ⛔ THE ROUNDING CAN CARRY TO A WHOLE DAY, AND THAT BRANCH HAD NO
    # ASSERTION. A fraction that rounds up to 86400 seconds is midnight of the
    # NEXT day, so the answer is 0 — an unguarded kernel reports HOUR 24, which
    # is not a valid hour at all. Measured 2026-09-05: deleting the carry guard
    # left every test in this file green.
    _assert_num(
        xl_hour(_n(1.9999995)), 0.0,
        "★ a fraction rounding up to 86400s is HOUR 0, not HOUR 24",
    )
    _assert_num(
        xl_minute(_n(1.9999995)), 0.0, "★ and MINUTE 0, not 1440 % 60",
    )
    _assert_num(
        xl_second(_n(1.9999995)), 0.0, "★ and SECOND 0",
    )


def test_SECOND_rounds_to_the_nearest_second_or_it_is_off_by_one() raises:
    """⛔⛔ THE DISCRIMINATING SECOND IS **11**, AND THE FIRST REVISION OF THIS
    TEST GOT IT WRONG — WHICH IS THE WHOLE LESSON.

    That revision asserted `SECOND(TIME(0,0,59)) == 59` on the reasoning that
    59/86400 is not exactly representable. It IS: the round trip
    `59/86400 * 86400` is exactly 59.0 in binary64, so a **truncating**
    implementation passes that assertion. An armed truncation mutant went
    GREEN through it — the test could not fail, which is this repo's dominant
    defect class written in miniature.

    ★ MEASURED OVER ALL 86,400 SECONDS: the round trip is exact for all but
    SEVEN — 11, 22, 29, 44, 58, 61, 85. `11/86400 * 86400` is
    **10.999999999999998**, so truncation answers 10 and rounding answers 11.

    ⚠ THE SPARSENESS IS THE HAZARD, not the magnitude of the error. Almost
    every value anybody picks by hand — 0, 30, 45, 59, 13:30:45, the last
    second of the day — is exact, so a suite full of them says nothing at
    all."""
    var t11 = _time3(0.0, 0.0, 11.0)
    _assert_num(
        xl_second(_n(t11.num)),
        11.0,
        "★ SECOND(TIME(0,0,11)) is 11. A TRUNCATING kernel answers 10 — this"
        " is the assertion the armed mutant has to fail",
    )
    _assert_num(_time_sec(22.0), 22.0, "★ second 22 — the second of the seven")
    _assert_num(_time_sec(29.0), 29.0, "★ second 29")
    _assert_num(_time_sec(44.0), 44.0, "★ second 44")
    _assert_num(_time_sec(58.0), 58.0, "★ second 58")
    # ⚠ AND THE EXACT ONES, KEPT DELIBERATELY AS A CONTROL: these pass under a
    # truncating kernel too, which is exactly why they are not sufficient.
    _assert_num(_time_sec(59.0), 59.0, "second 59 — exact, so NOT discriminating")
    var t2 = _time3(23.0, 59.0, 59.0)
    _assert_num(xl_hour(_n(t2.num)), 23.0, "HOUR at the last second of the day")
    _assert_num(xl_minute(_n(t2.num)), 59.0, "MINUTE at the last second")
    _assert_num(xl_second(_n(t2.num)), 59.0, "SECOND at the last second")


def test_a_negative_serial_refuses_across_the_whole_time_of_day_family() raises:
    _assert_err(xl_hour(_n(-1.0)), XL_ERR_NUM, "HOUR of a negative serial")
    _assert_err(xl_minute(_n(-1.0)), XL_ERR_NUM, "MINUTE of a negative serial")
    _assert_err(xl_second(_n(-1.0)), XL_ERR_NUM, "SECOND of a negative serial")


# =============================================================================
# ★★ THE SECOND 2026-09-04 WAVE — integer arithmetic, text, ISO weeks, CHOOSE
# =============================================================================


def test_gcd_and_lcm_TRUNCATE_their_arguments_and_REFUSE_a_negative() raises:
    """★ TWO RULES NOBODY GUESSES. `GCD(12.9, 8)` is 4 — every argument is
    truncated to an integer first — and `GCD(-4, 8)` is `#NUM!` rather than 4,
    because Excel REFUSES a negative instead of taking the absolute value.
    An implementation using `abs` answers 4 and never refuses."""
    _assert_num(xl_gcd(_nn(12.0, 8.0)), 4.0, "GCD(12,8) is 4")
    _assert_num(xl_gcd(_nn(12.9, 8.0)), 4.0, "★ GCD(12.9,8) truncates to GCD(12,8)")
    _assert_err(xl_gcd(_nn(-4.0, 8.0)), XL_ERR_NUM, "★ a NEGATIVE is #NUM!, not abs")
    _assert_num(xl_gcd(_nn(0.0, 0.0)), 0.0, "GCD(0,0) is 0")
    _assert_num(xl_gcd(_nn(0.0, 7.0)), 7.0, "GCD(0,7) is 7")
    _assert_num(xl_lcm(_nn(4.0, 6.0)), 12.0, "LCM(4,6) is 12")
    _assert_num(xl_lcm(_nn(4.0, 0.0)), 0.0, "★ any zero makes LCM 0")
    _assert_err(xl_lcm(_nn(-4.0, 6.0)), XL_ERR_NUM, "a negative refuses here too")
    _assert_num(xl_gcd(_nnn(24.0, 36.0, 60.0)), 12.0, "variadic GCD folds")
    _assert_num(xl_lcm(_nnn(2.0, 3.0, 4.0)), 12.0, "variadic LCM folds")


def test_mround_REFUSES_a_sign_mismatch_where_the_obvious_kernel_answers() raises:
    """⛔ THE ONE THING NOBODY EXPECTS ABOUT `MROUND`. `MROUND(10, -3)` is
    `#NUM!` — number and multiple must share a sign. A kernel that just
    computed `round(n/m)*m` answers 9, a perfectly plausible number, and never
    refuses anything.

    ⚠ AND THE TIE RULE IS AWAY FROM ZERO, not IEEE half-to-even: `MROUND(1.5,
    1)` is 2 and a language `round()` gives 2 as well — but `MROUND(2.5, 1)` is
    3 where half-to-even gives 2. That is the discriminating tie."""
    _assert_num(xl_mround(_nn(10.0, 3.0)), 9.0, "MROUND(10,3) is 9")
    _assert_num(xl_mround(_nn(-10.0, -3.0)), -9.0, "MROUND(-10,-3) is -9")
    _assert_err(
        xl_mround(_nn(10.0, -3.0)),
        XL_ERR_NUM,
        "★ MROUND(10,-3) is #NUM! — a sign mismatch REFUSES",
    )
    _assert_err(xl_mround(_nn(-10.0, 3.0)), XL_ERR_NUM, "and the other way round")
    _assert_num(xl_mround(_nn(0.0, 0.0)), 0.0, "a zero multiple is 0, not #DIV/0!")
    _assert_num(
        xl_mround(_nn(2.5, 1.0)),
        3.0,
        "★ MROUND(2.5,1) is 3 — half AWAY from zero. Half-to-even gives 2",
    )


def test_rept_TRUNCATES_its_count_and_REFUSES_past_excels_cell_limit() raises:
    """★ The ceiling is a REFUSAL and not a clamp: a clamp returns a truncated
    string that looks like a successful answer."""
    assert_equal(xl_rept(_tn(String("ab"), 3.0)).text, String("ababab"), "REPT x3")
    assert_equal(
        xl_rept(_tn(String("ab"), 2.9)).text,
        String("abab"),
        "★ the count TRUNCATES — 2.9 is twice, not three times",
    )
    assert_equal(xl_rept(_tn(String("ab"), 0.0)).text, String(""), "zero is empty")
    _assert_err(xl_rept(_tn(String("ab"), -1.0)), XL_ERR_VALUE, "a negative count")
    _assert_err(
        xl_rept(_tn(String("ab"), 20000.0)),
        XL_ERR_VALUE,
        "★ 40,000 bytes is past Excel's 32,767 cell limit — REFUSE, not clamp",
    )


def test_char_refuses_the_code_page_range_and_code_round_trips_ascii() raises:
    """⛔ `CHAR(128)` IS A REFUSAL HERE AND AN ANSWER IN EXCEL, deliberately.
    Excel maps 128..255 through the machine's ANSI code page, so the same call
    gives different characters on different machines; this engine has no code
    page, and answering with the Unicode scalar would be a plausible WRONG
    glyph for 27 of those 128 codes. A refusal is the safe direction."""
    assert_equal(xl_char(_n(65.0)).text, String("A"), "CHAR(65) is A")
    assert_equal(xl_char(_n(97.0)).text, String("a"), "CHAR(97) is a")
    _assert_err(xl_char(_n(0.0)), XL_ERR_VALUE, "CHAR(0) is #VALUE! in Excel too")
    _assert_err(
        xl_char(_n(128.0)),
        XL_ERR_VALUE,
        "★ CHAR(128) REFUSES — the ANSI code page is not derivable here",
    )
    _assert_num(xl_code(_t(String("A"))), 65.0, "CODE(A) is 65")
    _assert_num(xl_code(_t(String("Abc"))), 65.0, "★ CODE reads the FIRST character")
    _assert_err(xl_code(_t(String(""))), XL_ERR_VALUE, "CODE of empty text")


def test_clean_removes_CONTROLS_and_is_not_trim() raises:
    """★ `CLEAN` AND `TRIM` ARE NOT INTERCHANGEABLE and reaching for the wrong
    one gives a string that looks cleaned and is not. `CLEAN` removes ASCII
    0..31 and touches no space; the assertion below keeps a space that a `TRIM`
    implementation would collapse."""
    var raw = String("a") + String(xl_char(_n(9.0)).text) + String("  b")
    var cleaned = xl_clean(_t(raw)).text
    assert_equal(
        cleaned,
        String("a  b"),
        "★ the TAB goes and BOTH spaces stay — a TRIM would collapse them",
    )
    assert_equal(xl_clean(_t(String("plain"))).text, String("plain"), "no-op")


def test_T_and_N_do_NOT_coerce_which_is_the_whole_point_of_them() raises:
    """⛔ `T(123)` IS `""` AND `N("7")` IS `0`. Both are built on the shared
    coercions in every wrong implementation, and both are wrong on the one
    input anybody tests. `N` also says 0 for NON-numeric text, where
    `coerce_number` would raise `#VALUE!`."""
    assert_equal(xl_t(_t(String("hi"))).text, String("hi"), "T of text is the text")
    assert_equal(
        xl_t(_n(123.0)).text,
        String(""),
        '★ T(123) is "" — a coerce_text kernel answers "123"',
    )
    _assert_num(xl_n(_n(7.0)), 7.0, "N(7) is 7")
    _assert_num(
        xl_n(_t(String("7"))),
        0.0,
        '★ N("7") is 0 — NOT 7. This is not an arithmetic context',
    )
    _assert_num(
        xl_n(_t(String("zzz"))),
        0.0,
        '★ N("zzz") is 0 too, where coerce_number would give #VALUE!',
    )
    var tr = List[FormulaValue]()
    tr.append(FormulaValue.logical_val(True))
    _assert_num(xl_n(tr), 1.0, "N(TRUE) is 1")
    var na = List[FormulaValue]()
    na.append(FormulaValue.error(XL_ERR_NA))
    _assert_err(xl_n(na), XL_ERR_NA, "an error passes THROUGH N — ERRH_MANUAL")
    _assert_err(xl_t(na), XL_ERR_NA, "and through T")


def test_isoweeknum_puts_the_week_in_the_year_of_its_THURSDAY() raises:
    """⚠⚠ THE ONE THING AN ISO WEEK IMPLEMENTATION CAN GET WRONG, and the
    fixture is chosen to expose it. 2027-01-01 is a FRIDAY, so its week's
    Thursday falls in 2026 and the answer is **week 53** — a day-of-year
    division answers 1. 2024-12-30 is the mirror case: a MONDAY whose Thursday
    is in 2025, so it is week 1 and not week 53.

    ⛔ A FIXTURE OF MID-YEAR DATES CANNOT SEE EITHER OF THEM. Both wrong
    implementations agree with the right one everywhere except a handful of
    days at each end of a year."""
    _assert_num(
        xl_isoweeknum(_n(Float64(_serial(2027, 1, 1)))),
        53.0,
        "★ 2027-01-01 is a FRIDAY — its week's Thursday is in 2026, so week 53",
    )
    _assert_num(
        xl_isoweeknum(_n(Float64(_serial(2024, 12, 30)))),
        1.0,
        "★ 2024-12-30 is a MONDAY whose Thursday is in 2025 — week 1, not 53",
    )
    _assert_num(
        xl_isoweeknum(_n(Float64(_serial(2026, 1, 1)))),
        1.0,
        "2026-01-01 is a Thursday — unambiguously week 1",
    )
    _assert_num(
        xl_isoweeknum(_n(Float64(_serial(2026, 12, 31)))),
        53.0,
        "2026-12-31 is a Thursday — week 53 of 2026",
    )
    _assert_num(
        xl_isoweeknum(_n(Float64(_serial(2026, 9, 4)))),
        36.0,
        "a mid-year control, where every implementation agrees",
    )
    _assert_err(xl_isoweeknum(_n(0.0)), XL_ERR_NUM, "a serial below 1 refuses")


def test_choose_IGNORES_an_error_in_an_unselected_arm() raises:
    """⛔ THE ASSERTION THAT PINS THE ERROR CLASS. Excel does not EVALUATE the
    arms `CHOOSE` does not select, so `CHOOSE(1, 5, <error>)` is 5. Under
    `ERRH_PROPAGATE_DOMINANT` the leftmost error argument wins before the
    kernel is ever called and the answer is the error — a refusal where Excel
    returns a number. Registering this row alongside the math family would do
    exactly that.

    ⚠ `index_num` TRUNCATES: `CHOOSE(2.9, ...)` picks arm 2."""
    var a = List[FormulaValue]()
    a.append(FormulaValue.number(1.0))
    a.append(FormulaValue.number(5.0))
    a.append(FormulaValue.error(XL_ERR_DIV0))
    _assert_num(
        xl_choose(a),
        5.0,
        "★ CHOOSE(1, 5, #DIV/0!) is 5 — the unselected error is IGNORED",
    )

    var b = List[FormulaValue]()
    b.append(FormulaValue.number(2.9))
    b.append(FormulaValue.number(10.0))
    b.append(FormulaValue.number(20.0))
    b.append(FormulaValue.number(30.0))
    _assert_num(xl_choose(b), 20.0, "★ the index TRUNCATES — 2.9 picks arm 2")

    var c = List[FormulaValue]()
    c.append(FormulaValue.number(0.0))
    c.append(FormulaValue.number(10.0))
    _assert_err(xl_choose(c), XL_ERR_VALUE, "index 0 is out of range")

    var d = List[FormulaValue]()
    d.append(FormulaValue.number(3.0))
    d.append(FormulaValue.number(10.0))
    _assert_err(xl_choose(d), XL_ERR_VALUE, "index past the last arm")

    var e = List[FormulaValue]()
    e.append(FormulaValue.error(XL_ERR_NA))
    e.append(FormulaValue.number(10.0))
    _assert_err(
        xl_choose(e),
        XL_ERR_NA,
        "★ but an ERROR INDEX propagates — the selection cannot be made",
    )


# =============================================================================
# ★★ THE 2026-09-14 EXACT-ANSWER TRANCHE.
#
# ⛔ THE SELECTION RULE IS THIS FILE'S OWN, AND IT IS THE HALF THAT COST IT
# EIGHT SILENT KERNELS IN 2026-09: naming the wrong case is not enough — the
# ARGUMENT has to be one where the plausible WRONG implementation answers
# DIFFERENTLY. Six of these nine math names have a wrong twin ALREADY IN THIS
# FILE'S IMPORT LIST, so each test below asserts the SHARP input and, where the
# twin can be called here, the BLIND one beside it — because a blind cell that
# is never written down is how "these two functions are different" becomes an
# unchecked belief.
# =============================================================================


def test_fact_TRUNCATES_its_argument_and_refuses_the_overflow() raises:
    """★ `FACT(5.9)` is 120, not 720. A ROUNDING kernel answers 720, which is
    a perfectly plausible factorial of a perfectly plausible integer."""
    _assert_num(xl_fact(_n(5.9)), 120.0, "★ FACT TRUNCATES 5.9 to 5")
    _assert_num(xl_fact(_n(5.0)), 120.0, "the integer control")
    _assert_num(xl_fact(_n(0.0)), 1.0, "FACT(0) is the empty product, 1")
    _assert_err(xl_fact(_n(-1.0)), XL_ERR_NUM, "a negative is a REFUSAL")
    _assert_num(xl_fact(_n(170.0)), xl_fact(_n(170.0)).num, "170! is finite")
    _assert_err(
        xl_fact(_n(171.0)),
        XL_ERR_NUM,
        "★ 171! OVERFLOWS Float64 to +inf, which travels silently through "
        "every comparison above it. #NUM! stops",
    )


def test_factdouble_is_NOT_fact_and_the_blind_input_is_pinned() raises:
    """★★ THE MIS-WIRING THIS TRANCHE IS MOST EXPOSED TO. `FACTDOUBLE` wired
    to `FACT` answers CORRECTLY at 0, 1, 2 and 3 — the four inputs a lazy
    fixture uses — and diverges from 4 upward."""
    _assert_num(xl_factdouble(_n(6.0)), 48.0, "★★ 6*4*2 = 48, NOT FACT(6)=720")
    _assert_num(xl_fact(_n(6.0)), 720.0, "the twin, on the same input")
    _assert_num(xl_factdouble(_n(7.0)), 105.0, "the ODD arm: 7*5*3*1 = 105")
    _assert_num(xl_fact(_n(7.0)), 5040.0, "the twin again")
    # ⭐ THE BLIND INPUT, ASSERTED AS AN AGREEMENT. This is the measured
    # statement that a small-input fixture cannot tell the two apart at all.
    _assert_num(xl_factdouble(_n(2.0)), 2.0, "FACTDOUBLE(2) is 2")
    assert_equal(
        xl_fact(_n(2.0)).num,
        xl_factdouble(_n(2.0)).num,
        "★ THE BLIND INPUT: FACT and FACTDOUBLE AGREE at 2",
    )
    _assert_num(xl_factdouble(_n(0.0)), 1.0, "FACTDOUBLE(0) is 1")
    _assert_err(
        xl_factdouble(_n(-1.0)),
        XL_ERR_NUM,
        "⚠ EXCEL'S ANSWER, NOT MATHEMATICS': the convention is (-1)!! = 1",
    )


def test_combina_is_NOT_combin_in_two_separate_ways() raises:
    """★★ Two differences, and a fixture that finds only one is half a test.
    (1) the VALUE differs for every k >= 2; (2) COMBINA ACCEPTS k > n where
    COMBIN refuses."""
    _assert_num(xl_combin(_nn(5.0, 2.0)), 10.0, "C(5,2) = 10")
    _assert_num(xl_combina(_nn(5.0, 2.0)), 15.0, "★★ C(6,2) = 15, WITH repetition")
    _assert_num(xl_combin(_nn(5.9, 2.9)), 10.0, "both arguments TRUNCATE")
    _assert_err(xl_combin(_nn(2.0, 5.0)), XL_ERR_NUM, "★ k > n is #NUM!, not 0")
    _assert_num(xl_combina(_nn(2.0, 5.0)), 6.0, "★ and COMBINA ALLOWS it: C(6,5)")
    # ⭐ THE BLIND INPUT.
    assert_equal(
        xl_combin(_nn(5.0, 1.0)).num,
        xl_combina(_nn(5.0, 1.0)).num,
        "★ THE BLIND INPUT: the two agree for every k <= 1, and k=1 is the "
        "first case anybody writes",
    )
    _assert_num(xl_combina(_nn(0.0, 0.0)), 1.0, "COMBINA(0,0) is 1")
    _assert_err(xl_combina(_nn(0.0, 1.0)), XL_ERR_NUM, "nothing to draw from")
    _assert_num(xl_combin(_nn(52.0, 5.0)), 2598960.0, "a poker hand, exactly")


def test_sumsq_is_squares_and_not_a_sum_or_a_sum_of_absolutes() raises:
    """★ Two plausible wrong readings of the name, and one input kills each."""
    _assert_num(xl_sumsq(_nn(3.0, 4.0)), 25.0, "★ 25, where SUM(3,4) is 7")
    _assert_num(xl_sumsq(_n(-3.0)), 9.0, "★ 9, where a sum-of-abs gives 3")
    var blanks = List[FormulaValue]()
    blanks.append(FormulaValue.number(3.0))
    blanks.append(FormulaValue.blank())
    _assert_num(xl_sumsq(blanks), 9.0, "a blank is skipped")
    var err = List[FormulaValue]()
    err.append(FormulaValue.error(XL_ERR_DIV0))
    err.append(FormulaValue.number(1.0))
    _assert_err(xl_sumsq(err), XL_ERR_DIV0, "dominance on an error argument")


def test_base_renders_UPPER_CASE_and_pads_and_never_returns_empty() raises:
    """★ A lower-case renderer answers 'ff' and no numeric comparison sees it."""
    assert_equal(xl_base(_nn(255.0, 16.0)).text, String("FF"),
                 "★ UPPER-CASE digits")
    assert_equal(xl_base(_nn(7.0, 2.0)).text, String("111"), "binary")
    assert_equal(xl_base(_nnn(7.0, 2.0, 8.0)).text, String("00000111"),
                 "min_length LEFT-pads with zeros")
    assert_equal(xl_base(_nnn(255.0, 16.0, 1.0)).text, String("FF"),
                 "a min_length SHORTER than the rendering never truncates")
    assert_equal(xl_base(_nn(0.0, 2.0)).text, String("0"),
                 "★ '0', NOT '' — the one input a never-running loop gets wrong")
    assert_equal(xl_base(_nn(35.0, 36.0)).text, String("Z"), "the last digit")
    _assert_err(xl_base(_nn(255.0, 1.0)), XL_ERR_NUM, "radix < 2")
    _assert_err(xl_base(_nn(255.0, 37.0)), XL_ERR_NUM, "radix > 36")
    _assert_err(xl_base(_nn(-1.0, 2.0)), XL_ERR_NUM, "a negative number")


def test_decimal_REFUSES_a_digit_outside_the_radix() raises:
    """★★ THE SINGLE MOST LIKELY WRONG IMPLEMENTATION of this function is a
    parser that accumulates `value*radix + digit` without checking the digit
    against the radix. It reads `DECIMAL("2", 2)` as 2; Excel refuses."""
    _assert_num(xl_decimal(_tn(String("FF"), 16.0)), 255.0, "BASE's inverse")
    _assert_num(xl_decimal(_tn(String("ff"), 16.0)), 255.0,
                "★ CASE-INSENSITIVE")
    _assert_num(xl_decimal(_tn(String("111"), 2.0)), 7.0, "binary")
    _assert_err(xl_decimal(_tn(String("2"), 2.0)), XL_ERR_NUM,
                "★★ a digit OUTSIDE the radix is #NUM!, not 2")
    _assert_err(xl_decimal(_tn(String("G"), 16.0)), XL_ERR_NUM,
                "G is not a hex digit")
    _assert_err(xl_decimal(_tn(String("FF"), 1.0)), XL_ERR_NUM, "radix < 2")
    _assert_err(xl_decimal(_tn(String(""), 16.0)), XL_ERR_NUM,
                "the empty text — this engine REFUSES rather than inventing 0")
    # ⭐ THE ROUND TRIP. Neither direction can be faked into agreeing with the
    # other by accident: a lower-casing BASE would fail the `.text` assertions
    # above, and a radix-blind DECIMAL would have answered the refusal cell.
    assert_equal(
        xl_decimal(_tn(xl_base(_nn(419.0, 7.0)).text, 7.0)).num,
        419.0,
        "★ BASE and DECIMAL are INVERSES over radix 7",
    )


def test_the_PRECISE_pair_ignores_the_significance_SIGN() raises:
    """★★ `CEILING.PRECISE` WIRED TO `CEILING` PASSES EVERY POSITIVE CELL.
    The two differ in exactly two ways and both involve a sign: the DIRECTION
    is selected by sign agreement on CEILING and is always +infinity here, and
    CEILING REFUSES a positive number with a negative significance where this
    takes `abs(significance)` and answers."""
    # --- the SHARP inputs, each asserted against the twin on the same args ---
    _assert_num(xl_ceiling_precise(_nn(-2.1, -1.0)), -2.0,
                "★★ -2, toward +infinity")
    _assert_num(xl_ceiling(_nn(-2.1, -1.0)), -3.0,
                "★★ the TWIN answers -3 on the same arguments")
    _assert_num(xl_ceiling_precise(_nn(2.1, -1.0)), 3.0,
                "★★ 3, because the significance sign is DISCARDED")
    _assert_err(xl_ceiling(_nn(2.1, -1.0)), XL_ERR_NUM,
                "★★ and the TWIN REFUSES the same arguments")
    _assert_num(xl_floor_precise(_nn(-2.1, -1.0)), -3.0,
                "★★ FLOOR.PRECISE goes toward -infinity")
    _assert_num(xl_floor(_nn(-2.1, -1.0)), -2.0,
                "★★ the twin answers -2")
    _assert_err(xl_floor(_nn(2.1, -1.0)), XL_ERR_NUM, "the twin refuses")
    _assert_num(xl_floor_precise(_nn(2.1, -1.0)), 2.0, "and this answers")
    # --- the ARITY difference: significance is OPTIONAL here, REQUIRED there -
    _assert_num(xl_ceiling_precise(_n(4.3)), 5.0, "★ arity 1, default 1")
    _assert_num(xl_floor_precise(_n(-4.3)), -5.0,
                "★ arity 1 AND negative: -5, where a TRUNCATING kernel gives -4")
    # --- ⭐ THE BLIND INPUT, asserted as an AGREEMENT ----------------------
    assert_equal(
        xl_ceiling(_nn(2.1, 1.0)).num,
        xl_ceiling_precise(_nn(2.1, 1.0)).num,
        "★ THE BLIND INPUT: both arguments positive, and the two AGREE — "
        "which is the first cell anybody writes",
    )
    assert_equal(
        xl_floor(_nn(2.9, 1.0)).num,
        xl_floor_precise(_nn(2.9, 1.0)).num,
        "★ the same blindness on the FLOOR side",
    )
    _assert_num(xl_ceiling_precise(_nn(2.1, 0.0)), 0.0, "a zero significance is 0")


def test_concatenate_coerces_and_inserts_no_separator() raises:
    """★ The two plausible wrong kernels are an ARITHMETIC one and a
    TEXTJOIN-shaped one, and one input kills each."""
    var three = List[FormulaValue]()
    three.append(FormulaValue.text_val(String("a")))
    three.append(FormulaValue.text_val(String("b")))
    three.append(FormulaValue.text_val(String("c")))
    assert_equal(xl_concatenate(three).text, String("abc"),
                 "★ no separator — a TEXTJOIN-shaped kernel inserts one")
    assert_equal(xl_concatenate(_nn(1.0, 2.0)).text, String("12"),
                 "★ the answer is TEXT '12', where arithmetic gives 3")
    var err = List[FormulaValue]()
    err.append(FormulaValue.text_val(String("a")))
    err.append(FormulaValue.error(XL_ERR_DIV0))
    _assert_err(xl_concatenate(err), XL_ERR_DIV0, "dominance")


def test_unichar_answers_where_CHAR_refuses_and_splits_its_two_errors() raises:
    """★★ `CHAR` refuses everything above 127 (no ANSI code page here);
    `UNICHAR`'s argument IS a code point, so it answers. `UNICHAR(65)` and
    `CHAR(65)` are both "A" — the blind input an ASCII fixture never leaves."""
    assert_equal(xl_unichar(_n(8364.0)).text, String("€"),
                 "★★ the euro sign, where CHAR(8364) is #VALUE!")
    _assert_err(xl_char(_n(8364.0)), XL_ERR_VALUE,
                "★★ the TWIN refuses the same argument")
    assert_equal(
        xl_unichar(_n(65.0)).text,
        xl_char(_n(65.0)).text,
        "★ THE BLIND INPUT: both answer 'A'",
    )
    _assert_err(xl_unichar(_n(0.0)), XL_ERR_VALUE, "zero is #VALUE!")
    _assert_err(
        xl_unichar(_n(55296.0)),
        XL_ERR_NA,
        "★ A LONE SURROGATE IS #N/A — A DIFFERENT ERROR from the row above, "
        "and the case a naive encoder turns into invalid CESU-8 bytes",
    )
    _assert_err(xl_unichar(_n(1114112.0)), XL_ERR_NA, "above U+10FFFF")
    # ⭐ THE ROUND TRIP over a 4-byte character, which is where a hand-written
    # UTF-8 encoder gets the continuation bytes wrong.
    _assert_num(
        xl_unicode(_t(xl_unichar(_n(119070.0)).text)),
        119070.0,
        "★ U+1D11E round-trips — a 4-byte encoding, 3 continuation bytes",
    )


def test_unicode_is_CODE_here_and_that_is_the_stated_divergence() raises:
    """⛔ ON THIS ENGINE THEY ARE THE SAME NUMBER and the assertion SAYS SO
    rather than implying a discrimination there is not: `xl_code` returns a
    code point because this engine has no ANSI code page, so Excel's `CODE` is
    the one that diverges (128 for the euro sign on a Western box) and
    `UNICODE` is right on both surfaces."""
    _assert_num(xl_unicode(_t(String("A"))), 65.0, "ASCII")
    _assert_num(xl_unicode(_t(String("€"))), 8364.0, "the euro sign")
    assert_equal(
        xl_code(_t(String("€"))).num,
        xl_unicode(_t(String("€"))).num,
        "⛔ CODE AND UNICODE AGREE HERE — the divergence is CODE's, against "
        "EXCEL, and it is stated rather than hidden",
    )
    _assert_err(xl_unicode(_t(String(""))), XL_ERR_VALUE, "empty is #VALUE!")


def test_isnontext_type_and_error_type_all_INSPECT_the_error() raises:
    """⛔ ALL THREE ARE `ERRH_MANUAL` AND THESE ARE THE CELLS THAT SAY SO. A
    kernel is only half the claim: registered under dominance, none of the
    three would ever be reached with an error argument."""
    var e = List[FormulaValue]()
    e.append(FormulaValue.error(XL_ERR_NA))
    assert_true(xl_isnontext(e).logical, "★ an ERROR is non-text: TRUE")
    assert_false(xl_isnontext(_t(String("a"))).logical, "text is text")
    assert_true(xl_isnontext(_n(1.0)).logical,
                "★ a NUMBER is non-text — an ISTEXT-wired row answers FALSE")
    var blank = List[FormulaValue]()
    blank.append(FormulaValue.blank())
    assert_true(xl_isnontext(blank).logical, "a BLANK is non-text")
    assert_false(xl_isnontext(_t(String(""))).logical,
                 "★ but the EMPTY STRING is TEXT — the ISBLANK distinction")

    _assert_num(xl_type(_n(1.0)), 1.0, "number")
    _assert_num(xl_type(_t(String("a"))), 2.0, "text")
    var lg = List[FormulaValue]()
    lg.append(FormulaValue.logical_val(True))
    _assert_num(xl_type(lg), 4.0,
                "★ 4 FOR A LOGICAL, NOT 3 — the codes are BIT FLAGS")
    _assert_num(xl_type(e), 16.0, "★ 16 for an error — the MANUAL cell")
    _assert_num(xl_type(blank), 1.0,
                "★ a BLANK is 1: Excel has no TYPE code for an empty cell")


def test_error_type_is_the_only_kernel_that_reads_WHICH_error() raises:
    """★★ Every other MANUAL predicate in this file collapses the seven codes
    to one answer, so this is the only kernel whose seven-code axis can be
    discriminated at all — a constant-returning kernel passes them and fails
    here."""
    var seen = List[Float64]()
    var codes = List[UInt8]()
    codes.append(XL_ERR_DIV0)
    codes.append(XL_ERR_NA)
    codes.append(XL_ERR_VALUE)
    codes.append(XL_ERR_NUM)
    var want = List[Float64]()
    want.append(2.0)
    want.append(7.0)
    want.append(3.0)
    want.append(6.0)
    for i in range(len(codes)):
        var a = List[FormulaValue]()
        a.append(FormulaValue.error(codes[i]))
        var got = xl_error_type(a)
        _assert_num(got, want[i], "ERROR.TYPE ordinal")
        seen.append(got.num)
    # ⭐ THE ANSWERS MUST BE DISTINCT. Four ordinals that happened to collide
    # would satisfy every row above if the expectations were wrong together.
    for i in range(len(seen)):
        for j in range(i + 1, len(seen)):
            assert_true(
                seen[i] != seen[j],
                "★ ERROR.TYPE returns a DIFFERENT ordinal per code",
            )
    _assert_err(
        xl_error_type(_n(1.0)),
        XL_ERR_NA,
        "★★ A NON-ERROR IS #N/A, NOT 0 AND NOT #VALUE! — the idiom is "
        "CHOOSE(ERROR.TYPE(x), ...), which a 0 indexes out of range",
    )


def test_true_and_false_are_two_kernels_and_not_one_with_a_flag() raises:
    """⚠ A TRUE-ONLY FIXTURE CANNOT SEE A SWAPPED FLAG. Both halves asserted.

    ⛔ THE HARD PART OF THESE TWO WAS NEVER THE KERNEL — it was the PARSER:
    `=TRUE()` was a PARSE ERROR until 2026-09-14 because TRUE/FALSE were folded
    to boolean literals before the `(` was looked for. The parse half is graded
    through the C door by the scalar VALUE sweep; this is the kernel half."""
    var none = List[FormulaValue]()
    assert_true(xl_true(none).is_logical(), "TRUE() is a LOGICAL")
    assert_true(xl_true(none).logical, "TRUE() is TRUE")
    var none2 = List[FormulaValue]()
    assert_true(xl_false(none2).is_logical(), "FALSE() is a LOGICAL")
    assert_false(xl_false(none2).logical, "★ and FALSE() is FALSE")


# =============================================================================
# ★★ THE 2026-09-14 TEXT + LOOKUP TRANCHE.
#
# ⛔⛔ THE FIRST TEST HERE IS A REGRESSION FOR A DEFECT THE CENSUS HAD ALREADY
# MEASURED AND CARRIED AS FOUR KNOWN-RED CELLS ` answered 6, `LEFT("naïve",3)` emitted a LONE UTF-8 LEAD
# BYTE, `RIGHT` a lone continuation byte, `MID` a short string. ⚠ AND EVERY ONE
# OF THOSE FUNCTIONS ALREADY HAD AN ASSERTION IN THIS TREE — over ASCII, where
# the byte index and the character index are the SAME NUMBER. The selection
# rule at the top of this file is exactly why: naming the case is not enough,
# the ARGUMENT has to be one where the wrong implementation answers
# differently.
# =============================================================================
def _tnnt(a0: String, n1: Float64, n2: Float64, a3: String) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(a0))
    a.append(FormulaValue.number(n1))
    a.append(FormulaValue.number(n2))
    a.append(FormulaValue.text_val(a3))
    return a^


def _ttn(a0: String, a1: String, n2: Float64) -> List[FormulaValue]:
    var a = List[FormulaValue]()
    a.append(FormulaValue.text_val(a0))
    a.append(FormulaValue.text_val(a1))
    a.append(FormulaValue.number(n2))
    return a^


def _ttnn(a0: String, a1: String, n2: Float64, n3: Float64) -> List[FormulaValue]:
    var a = _ttn(a0, a1, n2)
    a.append(FormulaValue.number(n3))
    return a^


def _ttnnn(
    a0: String, a1: String, n2: Float64, n3: Float64, n4: Float64
) -> List[FormulaValue]:
    var a = _ttnn(a0, a1, n2, n3)
    a.append(FormulaValue.number(n4))
    return a^


def _ttnnnt(
    a0: String, a1: String, n2: Float64, n3: Float64, n4: Float64, a5: String
) -> List[FormulaValue]:
    var a = _ttnnn(a0, a1, n2, n3, n4)
    a.append(FormulaValue.text_val(a5))
    return a^


def _nnnb(n0: Float64, n1: Float64, n2: Float64, b3: Bool) -> List[FormulaValue]:
    var a = _nnn(n0, n1, n2)
    a.append(FormulaValue.logical_val(b3))
    return a^


def _nnnbt(
    n0: Float64, n1: Float64, n2: Float64, b3: Bool, a4: String
) -> List[FormulaValue]:
    var a = _nnnb(n0, n1, n2, b3)
    a.append(FormulaValue.text_val(a4))
    return a^


def test_text_positions_are_CHARACTER_positions_and_not_byte_offsets() raises:
    """⭐⭐ THE ONE THING AN ASCII FIXTURE CANNOT SEE.

    `"naïve"` is 5 CHARACTERS in 6 BYTES, so every index past the `ï` differs
    by one between the two readings; `"a𝔄b"` puts a FOUR-byte character in the
    middle and differs by three, which also separates a 3-byte-assuming
    implementation from a correct one.

    ⛔ THE ASCII CONTROLS ARE ASSERTED IN THE SAME TEST ON PURPOSE. They pass
    under BOTH readings, so a green control next to a red multibyte cell is
    what makes this a character/byte finding rather than a broken kernel."""
    # ---- the helpers themselves -------------------------------------------
    assert_equal(xl_char_count(String("naïve")), 5, "★ 5 CHARACTERS, 6 bytes")
    # The control word is deliberately NOT a product name: the public export
    # renames those, and a rename that changes the length turns this arm red
    # for a reason that has nothing to do with character counting.
    assert_equal(xl_char_count(String("control")), 7, "the ASCII control")
    assert_equal(xl_char_count(String("a𝔄b")), 3, "★ an ASTRAL character is ONE")
    assert_equal(
        xl_substr_chars(String("naïve"), 0, 3),
        String("naï"),
        "★ 3 CHARACTERS includes the whole 2-byte ï, never its lead byte",
    )
    assert_equal(
        xl_substr_chars(String("naïve"), 2, 3),
        String("ïve"),
        "★ and from the other side, starting ON the 2-byte character",
    )
    assert_equal(
        xl_substr_chars(String("a𝔄b"), 1, 1),
        String("𝔄"),
        "★ a 4-byte character taken whole",
    )
    assert_equal(
        xl_substr_chars(String("naïve"), 3, 99),
        String("ve"),
        "a count past the end SHORTENS, it does not corrupt",
    )
    # ---- FIND -------------------------------------------------------------
    _assert_num(xl_find(_tt("c", "abc")), 3.0, "the ASCII control: 3 either way")
    _assert_num(
        xl_find(_tt("v", "naïve")),
        4.0,
        "⭐ FIND('v','naïve') is the 4th CHARACTER; the byte offset is 5",
    )
    _assert_num(
        xl_find(_tt("e", "naïve")), 5.0, "and the last character is 5, not 6"
    )
    _assert_num(
        xl_find(_tt("b", "a𝔄b")),
        3.0,
        "⭐ past a FOUR-byte character: 3, where the byte offset is 6",
    )
    # ---- SEARCH -----------------------------------------------------------
    _assert_num(
        xl_search(_tt("V", "naïve")),
        4.0,
        "SEARCH reports the same CHARACTER position, case-insensitively",
    )
    # ---- REPLACE ----------------------------------------------------------
    _assert_text(
        xl_replace(_tnnt("abcdef", 2.0, 3.0, "XY")),
        String("aXYef"),
        "the ASCII control for REPLACE",
    )
    _assert_text(
        xl_replace(_tnnt("naïve", 3.0, 1.0, "i")),
        String("naive"),
        "⭐ REPLACE takes out the WHOLE 2-byte ï; a byte kernel removes its "
        "lead byte and returns invalid UTF-8",
    )
    _assert_text(
        xl_replace(_tnnt("a𝔄b", 2.0, 1.0, "X")),
        String("aXb"),
        "⭐ and the whole FOUR-byte character",
    )


def test_SEARCH_has_wildcards_and_FIND_must_not() raises:
    """⭐ THE SECOND DIFFERENCE BETWEEN THE PAIR, closed 2026-09-14.

    `_search_note` used to record `SEARCH("a*c","abc")` as a written-down
    divergence: the kernel searched for the LITERAL characters and answered
    `#VALUE!` where Excel answers 1.

    ⛔ AND `FIND` MUST STAY LITERAL. Sharing one matcher between them is the
    obvious simplification and it deletes a function: `FIND("*","a*b")` is how
    a sheet asks for a real asterisk, and it is 2."""
    _assert_num(xl_search(_tt("a*c", "abc")), 1.0, "★ * matches a run")
    _assert_num(xl_search(_tt("b?d", "abcde")), 2.0, "★ ? matches ONE character")
    _assert_num(
        xl_search(_tt("A*C", "abc")),
        1.0,
        "★ case-insensitivity and wildcards TOGETHER — a kernel that folded "
        "case only on the literal path fails this and passes both halves "
        "separately",
    )
    _assert_num(
        xl_search(_tt("*", "a*b")),
        1.0,
        "★ a BARE * matches the empty string at the first position",
    )
    _assert_num(
        xl_search(_tt("~*", "a*b")),
        2.0,
        "⭐ ~ ESCAPES the asterisk, so this finds the LITERAL one at 2. With "
        "the row above it is the pair no tilde-ignoring kernel passes",
    )
    _assert_num(xl_search(_tt("~?", "a?b")), 2.0, "~ escapes the question mark")
    _assert_num(xl_search(_tt("~~", "a~b")), 2.0, "and itself")
    _assert_err(
        xl_search(_tt("x*", "abc")),
        XL_ERR_VALUE,
        "a pattern that cannot match is still #VALUE!, not 0",
    )
    _assert_num(
        xl_search(_ttn("?", "abc", 3.0)),
        3.0,
        "start_num still applies under a wildcard",
    )
    # ---- and FIND is LITERAL ----------------------------------------------
    _assert_err(
        xl_find(_tt("a*c", "abc")),
        XL_ERR_VALUE,
        "⛔ FIND IS LITERAL: 'a*c' is three characters and is not in 'abc'",
    )
    _assert_num(
        xl_find(_tt("*", "a*b")),
        2.0,
        "⛔ and FIND finds the REAL asterisk at 2 — the whole reason the pair "
        "exists",
    )
    _assert_num(
        xl_find(_tt("?", "a?b")), 2.0, "the same for a literal question mark"
    )


def test_TEXTBEFORE_and_TEXTAFTER_partition_around_the_Nth_delimiter() raises:
    """⭐ THE PAIR IS EACH OTHER'S DISCRIMINATOR: over one input they partition
    the text, so a row wired to the wrong kernel returns the OTHER HALF — a
    well-formed string, never an error, which no recognition cell can see."""
    _assert_text(xl_textbefore(_tt("a-b-c", "-")), String("a"), "the 1st by default")
    _assert_text(xl_textafter(_tt("a-b-c", "-")), String("b-c"), "★ the other half")
    _assert_text(
        xl_textbefore(_ttn("a-b-c", "-", 2.0)),
        String("a-b"),
        "instance 2 — a kernel ignoring the argument answers 'a'",
    )
    _assert_text(xl_textafter(_ttn("a-b-c", "-", 2.0)), String("c"), "and after it")
    _assert_text(
        xl_textbefore(_ttn("a-b-c", "-", -1.0)),
        String("a-b"),
        "⭐ a NEGATIVE instance counts FROM THE END",
    )
    _assert_text(
        xl_textafter(_ttn("a-b-c", "-", -2.0)),
        String("b-c"),
        "⭐ the 2nd from the end",
    )
    _assert_err(
        xl_textbefore(_ttn("a-b-c", "-", 0.0)),
        XL_ERR_VALUE,
        "⛔ there is no ZEROTH occurrence — #VALUE!, not a silent 1",
    )
    _assert_err(
        xl_textbefore(_tt("abc", "-")),
        XL_ERR_NA,
        "⛔ NOT FOUND is #N/A — not '' and not the whole text",
    )
    _assert_err(
        xl_textbefore(_ttn("a-b", "-", 9.0)),
        XL_ERR_NA,
        "an instance past the last occurrence is #N/A too",
    )
    _assert_text(
        xl_textbefore(_ttnnnt("abc", "-", 1.0, 0.0, 0.0, "none")),
        String("none"),
        "if_not_found replaces the #N/A",
    )
    _assert_err(
        xl_textbefore(_ttnn("aXbXc", "x", 1.0, 0.0)),
        XL_ERR_NA,
        "match_mode 0 is CASE-SENSITIVE, so lowercase x is not found",
    )
    _assert_text(
        xl_textbefore(_ttnn("aXbXc", "x", 1.0, 1.0)),
        String("a"),
        "⭐ match_mode 1 is case-INSENSITIVE — the same call, the other answer",
    )
    _assert_text(
        xl_textbefore(_ttnnn("a-b", "-", 2.0, 0.0, 1.0)),
        String("a-b"),
        "⭐ match_end 1 makes the END OF THE TEXT the 2nd occurrence",
    )
    _assert_text(
        xl_textafter(_ttnnn("a-b", "-", 2.0, 0.0, 1.0)),
        String(""),
        "and after that occurrence there is nothing",
    )
    _assert_err(
        xl_textbefore(_ttnn("a-b", "-", 1.0, 2.0)),
        XL_ERR_VALUE,
        "a match_mode outside 0/1 is #VALUE!, not a fallback to 0",
    )
    _assert_text(
        xl_textbefore(_tt("naïve", "ï")),
        String("na"),
        "⭐ the slice is by CHARACTER, over a multi-byte delimiter",
    )
    _assert_text(xl_textafter(_tt("naïve", "ï")), String("ve"), "and its other half")
    _assert_err(
        xl_textbefore(_tt("a-b", "")),
        XL_ERR_NA,
        "⚠ DECLARED CONTRACT, NOT EXCEL'S RULE: an EMPTY delimiter takes the "
        "not-found path. See `_textba_note`",
    )


def test_VALUETOTEXT_strict_quotes_TEXT_and_leaves_numbers_alone() raises:
    """⭐ THE `format` ARGUMENT IS THE WHOLE FUNCTION. A kernel forwarding to
    `coerce_text` for both formats answers `a` twice and passes every concise
    cell in any corpus."""
    _assert_text(xl_valuetotext(_t("a")), String("a"), "concise is the default")
    _assert_text(
        xl_valuetotext(_tn("a", 1.0)),
        String('"a"'),
        "⭐ STRICT QUOTES TEXT — the quote characters are part of the answer",
    )
    _assert_text(
        xl_valuetotext(_nn(1.5, 1.0)),
        String("1.5"),
        "⭐ and leaves a NUMBER alone; quoting it would be the near-miss",
    )
    _assert_text(xl_valuetotext(_n(1.5)), String("1.5"), "concise over a number")
    _assert_text(
        xl_valuetotext(_tn('a"b', 1.0)),
        String('"a""b"'),
        "⭐ an internal quote is DOUBLED, which is what makes the strict form "
        "re-readable",
    )
    var lg = List[FormulaValue]()
    lg.append(FormulaValue.logical_val(True))
    _assert_text(xl_valuetotext(lg), String("TRUE"), "a LOGICAL renders as TRUE")
    _assert_err(
        xl_valuetotext(_tn("a", 2.0)),
        XL_ERR_VALUE,
        "a format outside 0/1 is #VALUE!, not a fallback to concise",
    )


def test_ADDRESS_abs_num_is_a_four_way_table_and_the_columns_are_bijective() raises:
    """⭐⭐ TWO INDEPENDENT WAYS TO GET THIS FUNCTION PLAUSIBLY WRONG, and an
    A1-only fixture sees neither.

    (1) `abs_num` 2 and 3 are named after the ROW's state, so 2 is `C$2` — the
    spelling that looks backwards — and a swapped pair passes the 1 and 4 cells.
    (2) The column letters are BIJECTIVE base-26: there is no zero digit, so 26
    is `Z` and 27 is `AA`. The `chr(65 + n % 26)` loop a reader writes from
    memory is correct for every column from 1 to 25."""
    _assert_text(xl_address(_nn(2.0, 3.0)), String("$C$2"), "the default is fully absolute")
    _assert_text(xl_address(_nnn(2.0, 3.0, 1.0)), String("$C$2"), "abs_num 1 says so explicitly")
    _assert_text(
        xl_address(_nnn(2.0, 3.0, 2.0)),
        String("C$2"),
        "⭐ abs_num 2 is ABSOLUTE ROW, relative column",
    )
    _assert_text(
        xl_address(_nnn(2.0, 3.0, 3.0)),
        String("$C2"),
        "⭐ abs_num 3 is the MIRROR of 2 — swapping the two passes 1 and 4",
    )
    _assert_text(xl_address(_nnn(2.0, 3.0, 4.0)), String("C2"), "abs_num 4 is fully relative")
    # ---- bijective base-26 -------------------------------------------------
    _assert_text(xl_address(_nn(1.0, 1.0)), String("$A$1"), "column 1 is A")
    _assert_text(xl_address(_nn(1.0, 26.0)), String("$Z$1"), "column 26 is Z")
    _assert_text(
        xl_address(_nn(1.0, 27.0)),
        String("$AA$1"),
        "⭐ 27 is AA — the modulo loop answers AB here",
    )
    _assert_text(xl_address(_nn(1.0, 52.0)), String("$AZ$1"), "52 is AZ")
    _assert_text(
        xl_address(_nn(1.0, 702.0)),
        String("$ZZ$1"),
        "⭐ 702 is ZZ, the last two-letter column",
    )
    _assert_text(
        xl_address(_nn(1.0, 703.0)),
        String("$AAA$1"),
        "⭐ and 703 rolls to AAA — the carry the modulo loop cannot express",
    )
    _assert_text(
        xl_address(_nn(1.0, 16384.0)), String("$XFD$1"), "the last column is XFD"
    )
    # ---- R1C1 --------------------------------------------------------------
    _assert_text(
        xl_address(_nnnb(2.0, 3.0, 1.0, False)),
        String("R2C3"),
        "⭐ a1=FALSE selects R1C1; a kernel ignoring the flag answers $C$2",
    )
    _assert_text(
        xl_address(_nnnb(2.0, 3.0, 4.0, False)),
        String("R[2]C[3]"),
        "⭐ and in R1C1 the BRACKETS are the relative form",
    )
    _assert_text(
        xl_address(_nnnb(2.0, 3.0, 2.0, False)),
        String("R2C[3]"),
        "the mixed form keeps the same row/column reading as A1's abs_num 2",
    )
    # ---- sheet prefix ------------------------------------------------------
    _assert_text(
        xl_address(_nnnbt(2.0, 3.0, 1.0, True, "Sheet1")),
        String("Sheet1!$C$2"),
        "a bare identifier needs no quoting",
    )
    _assert_text(
        xl_address(_nnnbt(2.0, 3.0, 1.0, True, "My Sheet")),
        String("'My Sheet'!$C$2"),
        "⭐ a space forces single quotes",
    )
    _assert_text(
        xl_address(_nnnbt(2.0, 3.0, 1.0, True, "it's")),
        String("'it''s'!$C$2"),
        "⭐ and an internal quote is DOUBLED",
    )
    # ---- refusals ----------------------------------------------------------
    _assert_err(xl_address(_nn(0.0, 1.0)), XL_ERR_VALUE, "row 0 is #VALUE!")
    _assert_err(xl_address(_nn(1.0, 0.0)), XL_ERR_VALUE, "column 0 is #VALUE!")
    _assert_err(
        xl_address(_nn(1.0, 16385.0)),
        XL_ERR_VALUE,
        "⛔ past the worksheet ceiling is a REFUSAL, never a clamp",
    )
    _assert_err(
        xl_address(_nnn(2.0, 3.0, 5.0)),
        XL_ERR_VALUE,
        "an abs_num outside 1..4 is #VALUE!",
    )


def test_PROPER_word_boundary_is_a_NON_LETTER_and_a_letter_is_not_only_ASCII() raises:
    """⛔⛔ THE MEASURED DEFECT WAS NOT "FAILS TO CAPITALISE é" — IT WAS
    "CAPITALISES THE WRONG CHARACTER". `PROPER("étude")` answered `éTude`
    (the ASCII-only letter test made `é` a word
    BOUNDARY, so the `t` after it was capitalised.

    ⚠ THE ASCII ROWS ARE HERE TOO because they must not regress: the apostrophe
    and the digit ARE boundaries, and a letter test that swallowed all
    punctuation would answer `O'neil`."""
    _assert_text(xl_proper(_t("jean-luc picard")), String("Jean-Luc Picard"),
                 "the hyphen is a word boundary")
    _assert_text(xl_proper(_t("o'neil")), String("O'Neil"),
                 "so is the apostrophe")
    _assert_text(xl_proper(_t("2nd place")), String("2Nd Place"),
                 "and a digit — which looks wrong and IS what Excel returns")
    _assert_text(
        xl_proper(_t("étude")),
        String("Étude"),
        "⭐ é IS A LETTER, so it is the word initial and is CAPITALISED. The "
        "ASCII-only test answered 'éTude' — the wrong character",
    )
    _assert_text(
        xl_proper(_t("ÉTUDE")),
        String("Étude"),
        "⭐ and the non-initial letters are LOWER-cased, which needs the same "
        "classification in the other direction",
    )
    _assert_text(
        xl_proper(_t("straße")), String("Straße"),
        "a mid-word ß is left alone: it is lower-cased, not folded",
    )
    _assert_text(
        xl_proper(_t("ábc déf")), String("Ábc Déf"),
        "two accented words, so the SPACE boundary still works beside them",
    )


def test_HYPERLINK_value_is_the_FRIENDLY_NAME_and_not_the_link() raises:
    """⭐ THE OMITTED-ARGUMENT CELL CANNOT DISCRIMINATE, which is why both are
    here: with `friendly_name` absent the value IS the link, so a kernel
    returning the wrong argument passes that cell and fails this one."""
    _assert_text(
        xl_hyperlink(_t("https://x")),
        String("https://x"),
        "with no friendly name the value IS the link",
    )
    _assert_text(
        xl_hyperlink(_tt("https://x", "report")),
        String("report"),
        "⭐ the DISPLAYED value is the friendly name; every downstream "
        "consumer of the cell sees this string",
    )
    _assert_text(
        xl_hyperlink(_tt("https://x", "")),
        String("https://x"),
        "an EMPTY friendly name falls back to the link, as Excel displays it",
    )


# =============================================================================
# ⭐⭐ WAVE 7 (2026-09-14) — THE TWO LIVE DEFECTS, THEN THE 19 NEW KERNELS.
# =============================================================================
def test_a_non_finite_result_is_NUM_and_never_a_finite_negative_integer() raises:
    """⛔⛔ THE MEASUREMENT THAT STARTED THIS SLICE, AND IT WAS SEVEN KERNELS.

    Before the fix, EVERY one of these overflowed to `+inf` and RENDERED as
    `-9223372036854775808` — a plausible finite NEGATIVE integer — while
    `ISNUMBER` answered TRUE on it. `Int64(inf)` is an undefined conversion and
    the optimiser folded `Float64(Int64(v)) == v` to TRUE at
    `--optimization-level 1`.

    ⚠ THE ASSERTION IS ON **ALL THREE** PROPERTIES, and one alone is not
    enough: an `is_error` check alone passes a kernel that returns `#VALUE!`,
    a render check alone passes one that returns the string `"inf"` while the
    value keeps travelling, and an `ISNUMBER` check alone passes `#DIV/0!`."""
    var cases = List[FormulaValue]()
    var names = List[String]()
    cases.append(xl_exp(_n(1000.0))); names.append(String("EXP(1000)"))
    cases.append(xl_power(_nn(10.0, 400.0))); names.append(String("POWER(10,400)"))
    cases.append(xl_sumsq(_nn(1.0e200, 1.0e200))); names.append(String("SUMSQ(1e200,1e200)"))
    cases.append(xl_product(_nn(1.0e200, 1.0e200))); names.append(String("PRODUCT(1e200,1e200)"))
    cases.append(xl_sinh(_n(1000.0))); names.append(String("SINH(1000)"))
    cases.append(xl_cosh(_n(1000.0))); names.append(String("COSH(1000)"))
    cases.append(xl_mround(_nn(1.0e308, 1.0e-300))); names.append(String("MROUND(1e308,1e-300)"))
    for i in range(len(cases)):
        var v = cases[i].copy()
        _assert_err(
            v,
            XL_ERR_NUM,
            String("★★ ") + names[i] + String(" overflows binary64; Excel's")
            + String(" numeric range stops at the same ceiling and answers")
            + String(" #NUM!"),
        )
        assert_true(
            v.render() != String("-9223372036854775808"),
            String("⛔ ") + names[i] + String(" MUST NOT render the poison")
            + String(" integer Int64::MIN"),
        )
        var vl = List[FormulaValue]()
        vl.append(v.copy())
        assert_false(
            xl_isnumber(vl).logical,
            String("⛔ ISNUMBER(") + names[i] + String(") must be FALSE — a")
            + String(" wrong answer that passes ISNUMBER is the worst shape"),
        )
    # ⚠ AND THE GUARD MUST NOT EAT THE LARGEST **FINITE** VALUE. A refusal
    # spelled `>= 1e308` would take this one too, and nothing above would see
    # it: every case in the loop is genuinely infinite.
    _assert_num(
        xl_abs(_n(1.7976931348623157e308)),
        1.7976931348623157e308,
        "★ the largest finite binary64 is a NUMBER, not #NUM!",
    )
    # ⚠ AND SECH(1000) IS STILL A NUMBER: 1/inf is 0.0, the mathematically
    # right answer, so the guard is on the RESULT and not on the argument.
    _assert_num(xl_sech(_n(1000.0)), 0.0, "★ SECH(1000) is 0, not #NUM!")


def test_the_round_tie_rule_is_ONE_implementation_and_the_obvious_fix_is_a_regression() raises:
    """⛔⛔ A MEASURED NEGATIVE RESULT, PINNED SO IT IS NOT RE-DISCOVERED AS A
    BUG. `_half_away_from_zero` is spelled `floor(x + 0.5)`, which is the
    textbook rounding bug: it rounds `0.49999999999999994` — the largest double
    STRICTLY BELOW one half — up to 1, where the arithmetic says 0.

    ★ EXCEL ALSO SAYS 1, and that is why the spelling stays. Excel rounds the
    15-SIGNIFICANT-DECIMAL-DIGIT representation it displays, and that reading of
    `0.49999999999999994` is exactly `0.5`. The textbook "fix" — testing the
    fraction — answers 0 and moves this kernel AWAY from Excel at the only
    inputs where the two spellings differ at all: over 400,000 random
    `(x, digits)` pairs they agreed on every one.

    ⇒ THIS TEST IS WHAT MAKES THAT DECISION FALSIFIABLE. A future agent who
    "fixes" the `+ 0.5` reds here and reads why."""
    var almost_half = 0.49999999999999994
    _assert_num(
        xl_round(_nn(almost_half, 0.0)),
        1.0,
        "★★ 1, NOT 0: Excel's 15-significant-digit reading of this double is "
        "exactly 0.5, so the textbook fraction test would DIVERGE from Excel",
    )
    _assert_num(
        xl_mround(_nn(almost_half, 1.0)),
        1.0,
        "★ MROUND shares the rule and now shares the implementation",
    )
    # ⚠ THE ORDINARY TIES MUST STILL WORK, in both directions.
    _assert_num(xl_round(_nn(0.5, 0.0)), 1.0, "an EXACT half goes away from zero")
    _assert_num(xl_round(_nn(-0.5, 0.0)), -1.0, "and so does the negative exact half")
    _assert_num(xl_round(_nn(2.5, 0.0)), 3.0, "half-away-from-zero, not half-to-even")
    _assert_num(xl_round(_nn(-1.5, 0.0)), -2.0, "the negative half of the same rule")
    assert_equal(
        _half_away_from_zero(4503599627370497.0),
        4503599627370498.0,
        "⛔ MEASURED: the `+ 0.5` spelling is OFF BY ONE on an exactly "
        "representable integer above 2**52 — ROUND of an integer is not the "
        "identity there",
    )
    # ⚠ AND IT **IS** THE IDENTITY BELOW 2**52, which is what makes the row
    # above a magnitude boundary rather than a blanket failure.
    assert_equal(
        _half_away_from_zero(2251799813685247.0),
        2251799813685247.0,
        "★ below 2**52 the ulp is < 1 and the carry cannot happen",
    )
    # ⭐ THE DIVERGENCE `_round_note` USED TO NAME AT THE WRONG INPUT. 2.675
    # AGREES with Excel (2.68) because 2.675*100 rounds UP to exactly 267.5;
    # 1.005 does not, because 1.005*100 is 100.49999999999999.
    _assert_num(xl_round(_nn(2.675, 2.0)), 2.68, "★★ 2.675 AGREES with Excel — the note cited the wrong input for months")
    _assert_num(
        xl_round(_nn(1.005, 2.0)),
        1.0,
        "⚠ THE REAL BINARY-vs-DECIMAL DIVERGENCE: Excel says 1.01. Asserted "
        "as the ENGINE's own contract, which `_round_note` states",
    )


def test_the_reciprocal_trig_family_splits_on_the_error_class() raises:
    """⛔ SEC / SECH ARE TOTAL; CSC / CSCH / COT / COTH ARE `#DIV/0!` AT 0.

    ⚠ AND EVERY MEMBER IS ALSO ASSERTED **OFF** ITS FIXED POINT, because
    `SEC(0)`, `SECH(0)`, `COSH(0)` and `1/COS(0)` are all 1.0 — the exact
    fixed-point collision that let thirteen wrong kernels pass this file in
    2026-09-05."""
    _assert_num(xl_sec(_n(0.0)), 1.0, "SEC(0) is 1")
    _assert_num(xl_sech(_n(0.0)), 1.0, "SECH(0) is 1")
    _assert_err(xl_csc(_n(0.0)), XL_ERR_DIV0, "★ CSC(0) is #DIV/0!, not +inf")
    _assert_err(xl_csch(_n(0.0)), XL_ERR_DIV0, "★ CSCH(0) is #DIV/0!")
    _assert_err(xl_cot(_n(0.0)), XL_ERR_DIV0, "★ COT(0) is #DIV/0!")
    _assert_err(xl_coth(_n(0.0)), XL_ERR_DIV0, "★ COTH(0) is #DIV/0!")
    # --- OFF the fixed point. Six distinct values; no two collide.
    _assert_close(xl_sec(_n(1.0)), 1.8508157176809255, "SEC(1) = 1/cos(1)")
    _assert_close(xl_csc(_n(1.0)), 1.1883951057781212, "CSC(1) = 1/sin(1)")
    _assert_close(xl_cot(_n(1.0)), 0.6420926159343306, "COT(1) = cos(1)/sin(1)")
    _assert_close(xl_sech(_n(1.0)), 0.6480542736638853, "SECH(1) = 1/cosh(1)")
    _assert_close(xl_csch(_n(1.0)), 0.8509181282393216, "CSCH(1) = 1/sinh(1)")
    _assert_close(xl_coth(_n(1.0)), 1.3130352854993315, "COTH(1) = 1/tanh(1)")
    # ⚠ THE GUARD IS ON THE DENOMINATOR AND NOT THE ARGUMENT: sin(pi) is
    # 1.2246e-16, so CSC(PI()) is a large finite number in Excel too. An
    # `x == 0.0` guard would refuse this and look correct on every 0 cell.
    _assert_close(
        xl_csc(_n(3.141592653589793)),
        8165619676597685.0,
        "★ CSC(PI()) is a huge NUMBER, not #DIV/0! — sin(pi) is not 0",
    )


def test_ACOT_is_pi_over_two_minus_atan_and_not_atan_of_one_over_x() raises:
    """⛔⛔ THE BRANCH, NOT THE PRECISION. `ATAN(1/x)` is right for every
    POSITIVE argument and wrong by exactly pi for every negative one, and it
    divides by zero where the answer is pi/2. Both discriminating inputs."""
    _assert_close(xl_acot(_n(0.0)), 1.5707963267948966, "★ ACOT(0) is pi/2 — the 1/x spelling divides by zero")
    _assert_close(xl_acot(_n(1.0)), 0.7853981633974483, "ACOT(1) is pi/4 — the BLIND cell, both spellings agree")
    _assert_close(
        xl_acot(_n(-1.0)),
        2.356194490192345,
        "★★ ACOT(-1) is 3pi/4; ATAN(1/-1) is -pi/4, off by exactly pi, with "
        "no error and no infinity to notice",
    )


def test_the_four_inverse_hyperbolic_domains_are_four_and_two_are_mirrors() raises:
    """⛔ ASINH TOTAL, ACOSH x>=1, ATANH |x|<1, ACOTH |x|>1.

    ★ ATANH AND ACOTH ARE EXACT MIRRORS, so the cross-assertions are the ones
    that matter: `ATANH(0.5)` is a number where `ACOTH(0.5)` is `#NUM!`, and
    `ACOTH(2)` is a number where `ATANH(2)` is `#NUM!`. A kernel that copied
    one guard into the other passes every same-side assertion."""
    _assert_num(xl_asinh(_n(0.0)), 0.0, "ASINH(0) is 0")
    _assert_num(xl_acosh(_n(1.0)), 0.0, "ACOSH(1) is 0 — the domain edge, INCLUSIVE")
    _assert_num(xl_atanh(_n(0.0)), 0.0, "ATANH(0) is 0")
    _assert_err(xl_acosh(_n(0.5)), XL_ERR_NUM, "★ ACOSH(0.5) is #NUM!, not NaN")
    _assert_err(xl_atanh(_n(1.0)), XL_ERR_NUM, "★ ATANH(1) is #NUM!, not +inf — the edge is EXCLUSIVE")
    _assert_err(xl_atanh(_n(-1.0)), XL_ERR_NUM, "★ and so is -1")
    _assert_err(xl_acoth(_n(1.0)), XL_ERR_NUM, "★ ACOTH(1) is #NUM!")
    _assert_err(xl_acoth(_n(0.5)), XL_ERR_NUM, "★★ ACOTH(0.5) is #NUM! where ATANH(0.5) is a NUMBER")
    _assert_err(xl_atanh(_n(2.0)), XL_ERR_NUM, "★★ ATANH(2) is #NUM! where ACOTH(2) is a NUMBER")
    # --- OFF the fixed point, and no two values collide. ⚠ ACOTH(2) AND
    #     ATANH(0.5) ARE THE SAME NUMBER mathematically (acoth(x) =
    #     atanh(1/x)), so ACOTH is asserted at 3 to keep the values distinct.
    _assert_close(xl_asinh(_n(1.0)), 0.8813735870195429, "ASINH(1)")
    _assert_close(xl_acosh(_n(2.0)), 1.3169578969248166, "ACOSH(2)")
    _assert_close(xl_atanh(_n(0.5)), 0.5493061443340548, "ATANH(0.5)")
    _assert_close(xl_acoth(_n(3.0)), 0.34657359027997264, "ACOTH(3)")


def test_SQRTPI_multiplies_by_pi_and_refuses_a_negative() raises:
    """⚠ `SQRTPI(0)` IS 0, WHICH IS ALSO WHAT A KERNEL THAT DROPPED THE PI
    ANSWERS. `SQRTPI(1)` is the discriminating cell."""
    _assert_num(xl_sqrtpi(_n(0.0)), 0.0, "SQRTPI(0) is 0 — the BLIND cell")
    _assert_close(xl_sqrtpi(_n(1.0)), 1.7724538509055159, "★ SQRTPI(1) is sqrt(pi); a pi-less kernel answers 1")
    _assert_close(xl_sqrtpi(_n(4.0)), 3.5449077018110318, "SQRTPI(4) is 2*sqrt(pi)")
    _assert_err(xl_sqrtpi(_n(-1.0)), XL_ERR_NUM, "★ a negative argument is #NUM!, not NaN")


def test_MULTINOMIAL_is_not_a_product_of_factorials_and_not_a_sum() raises:
    """⛔ BOTH MISREADINGS RETURN A NUMBER. For (2,3): correct 10, product of
    factorials 12, sum of factorials 8. Only a VALUE cell separates them."""
    _assert_num(xl_multinomial(_nn(2.0, 3.0)), 10.0, "★★ MULTINOMIAL(2,3) = 5!/(2!3!) = 10; a product answers 12, a sum answers 8")
    _assert_num(xl_multinomial(_n(4.0)), 1.0, "★ a SINGLE argument is 1 (4!/4!), not 24")
    _assert_num(xl_multinomial(_nnn(1.0, 1.0, 1.0)), 6.0, "MULTINOMIAL(1,1,1) = 3! = 6")
    _assert_num(xl_multinomial(_nn(2.9, 3.0)), 10.0, "★ every argument is TRUNCATED: (2.9,3) is (2,3)")
    _assert_err(xl_multinomial(_nn(-1.0, 2.0)), XL_ERR_NUM, "★ a negative argument is #NUM!, not an absolute value")
    # ⚠ THE RUNNING-BINOMIAL FORM IS WHAT MAKES THIS FINITE. `340!` is +inf,
    # so a `fact(total)/prod(fact)` kernel answers #NUM! (or NaN) here.
    assert_true(
        xl_multinomial(_nn(170.0, 170.0)).is_number(),
        "★★ MULTINOMIAL(170,170) is ~1e102 — finite — where the direct "
        "fact(340)/(fact(170)^2) spelling overflows",
    )


def test_ROMAN_is_classic_form_and_ARABIC_is_not_its_inverse() raises:
    """⛔ TWO SEPARATE CLAIMS. ROMAN emits form 0 and REFUSES forms 1..4;
    ARABIC reads every form, including ones ROMAN never emits."""
    _assert_text(xl_roman(_n(499.0)), String("CDXCIX"), "★ classic form 0 — form 4 is 'ID'")
    _assert_text(xl_roman(_n(4.0)), String("IV"), "★ the SUBTRACTIVE pair; a greedy I-V-X kernel emits 'IIII'")
    _assert_text(xl_roman(_n(9.0)), String("IX"), "★ and 9 is IX, not VIIII")
    _assert_text(xl_roman(_n(3999.0)), String("MMMCMXCIX"), "the ceiling")
    _assert_text(xl_roman(_n(0.0)), String(""), "★ ROMAN(0) is the EMPTY STRING, not #NUM! and not 'N'")
    _assert_err(xl_roman(_n(4000.0)), XL_ERR_NUM, "★ above 3999 is #NUM!")
    _assert_err(xl_roman(_n(-1.0)), XL_ERR_NUM, "★ below 0 is #NUM!")
    _assert_text(xl_roman(_nn(499.0, 0.0)), String("CDXCIX"), "form 0 stated explicitly is the same answer")
    _assert_err(
        xl_roman(_nn(499.0, 4.0)),
        XL_ERR_VALUE,
        "★★ FORM 4 IS REFUSED, not silently served as form 0. Excel answers "
        "'ID'; a kernel that ignored the argument answers 'CDXCIX' and looks "
        "like it works",
    )
    # --- ARABIC.
    _assert_num(xl_arabic(_t(String("MCMXII"))), 1912.0, "★ the SUBTRACTIVE rule: CM is 900, not 1100")
    _assert_num(xl_arabic(_t(String("CDXCIX"))), 499.0, "the canonical form round-trips")
    _assert_num(
        xl_arabic(_t(String("ID"))),
        499.0,
        "★★ A CONCISE FORM ROMAN NEVER EMITS. A kernel written as ROMAN's "
        "inverse refuses exactly the inputs this function exists to read",
    )
    _assert_num(xl_arabic(_t(String("mcmxii"))), 1912.0, "★ lower case is accepted")
    _assert_num(xl_arabic(_t(String(""))), 0.0, "the empty string is 0")
    _assert_num(xl_arabic(_t(String("-IV"))), -4.0, "★ a leading minus is Excel's documented behaviour")
    _assert_err(xl_arabic(_t(String("IZ"))), XL_ERR_VALUE, "★ a non-roman letter is #VALUE!")


def test_ISO_CEILING_is_CEILING_PRECISE_and_is_not_CEILING() raises:
    """⛔ THE POSITIVE CELL IS BLIND — every plausible kernel answers 3. Only
    the negative-significance cell separates `ISO.CEILING` from `CEILING`,
    whose direction comes from SIGN AGREEMENT."""
    _assert_num(xl_iso_ceiling(_nn(2.1, 1.0)), 3.0, "the BLIND cell: CEILING answers 3 too")
    _assert_num(
        xl_iso_ceiling(_nn(-2.1, -1.0)),
        -2.0,
        "★★ -2, where CEILING(-2.1,-1) is -3",
    )
    _assert_num(xl_ceiling(_nn(-2.1, -1.0)), -3.0, "★ the rival, on the same input, to prove the pair is a discriminator")
    _assert_num(xl_iso_ceiling(_n(4.3)), 5.0, "★ `significance` is OPTIONAL (default 1), where CEILING's is REQUIRED")


def test_DAYS360_has_two_methods_that_disagree_on_real_dates() raises:
    """⛔ A KERNEL THAT IGNORED THE METHOD ARGUMENT RETURNS A CONFIDENT WRONG
    INTEGER. Three inputs where US and EUROPEAN differ, each exercising a
    DIFFERENT clause of the US rule:

      (2026-01-15, 2026-03-31)  76 / 75  the end-date-to-NEXT-MONTH clause
      (2026-01-31, 2026-02-28)  30 / 28  US's last-day-of-February end
      (2026-02-28, 2026-03-31)  30 / 32  US's last-day-of-February START
    """
    var jan15 = Float64(_serial(2026, 1, 15))
    var jan31 = Float64(_serial(2026, 1, 31))
    var feb28 = Float64(_serial(2026, 2, 28))
    var mar31 = Float64(_serial(2026, 3, 31))
    _assert_num(xl_days360(_nn(jan15, mar31)), 76.0, "★★ US: end is last-of-month and start < 30, so end -> 1st of April")
    _assert_num(xl_days360(_nnn(jan15, mar31, 1.0)), 75.0, "★★ EUROPEAN: 31 -> 30 and nothing else")
    _assert_num(xl_days360(_nn(jan31, feb28)), 30.0, "★★ US: BOTH ends are last-of-month, so both become 30")
    _assert_num(xl_days360(_nnn(jan31, feb28, 1.0)), 28.0, "★★ EUROPEAN: only the 31 moves; 28 February is untouched")
    _assert_num(xl_days360(_nn(feb28, mar31)), 30.0, "★★ US: the START's last-of-February becomes 30")
    _assert_num(xl_days360(_nnn(feb28, mar31, 1.0)), 32.0, "★★ EUROPEAN: 28 stays 28, so the span is 32")
    # ⛔⛔ AND THE US RULE IS **NOT ANTISYMMETRIC**, WHICH IS THE PROPERTY
    # EVERY READER ASSUMES AND NOBODY CHECKS. DAYS360(a,b) is 76 and
    # DAYS360(b,a) is -75, because the two adjustments are applied to the
    # START and the END by POSITION, not by which date is earlier. A kernel
    # that computed `-DAYS360(b,a)` for a reversed pair would answer -76.
    _assert_num(
        xl_days360(_nn(mar31, jan15)),
        -75.0,
        "★★ the reversed pair is -75 and NOT -76: the US rule is "
        "order-dependent, so it is not the negative of the forward answer",
    )
    _assert_num(
        xl_days360(_nnn(mar31, jan15, 1.0)),
        -75.0,
        "★ EUROPEAN **IS** antisymmetric — 75 forward, -75 back — which is "
        "what makes the US row above a finding rather than an off-by-one",
    )
    # ⚠ A BOOLEAN `method` AND A NUMERIC ONE ARE THE SAME ARGUMENT: 0 is US.
    _assert_num(xl_days360(_nnn(jan15, mar31, 0.0)), 76.0, "method = 0 is US, same as omitted")


def test_TIMEVALUE_and_DATEVALUE_parse_the_locale_free_spelling_only() raises:
    """⚠ THE NARROWING IS THE ROW'S CONTENT. Every form that a locale could
    read two ways is `#VALUE!`, which is honest; a plausible number for the
    wrong reading is not."""
    # ⭐ THE CROSS-CHECK THAT MAKES THIS MORE THAN A SELF-CONSISTENT PARSE:
    # TIMEVALUE("13:30") must equal TIME(13,30,0), which a different kernel
    # computes from three numeric arguments.
    _assert_num(xl_timevalue(_t(String("13:30"))), 0.5625, "13:30 is 0.5625 of a day")
    _assert_num(
        xl_timevalue(_t(String("13:30"))),
        _time3(13.0, 30.0, 0.0).num,
        "★★ TIMEVALUE agrees with TIME, which is a DIFFERENT kernel reading "
        "three numbers",
    )
    _assert_num(xl_timevalue(_t(String("00:00:00"))), 0.0, "midnight is 0")
    _assert_num(xl_timevalue(_t(String("06:00:00"))), 0.25, "the seconds form")
    _assert_err(xl_timevalue(_t(String("1:30 PM"))), XL_ERR_VALUE, "★ the 12-hour form is REFUSED, not guessed at")
    _assert_err(xl_timevalue(_t(String("27:00"))), XL_ERR_VALUE, "★★ #VALUE! here where TIME(27,0,0) WRAPS — this one PARSES a clock reading")
    _assert_err(xl_timevalue(_t(String("13:60"))), XL_ERR_VALUE, "60 minutes is not a clock reading")
    _assert_err(xl_timevalue(_t(String("13.30"))), XL_ERR_VALUE, "a non-colon separator is refused")
    # --- DATEVALUE.
    _assert_num(
        xl_datevalue(_t(String("2026-09-14"))),
        Float64(_serial(2026, 9, 14)),
        "★★ the SERIAL from the same builder DATE uses — a hand-computed "
        "number here would be a second implementation of the thing under test",
    )
    _assert_num(
        xl_datevalue(_t(String("1900-03-01"))),
        61.0,
        "★★ THE LOTUS BUG IS PART OF THE CONTRACT: 61, not 60. A true "
        "proleptic day count is off by one against DATE(1900,3,1)",
    )
    _assert_err(xl_datevalue(_t(String("03/04/2026"))), XL_ERR_VALUE, "★★ the LOCALE-AMBIGUOUS form: 4 March in the UK, 3 April in the US")
    _assert_err(xl_datevalue(_t(String("2026-02-30"))), XL_ERR_VALUE, "★ 30 February is #VALUE!, NOT the rollover DATE(2026,2,30) gives")
    _assert_err(xl_datevalue(_t(String("2026-13-01"))), XL_ERR_VALUE, "month 13 is refused")
    _assert_err(xl_datevalue(_t(String("1899-12-31"))), XL_ERR_VALUE, "★ below Excel's serial space, and a negative serial is a number the sheet has none of")
    _assert_num(xl_datevalue(_t(String("2024-02-29"))), Float64(_serial(2024, 2, 29)), "★ a REAL leap day is accepted")
    _assert_err(xl_datevalue(_t(String("2026-02-29"))), XL_ERR_VALUE, "★ and a fake one is not")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
