# =============================================================================
# parse_float_f64: exponent saturation, bounded work, and correct rounding.
# =============================================================================
#
# Every check compares the exact bits of the result with the IEEE 754
# round-to-nearest-even answer (computed with exact rational arithmetic
# outside this test and spelled here as hex).
#
# What each test proves, and the defect it catches:
#   * test_exponent_saturates -- an exponent of 2^64 (1e18446744073709551616)
#     reads as +Inf and -1e-18446744073709551616 as -0.0. Catches an
#     exponent accumulated in a wrapping Int (2^64 wraps to 0 and the value
#     reads as 1.0). 1e30800 -> +Inf, 1(19 zeros)e-3300 -> +0.0 and
#     9e-3240 -> +0.0 pin the constant margin of the cap (the exponent
#     stops accumulating at the first prefix of its digits that reaches
#     the input length plus the margin). 1e30800 catches a margin
#     of 301 or less, 1(19 zeros)e-3300 one of 304 or less, and 9e-3240
#     one of 317 or less (it is held at 9e-324 for a margin from 26 to
#     317 and at 9e-32 below that, nonzero either way). A
#     margin of 318 is the smallest correct one: the shortest input that
#     needs the cap, 9e-<digits>, reads as zero only when input length
#     plus margin is at least 325.
#   * test_huge_exponent_bounded -- 1e999999999, -1e999999999 and
#     1e-999999999 read as +Inf, -Inf and +0.0. The scale comes from a
#     table lookup, not from one multiplication per unit of exponent, so
#     this completes inside the build action; a per-unit loop runs 10^9
#     iterations per value here (and the 2^64 case above would never end).
#   * test_digits_shift_the_exponent -- 0.(399 zeros)1e400 and 1(400
#     zeros)e-400 are both 1.0: the digit count and the decimal point move
#     the exponent, and the exponent part is combined with them exactly even
#     past the double range; 0.(9999 zeros)1e10000 and 1(10000
#     zeros)e-10000 are 1.0 too. Catches an exponent clamped before the
#     digit adjustment is applied, including a cap that does not grow with
#     the input length (a fixed cap of 1000 reads them as 0.0 and +Inf).
#   * test_range_edges -- 1e308, DBL_MAX and the two decimals either side of
#     the DBL_MAX/2^1024 midpoint, 4.9e-324 and 5e-324 (the smallest
#     subnormal), the two decimals either side of half of it, DBL_MIN and
#     the largest subnormal. Catches a scale built from repeated
#     multiplications (DBL_MAX read as 0x7FEFFFFFFFFFFFFD, 5e-324 as 0.0).
#   * test_ties_to_even -- 2^53+1 and 2^53+3 (both exact midpoints) round
#     to the even neighbour; 1e23, 0.1 and 0.30000000000000004 are exact.
#     The same tie written with a fraction, 9007199254740993.0 (q = -1)
#     and 9007199254740993.000 (q = -3), and 562949953421312.0625
#     (625 * (2^53+1) * 10^-4, q = -4, the lower edge of the range where
#     an exact tie can occur) also round to even. Catches an Eisel-Lemire
#     port without the round-to-even step, or with that step limited to
#     q >= 0.
#   * test_long_mantissas -- more than 19 significant digits, where the
#     truncated mantissa cannot decide the rounding: the exact midpoints
#     1 + 2^-53 and (2^54-1) * 2^970 (309 digits) tie to even; one unit
#     more or less in the last digit moves the result; 2^-1075 (752
#     digits) ties to 0.0 and goes to the smallest subnormal with a
#     trailing 1, also when that 1 is past the 800th significant digit
#     (in the integer part, and in the fraction part);
#     trailing zeros past it do not; the 768-digit midpoint between the
#     largest subnormal and DBL_MIN ties to DBL_MIN, and one unit lower in
#     its last digit reads the largest subnormal. Catches a parser that
#     rounds a truncated mantissa without an exact fallback, and a digit
#     cap in the fallback below the 768 digits that midpoint needs.
#   * test_eisel_lemire_matches_exact -- 20000 pseudo-random (w, q), w up
#     to 19 digits and q over the whole table: decimal_to_f64(w, q) is the
#     double r with mid(prev(r), r) < w * 10^q < mid(r, next(r)) (ties to
#     the even one), decided in exact integers by round_long_decimal.
#     Catches a wrong table entry, exponent formula or a missing
#     second-product refinement (the truncated 5^q carry).
#   * test_grammar_unchanged -- the error text for the malformed inputs and
#     the leading `+`, leading zeros and signed zeros that the parser
#     accepted before.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_jsonl.value_parsers.float_decimal_to_f64 import decimal_to_f64
from komira_jsonl.value_parsers.float_long_decimal import round_long_decimal
from komira_jsonl.value_parsers.parse_float import parse_float_f64


def _bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64, 1](v)


def _hex(v: UInt64) -> String:
    comptime digits = "0123456789ABCDEF"
    var out = String("0x")
    for k in range(16):
        var nib = Int((v >> UInt64(60 - 4 * k)) & UInt64(0xF))
        out += String(digits[byte=nib])
    return out


def _check(text: String, want: UInt64) raises:
    var b = text.as_bytes()
    var got = _bits(parse_float_f64(b, 0, len(b)))
    var label = text
    if text.byte_length() > 60:
        label = String(text[byte=0:60]) + "...(" + String(text.byte_length()) + " bytes)"
    assert_equal(_hex(got), _hex(want), label)


def _zeros(n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += "0"
    return s^


comptime POS_INF: UInt64 = 0x7FF0000000000000
comptime NEG_INF: UInt64 = 0xFFF0000000000000
comptime POS_ZERO: UInt64 = 0x0000000000000000
comptime NEG_ZERO: UInt64 = 0x8000000000000000
comptime ONE: UInt64 = 0x3FF0000000000000
comptime DBL_MAX: UInt64 = 0x7FEFFFFFFFFFFFFF


def test_exponent_saturates() raises:
    print("test_exponent_saturates")
    _check("1e18446744073709551616", POS_INF)
    _check("-1e-18446744073709551616", NEG_ZERO)
    _check("1e-18446744073709551616", POS_ZERO)
    _check("-1e18446744073709551616", NEG_INF)
    # 2^64 + 1: wraps to exponent 1 (10.0) in a 64-bit accumulator.
    _check("1e18446744073709551617", POS_INF)
    # A hundred exponent digits.
    _check("1e1" + _zeros(99), POS_INF)
    _check("1e-1" + _zeros(99), POS_ZERO)
    # Leading zeros in the exponent are not magnitude: 1e(99 zeros)1 is 10.
    _check("1e" + _zeros(99) + "1", 0x4024000000000000)
    _check("1e-" + _zeros(99) + "1", 0x3FB999999999999A)
    # The constant part of the cap: the exponent stops accumulating at the
    # first prefix of its digits that reaches the input length plus a
    # margin, and that margin must carry the value past +-1000 (beyond
    # DBL_MAX and below half the smallest subnormal). With a margin of 300
    # the first two exponents are held inside the double range and read as
    # finite values (1e30800 as 1e308, 1(19 zeros)e-3300 as a subnormal);
    # they must read as +Inf and +0.0. With any margin from 305 to 317 both
    # of those still read correctly, but 9e-3240 (7 bytes) is held at
    # 9e-324 (the prefix 324) for every margin from 26 to 317 (at 9e-32,
    # the prefix 32, below that), a nonzero value; it must read as +0.0.
    _check("1e30800", POS_INF)
    _check("1" + _zeros(19) + "e-3300", POS_ZERO)
    _check("9e-3240", POS_ZERO)


def test_huge_exponent_bounded() raises:
    print("test_huge_exponent_bounded")
    _check("1e999999999", POS_INF)
    _check("-1e999999999", NEG_INF)
    _check("1e-999999999", POS_ZERO)
    _check("-1e-999999999", NEG_ZERO)
    _check("0e999999999", POS_ZERO)
    _check("-0.0e-999999999", NEG_ZERO)


def test_digits_shift_the_exponent() raises:
    print("test_digits_shift_the_exponent")
    _check("0." + _zeros(399) + "1e400", ONE)
    _check("1" + _zeros(400) + "e-400", ONE)
    _check("-0." + _zeros(399) + "1e400", 0xBFF0000000000000)
    # 400 leading zeros before the point do not move it.
    _check(_zeros(400) + "1.5", 0x3FF8000000000000)
    # 10^308 spelled with 300 fraction zeros: 0.(300 zeros)1e609.
    _check("0." + _zeros(300) + "1e609", 0x7FE1CCF385EBC8A0)
    # Digit shifts larger than 1000: the exponent cap must grow with the
    # input length, or 1e10000 is held below 10000 before the shift of the
    # 9999 fraction zeros (or the 10000 integer zeros) brings it back.
    _check("0." + _zeros(9999) + "1e10000", ONE)
    _check("1" + _zeros(10000) + "e-10000", ONE)


def test_range_edges() raises:
    print("test_range_edges")
    _check("1e308", 0x7FE1CCF385EBC8A0)
    _check("1.7976931348623157e308", DBL_MAX)
    _check("-1.7976931348623157e308", 0xFFEFFFFFFFFFFFFF)
    _check("1.7976931348623157e+308", DBL_MAX)
    _check("1.7976931348623158e308", DBL_MAX)
    _check("1.7976931348623159e308", POS_INF)
    _check("4.9e-324", 0x0000000000000001)
    _check("5e-324", 0x0000000000000001)
    _check("-5e-324", 0x8000000000000001)
    _check("2.4703282292062327e-324", POS_ZERO)
    _check("2.4703282292062328e-324", 0x0000000000000001)
    _check("2.225073858507201e-308", 0x000FFFFFFFFFFFFF)
    _check("2.2250738585072011e-308", 0x000FFFFFFFFFFFFF)
    _check("2.2250738585072012e-308", 0x0010000000000000)
    _check("2.2250738585072014e-308", 0x0010000000000000)
    _check("4.35679e-310", 0x00005033914D5594)
    _check("1e400", POS_INF)
    _check("1e-400", POS_ZERO)


def test_ties_to_even() raises:
    print("test_ties_to_even")
    _check("9007199254740993", 0x4340000000000000)
    _check("9007199254740995", 0x4340000000000002)
    # Exact ties with a negative decimal exponent q (w * 10^q, q in [-4, -1]).
    _check("9007199254740993.0", 0x4340000000000000)
    _check("9007199254740993.000", 0x4340000000000000)
    _check("562949953421312.0625", 0x4300000000000000)
    _check("1.8014398509481988e+16", 0x4350000000000001)
    _check("1.801439850948199e+16", 0x4350000000000002)
    _check("1e23", 0x44B52D02C7E14AF6)
    _check("1e22", 0x4480F0CF064DD592)
    _check("1e-22", 0x3B5E392010175EE6)
    _check("0.1", 0x3FB999999999999A)
    _check("0.30000000000000004", 0x3FD3333333333334)
    _check("3.14159265358979323846", 0x400921FB54442D18)
    _check("123456789012345678901234567890", 0x45F8EE90FF6C373E)


def _half_min_subnormal_digits() -> String:
    """The 752 significant digits of 2^-1075 (= digits * 10^-1075)."""
    return (
        String("2470328229206232720882843964341106861825299013071623822127928412503377536351")
        + "0437593264991818081799618989828234772285886546332835517796989819938739800539"
        + "0939063150356595155702263922908583924491051844359318028499365361525003193704"
        + "5767824921936562366986365848075700158576926990370631192827955855133292783433"
        + "8409351978015531246597263579574622766465272827220056374006485499977096599470"
        + "4540208281662262378573934507363390079677619305775067401763246736009689513405"
        + "3553745851666113422376667860416215968046191446729184030053005753084904876539"
        + "1711386591646239524912623653881879636239373280423891018672348497668235089863"
        + "3885879256283027559956575244555072551893136908362547791869486679949683240497"
        + "05821028513185451396213837722826145437693412532098591327667236328125"
    )


def _dbl_min_midpoint_digits() -> String:
    """The 768 significant digits of (2^53 - 1) * 2^-1075 (= digits *
    10^-1075), the midpoint between the largest subnormal (odd mantissa)
    and DBL_MIN."""
    return (
        String("2225073858507201136057409796709131975934819546351645648023426109724822222021")
        + "0769455165295239081350879141491589130396211068700864386945946455276572074078"
        + "2062174337998814106326732925355228688137214901298112245145188984905722230728"
        + "5255133155755015914397476397983411801999323962548289017107081850690630666655"
        + "9949382757725720157630626906633326475653000092458883164330377797918696120494"
        + "9739037782970490505108060994073026293712895895000358379996720725430436028407"
        + "8895771796150945516748243471030702609144621572289880258182545180325707018860"
        + "8721131280795122334262883686223215037756666225039825343359745688844239002654"
        + "9819838548794829220689472168983109969836584681402285424333066033985088644580"
        + "4001034933970427567186443383770486037861622771738545623065874679014086723327"
        + "63671875"
    )


comptime _DBL_MAX_MIDPOINT = (
    "17976931348623158079372897140530341507993413271003782693617377898044496829276475094664901797758720709633028641669288791094655554785194040263065748867150582068190890200070838367627385484581771153176447573027006985557136695962284291481986083493647529271907416844436551070434271155969950809304288017790417449779"
)
"""(2^54 - 1) * 2^970 without its last digit (2): the midpoint between
DBL_MAX and 2^1024 is this followed by "2"."""


def test_long_mantissas() raises:
    print("test_long_mantissas")
    _check("1.00000000000000011102230246251565404236316680908203125", ONE)
    _check("1.000000000000000111022302462515654042363166809082031251", 0x3FF0000000000001)
    _check("1.00000000000000011102230246251565404236316680908203124", ONE)
    _check("9007199254740993.0000000000000000001", 0x4340000000000001)
    _check("9007199254740992.9999999999999999999", 0x4340000000000000)
    _check(String(_DBL_MAX_MIDPOINT) + "2", POS_INF)
    _check(String(_DBL_MAX_MIDPOINT) + "1", DBL_MAX)
    _check(String(_DBL_MAX_MIDPOINT) + "2.000000000000000000000001", POS_INF)
    _check(String(_DBL_MAX_MIDPOINT) + "1.999999999999999999999999", DBL_MAX)
    var h = _half_min_subnormal_digits()
    _check(h + "e-1075", POS_ZERO)
    _check("0." + _zeros(323) + h, POS_ZERO)
    _check("-0." + _zeros(323) + h, NEG_ZERO)
    _check(h + "1e-1076", 0x0000000000000001)
    _check("0." + _zeros(323) + h + "1", 0x0000000000000001)
    # The 1 past the 800th significant digit still counts ...
    _check(h + _zeros(100) + "1e-1176", 0x0000000000000001)
    _check("0." + _zeros(323) + h + _zeros(100) + "1", 0x0000000000000001)
    # ... and zeros past it do not.
    _check(h + _zeros(100) + "e-1175", POS_ZERO)
    _check("0." + _zeros(323) + h + _zeros(200), POS_ZERO)
    # The midpoint below DBL_MIN needs 768 digits to decide: on it, ties
    # go to the even DBL_MIN; one unit lower in the last digit, to the
    # largest subnormal. A digit cap under 768 truncates the midpoint
    # below itself and reads the largest subnormal for both.
    var mid = _dbl_min_midpoint_digits()
    _check(mid + "e-1075", 0x0010000000000000)
    _check(String(mid[byte=0:767]) + "4e-1075", 0x000FFFFFFFFFFFFF)
    _check(String(mid[byte=0:767]) + "6e-1075", 0x0010000000000000)
    # 24 significant digits, all exact after the 19th (zeros).
    _check("1.00000000000000000000000", ONE)
    _check("100000000000000000000000e-23", ONE)


def _xorshift(mut s: UInt64) -> UInt64:
    s ^= s << UInt64(13)
    s ^= s >> UInt64(7)
    s ^= s << UInt64(17)
    return s


def test_eisel_lemire_matches_exact() raises:
    print("test_eisel_lemire_matches_exact")
    var state = UInt64(0x9E3779B97F4A7C15)
    var checked = 0
    for k in range(20000):
        var w = _xorshift(state) % UInt64(10000000000000000000)
        # Every fourth sample keeps fewer digits (short mantissas).
        if k % 4 == 0:
            w = w >> (_xorshift(state) % UInt64(60))
        if w == UInt64(0):
            w = UInt64(1)
        var q = Int(_xorshift(state) % UInt64(651)) - 342
        var r = decimal_to_f64(w, q)
        var rb = _bits(r)
        if rb == UInt64(0) or rb >= UInt64(0x7FF0000000000000):
            continue  # zero or Inf: no neighbour below to compare with
        var text = String(w)
        var b = text.as_bytes()
        var n = len(b)
        var prev = bitcast[DType.float64, 1](rb - UInt64(1))
        var from_prev = round_long_decimal(b, 0, n, n, n, q, prev)
        var from_r = round_long_decimal(b, 0, n, n, n, q, r)
        if _bits(from_prev) != rb or _bits(from_r) != rb:
            raise Error(
                "decimal_to_f64(" + text + ", " + String(q) + ") = "
                + _hex(rb) + "; exact rounding gives " + _hex(_bits(from_prev))
                + " / " + _hex(_bits(from_r))
            )
        checked += 1
    assert_true(checked > 15000, "too few finite samples: " + String(checked))


def _check_raises(text: String, want: String) raises:
    var b = text.as_bytes()
    var msg = String("")
    try:
        var _v = parse_float_f64(b, 0, len(b))
    except e:
        msg = String(e)
    assert_equal(msg, want, text)


def test_grammar_unchanged() raises:
    print("test_grammar_unchanged")
    _check_raises("", "parse_float_f64: empty byte range")
    _check_raises("-", "parse_float_f64: lone sign without digits")
    _check_raises("x1", "parse_float_f64: non-digit at integer start, position 0")
    _check_raises("1.", "parse_float_f64: '.' must be followed by digits at position 2")
    _check_raises("1e", "parse_float_f64: 'e'/'E' must be followed by digits at position 2")
    _check_raises("1e+", "parse_float_f64: 'e'/'E' must be followed by digits at position 3")
    _check_raises("1.5x", "parse_float_f64: trailing non-numeric content at position 3")
    _check_raises("1e5x", "parse_float_f64: trailing non-numeric content at position 3")
    _check("+1.5", 0x3FF8000000000000)
    _check("007", 0x401C000000000000)
    _check("-0", NEG_ZERO)
    _check("-0.0", NEG_ZERO)
    _check("0.0", POS_ZERO)
    _check("1E2", 0x4059000000000000)
    _check("1e+2", 0x4059000000000000)
    # A sub-range of a larger buffer.
    var s = String("[12.5e-1,9]")
    var b = s.as_bytes()
    assert_true(parse_float_f64(b, 1, 8) == 1.25)


def main() raises:
    test_exponent_saturates()
    test_huge_exponent_bounded()
    test_digits_shift_the_exponent()
    test_range_edges()
    test_ties_to_even()
    test_long_mantissas()
    test_eisel_lemire_matches_exact()
    test_grammar_unchanged()
    print("test_parse_float_exponent: ALL PASS")
