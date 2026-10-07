# =============================================================================
# test_proto_codec_json_float64.mojo — a proto3 `double` field in canonical
# JSON: read correctly rounded at any length, refused past the double range,
# and written so that every value the reader returns reads back as itself.
# =============================================================================
#
# Every expected value is an exact bit pattern (`_bits`), computed with an
# arbitrary-precision decimal reference.
#
# WHAT EACH LEG PROVES, and the defect it catches:
#   R1  the JSONTestSuite literal y_number_double_close_to_zero (an 80-digit
#       -0.000...0001, i.e. -1e-78) reads as the nearest double, as a number
#       and as a numeric string. Catches: the standard library's `atof`,
#       which refuses a literal this long ("String is not convertible to
#       float").
#   R2  mantissas of 30 to 90 digits (the JSONTestSuite i_number_too_big_*
#       and i_number_very_big_negative_int literals among them) read as the
#       nearest double. Catches: a digit-count limit in the reader.
#   R3  correct rounding: the exact midpoint 1 + 2^-53 ties to even (1.0),
#       one unit in the 55th digit either side goes down / up, a nonzero
#       digit dropped past the 800th significant digit lifts the midpoint
#       to 1 + 2^-52 whether it is dropped from the fraction or from the
#       integer part (955 integer digits, then e-954), and with that digit
#       zero the integer-part form still ties to even, the exact
#       1 + 2^-53 + 2^-55 goes up (its excess is a bit shifted out of the
#       quotient, not a division remainder) and 1 + 2^-53 - 2^-55 goes down,
#       2^53 + 1 and 2^53 + 3 tie to even, and the 768-digit midpoint between two
#       subnormals ties to even, goes up with a nonzero digit 829 places in,
#       and down one unit in its last digit. Catches: a reader that rounds
#       twice or truncates, a shifted-out bit that never reaches the sticky
#       flag, a dropped digit that never sets the tail flag in either the
#       integer or the fraction loop, and a significant-digit cap below 768 in
#       either loop (the cap drops the midpoint's last digits, so the midpoint
#       plus a nonzero digit 829 places in, written as a fraction or as an
#       integer, reads below the midpoint and rounds down).
#   R4  subnormals and zeros: 5e-324, 4.9e-324, 2.5e-324 and 3e-324 are the
#       smallest subnormal, 2^-1075 exactly (752 digits) ties to +0.0 and
#       with a nonzero digit 853 places in is the smallest subnormal, the
#       largest subnormal and the smallest normal are told apart, and "-0",
#       "-0.0", "-1e-400", "-2.4703282292062327e-324" are -0.0. Catches: a
#       flush-to-zero, the wrong rounding at the bottom of the range, and a
#       dropped sign.
#   R5  range: the largest double reads bit-exact from its 17-digit form,
#       from 1.7976931348623158e308 and from the 309-digit T - 1
#       (T = 2^1024 - 2^970); T itself, 1.7976931348623159e308,
#       1.89769e+308 (protobuf's DoubleFieldTooLarge conformance case),
#       1e309, 1e400, their negatives, the string form and a repeated
#       element are REFUSED with "value out of double range". Catches:
#       reading an out-of-range number as an infinity (the old reader), and
#       an off-by-one at the overflow midpoint.
#   R6  exponents: 1e18446744073709551616 (2^64, which wraps a 64-bit
#       accumulator to 1e0) and 1e999999999 are refused, their negatives are
#       zeros, 0e18446744073709551616 is 0.0, a 50-digit exponent saturates,
#       an exponent offset by a million leading zeros (or 400 integer
#       zeros) is an ordinary 1.0, and a 4101-digit integer is refused while
#       4101 fraction digits are a zero. Catches: an exponent that wraps, a
#       fixed exponent cap that misreads the offset cases, and a missing
#       small-magnitude early-out (10^4101 wraps to 0 in the
#       4096-bit integers, the division then reads as all ones, and
#       10^-4101 is refused as out of range instead of read as 0.0).
#   R7  only the three spec spellings name a non-finite value ("inf", "nan",
#       "infinity", "-inf" are refused), numeric strings follow JSON number
#       syntax (" 1.5", "+1.5", ".5", "1.", "1e", "" are refused; "1E+2" is
#       100.0), and a bool is refused. Catches: `atof`'s lenient spellings.
#   W1  NaN / +Inf / -Inf write as the strings "NaN" / "Infinity" /
#       "-Infinity" in a field and a repeated element, and read back.
#       Catches: writing `null`, which reads back as an absent field (0.0).
#   W2  extremes round-trip bit-exactly through encode_json / decode_json
#       (max, smallest normal, largest and smallest subnormal, -0.0, 0.1, -1.5,
#       1e23, 0.30000000000000004). Catches: a reader and a writer that
#       disagree on a value the reader accepts.
#   F1  the fast path (15 digits or fewer, |exponent| <= 22) agrees with
#       the exact path on its edge values (1e22, 123456789012345e-22, 7e-10),
#       and values just outside it (3e23, 1e-23, a 16-digit 0.97...) are
#       exact; short negatives (-1.5, -0.1) keep their sign; and the exact
#       midpoint 4.73e21 followed by a nonzero digit 900 places in reads
#       above the midpoint. Catches: a fast path taken past the range where
#       one IEEE operation is exact (each of those three reads wrong through
#       it), a fast path that drops the sign, and a fast path taken when a
#       nonzero tail past the kept digits was dropped.
# =============================================================================

from std.math import isinf, isnan
from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    decode_json,
    encode_json,
    parse_decimal_f64,
)


@fieldwise_init
struct F64One(Serializable):
    """`message F64One { double v = 1; }`."""

    var v: Float64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_f64_field(1, "v", self.v)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Float64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "v":
                v = dec.read_f64()
            else:
                dec.skip()
        return F64One(v)


@fieldwise_init
struct F64List(Serializable):
    """`message F64List { repeated double vs = 1; }`."""

    var vs: List[Float64]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.begin_list_field(1, "vs")
        for i in range(len(self.vs)):
            enc.write_f64_element(1, self.vs[i])
        enc.end_list_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var vs = List[Float64]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "vs":
                dec.read_into_repeated_f64(vs)
            else:
                dec.skip()
        return F64List(vs^)


def _f(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64](v)


comptime MAX_BITS = UInt64(0x7FEFFFFFFFFFFFFF)
comptime MIN_NORMAL_BITS = UInt64(0x0010000000000000)
comptime MAX_SUBNORMAL_BITS = UInt64(0x000FFFFFFFFFFFFF)
comptime MIN_SUBNORMAL_BITS = UInt64(0x0000000000000001)
comptime NEG_ZERO_BITS = UInt64(0x8000000000000000)
comptime ONE_BITS = UInt64(0x3FF0000000000000)


def _read(doc: String) raises -> UInt64:
    """The bits of field `v` decoded from `{"v":<doc>}`."""
    return _bits(decode_json[F64One]('{"v":' + doc + "}").v)


def _expect_read(doc: String, bits: UInt64, what: String) raises:
    assert_equal(_read(doc), bits, what)
    # The same literal through the reader directly (a number's text).
    if not doc.startswith('"'):
        assert_equal(_bits(parse_decimal_f64(doc)), bits, what + " (direct)")


def _expect_refused(doc: String, message: String, what: String) raises:
    """Decoding `{"v":<doc>}` raises exactly `message`."""
    var refused = False
    try:
        _ = decode_json[F64One]('{"v":' + doc + "}")
    except e:
        refused = True
        assert_equal(String(e), message, what)
    assert_true(refused, what + ": " + doc + " must be refused")


def _range_error(text: String) -> String:
    return "JsonError: value out of double range: " + text


def _syntax_error(text: String) -> String:
    return "JsonError: not a proto3 double: " + text


def _zeros(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "0"
    return s^


def _half_min_sub_digits() -> String:
    """The 752 significant digits of 2^-1075 (half the smallest subnormal),
    after its 323 leading fraction zeros."""
    var s = String("")
    s += "247032822920623272088284396434110686182529901307162382212792"
    s += "841250337753635104375932649918180817996189898282347722858865"
    s += "463328355177969898199387398005390939063150356595155702263922"
    s += "908583924491051844359318028499365361525003193704576782492193"
    s += "656236698636584807570015857692699037063119282795585513329278"
    s += "343384093519780155312465972635795746227664652728272200563740"
    s += "064854999770965994704540208281662262378573934507363390079677"
    s += "619305775067401763246736009689513405355374585166611342237666"
    s += "786041621596804619144672918403005300575308490487653917113865"
    s += "916462395249126236538818796362393732804238910186723484976682"
    s += "350898633885879256283027559956575244555072551893136908362547"
    s += "791869486679949683240497058210285131854513962138377228261454"
    s += "37693412532098591327667236328125"
    return s^


def _mid_ffe_head() -> String:
    """The first 767 of the 768 significant digits of
    (2 * 0xFFFFFFFFFFFFE + 1) * 2^-1075, the midpoint between the subnormals
    0x000FFFFFFFFFFFFE and 0x000FFFFFFFFFFFFF, after its 307 leading fraction
    zeros; its last digit is 5."""
    var s = String("")
    s += "222507385850720064199176395546258779936602667813027328296362"
    s += "349540005779643539444484102225369938322261431279727704724131"
    s += "030539099297686371887094685146802422296858397735918514102854"
    s += "036197547684430319581327346934820113042116530855453208314936"
    s += "760676083249201067093840472615434740825730172168377656439210"
    s += "106482391161721588524757602313035270771562002841775343298712"
    s += "758123539074213191978739083589771549597066404661620550578925"
    s += "994422322342444472859570416955675758542375241712413480599907"
    s += "313780801813381104948904668664894425583448890100825972149614"
    s += "710420439919855653569753100552319354486638980954850896040660"
    s += "352681852824502078615102443513620912377597978521535770387775"
    s += "045705684361475530270683064113556748943345076587312006145811"
    s += "35848683152156368691976240370422601699829101562"
    return s^


def _overflow_t() -> String:
    """T = 2^1024 - 2^970, the midpoint between the largest double and
    2^1024 (it ties to the even 2^1024, so it is out of range)."""
    var s = String("")
    s += "179769313486231580793728971405303415079934132710037826936173"
    s += "778980444968292764750946649017977587207096330286416692887910"
    s += "946555547851940402630657488671505820681908902000708383676273"
    s += "854845817711531764475730270069855571366959622842914819860834"
    s += "936475292719074168444365510704342711559699508093042880177904"
    s += "174497792"
    return s^


def _overflow_t_minus_1() -> String:
    """T - 1, which rounds down to the largest double."""
    var s = String("")
    s += "179769313486231580793728971405303415079934132710037826936173"
    s += "778980444968292764750946649017977587207096330286416692887910"
    s += "946555547851940402630657488671505820681908902000708383676273"
    s += "854845817711531764475730270069855571366959622842914819860834"
    s += "936475292719074168444365510704342711559699508093042880177904"
    s += "174497791"
    return s^


def test_r1_jsontestsuite_close_to_zero() raises:
    var lit = "-0." + _zeros(77) + "1"
    assert_equal(
        lit.byte_length(), 81, "the y_number_double_close_to_zero literal"
    )
    _expect_read(lit, UInt64(0xAFBDA48CE468E7C7), "-1e-78 as 80 digits")
    _expect_read('"' + lit + '"', UInt64(0xAFBDA48CE468E7C7), "as a string")
    print("  test_r1_jsontestsuite_close_to_zero: PASS")


def test_r2_long_mantissas() raises:
    var ninety = String("")
    for _ in range(9):
        ninety += "1234567890"
    _expect_read(ninety, UInt64(0x526F07C2FAE1AB2C), "90-digit integer")
    _expect_read(
        "-237462374673276894279832749832423479823246327846",
        UInt64(0xC9C4CC172FF39C42),
        "i_number_very_big_negative_int",
    )
    _expect_read(
        "-123123123123123123123123123123",
        UInt64(0xC5F8DD50F76AA1DC),
        "i_number_too_big_neg_int",
    )
    _expect_read(
        "1" + _zeros(100) + "e-100", ONE_BITS, "101 digits that are 1.0"
    )
    print("  test_r2_long_mantissas: PASS")


def test_r3_correct_rounding() raises:
    var mid = "1.00000000000000011102230246251565404236316680908203125"
    _expect_read(mid, ONE_BITS, "1 + 2^-53 ties to even")
    _expect_read(
        "1.00000000000000011102230246251565404236316680908203124",
        ONE_BITS,
        "just below 1 + 2^-53",
    )
    _expect_read(
        "1.00000000000000011102230246251565404236316680908203126",
        UInt64(0x3FF0000000000001),
        "just above 1 + 2^-53",
    )
    _expect_read(mid + _zeros(900) + "1", UInt64(0x3FF0000000000001), "a tail")
    var mid_int = "100000000000000011102230246251565404236316680908203125"
    _expect_read(
        mid_int + _zeros(900) + "1e-954",
        UInt64(0x3FF0000000000001),
        "an integer-part tail past the 800th digit",
    )
    _expect_read(
        mid_int + _zeros(901) + "e-954",
        ONE_BITS,
        "955 integer digits that are the midpoint tie to even",
    )
    # 1 + 2^-53 + 2^-55 exactly: above the midpoint by a binary-exact amount
    # that the division leaves in q's lowest bit, which normalisation shifts
    # out; that bit must reach the sticky flag. Its mirror 1 + 2^-53 - 2^-55
    # is below the midpoint.
    _expect_read(
        "1.0000000000000001387778780781445675529539585113525390625",
        UInt64(0x3FF0000000000001),
        "1 + 2^-53 + 2^-55 (shifted-out sticky bit)",
    )
    _expect_read(
        "1.0000000000000000832667268468867405317723751068115234375",
        ONE_BITS,
        "1 + 2^-53 - 2^-55",
    )
    _expect_read(
        "9007199254740993", UInt64(0x4340000000000000), "2^53 + 1 ties down"
    )
    _expect_read(
        "9007199254740995", UInt64(0x4340000000000002), "2^53 + 3 ties up"
    )
    var m = _mid_ffe_head() + "5"
    assert_equal(
        m.byte_length(), 768, "the midpoint has 768 significant digits"
    )
    var p = "0." + _zeros(307)
    _expect_read(p + m, UInt64(0x000FFFFFFFFFFFFE), "768-digit midpoint")
    _expect_read(
        p + m + _zeros(60) + "1",
        MAX_SUBNORMAL_BITS,
        "768-digit midpoint, nonzero digit 829 places in",
    )
    _expect_read(
        m + _zeros(60) + "1e-1136",
        MAX_SUBNORMAL_BITS,
        "768-digit midpoint as an integer, nonzero digit 829 places in",
    )
    _expect_read(
        p + _mid_ffe_head() + "4", UInt64(0x000FFFFFFFFFFFFE), "just below it"
    )
    print("  test_r3_correct_rounding: PASS")


def test_r4_subnormals_and_zeros() raises:
    _expect_read("5e-324", MIN_SUBNORMAL_BITS, "5e-324")
    _expect_read("4.9e-324", MIN_SUBNORMAL_BITS, "4.9e-324")
    _expect_read("2.5e-324", MIN_SUBNORMAL_BITS, "2.5e-324")
    _expect_read("3e-324", MIN_SUBNORMAL_BITS, "3e-324")
    _expect_read("-5e-324", UInt64(0x8000000000000001), "-5e-324")
    _expect_read("5e-310", UInt64(0x00005C0AB9347ED7), "5e-310")
    var h = _half_min_sub_digits()
    assert_equal(h.byte_length(), 752, "2^-1075 has 752 significant digits")
    var p = "0." + _zeros(323)
    _expect_read(p + h, UInt64(0), "2^-1075 ties to +0.0")
    _expect_read(
        p + h + _zeros(100) + "1",
        MIN_SUBNORMAL_BITS,
        "2^-1075 and a nonzero digit 853 places in",
    )
    _expect_read(
        "-2.4703282292062327e-324", NEG_ZERO_BITS, "just below -2^-1075"
    )
    _expect_read(
        "2.2250738585072014e-308", MIN_NORMAL_BITS, "the smallest normal"
    )
    _expect_read(
        "2.2250738585072012e-308", MIN_NORMAL_BITS, "rounds up to it"
    )
    _expect_read(
        "2.2250738585072011e-308", MAX_SUBNORMAL_BITS, "the largest subnormal"
    )
    _expect_read(
        "4.4501477170144023e-308", UInt64(0x001FFFFFFFFFFFFF), "binade top"
    )
    _expect_read("-0", NEG_ZERO_BITS, "-0")
    _expect_read("-0.0", NEG_ZERO_BITS, "-0.0")
    _expect_read('"-0.0"', NEG_ZERO_BITS, "-0.0 as a string")
    _expect_read("-1e-400", NEG_ZERO_BITS, "-1e-400")
    _expect_read("0", UInt64(0), "0")
    print("  test_r4_subnormals_and_zeros: PASS")


def test_r5_range() raises:
    _expect_read("1.7976931348623157e308", MAX_BITS, "max")
    _expect_read("-1.7976931348623157e308", MAX_BITS | NEG_ZERO_BITS, "-max")
    _expect_read("1.7976931348623158e308", MAX_BITS, "rounds down to max")
    var t = _overflow_t()
    assert_equal(t.byte_length(), 309, "T has 309 digits")
    _expect_read(_overflow_t_minus_1(), MAX_BITS, "T - 1 is max")
    _expect_refused(t, _range_error(t), "T ties to 2^1024")
    _expect_refused("-" + t, _range_error("-" + t), "-T")
    _expect_refused(
        "1.7976931348623159e308",
        _range_error("1.7976931348623159e308"),
        "just past T",
    )
    _expect_refused(
        "1.89769e+308",
        _range_error("1.89769e+308"),
        "protobuf DoubleFieldTooLarge",
    )
    _expect_refused(
        "-1.89769e+308",
        _range_error("-1.89769e+308"),
        "protobuf DoubleFieldTooSmall",
    )
    _expect_refused("1e309", _range_error("1e309"), "1e309")
    _expect_refused("1e400", _range_error("1e400"), "1e400")
    _expect_refused("-1e400", _range_error("-1e400"), "-1e400")
    _expect_refused('"1e400"', _range_error("1e400"), "1e400 as a string")
    var refused = False
    try:
        _ = decode_json[F64List]('{"vs":[1.5,1e400]}')
    except e:
        refused = True
        assert_equal(String(e), _range_error("1e400"), "repeated element")
    assert_true(refused, "a repeated 1e400 must be refused")
    print("  test_r5_range: PASS")


def test_r6_exponents() raises:
    var wrap = "1e18446744073709551616"
    _expect_refused(wrap, _range_error(wrap), "exponent 2^64")
    _expect_read("1e-18446744073709551616", UInt64(0), "exponent -2^64")
    _expect_read("0e18446744073709551616", UInt64(0), "zero, exponent 2^64")
    _expect_refused("1e999999999", _range_error("1e999999999"), "1e999999999")
    _expect_read("-1e-999999999", NEG_ZERO_BITS, "-1e-999999999")
    var fifty = "1e" + _zeros(30) + "99999999999999999999"
    _expect_refused(fifty, _range_error(fifty), "a 50-digit exponent")
    _expect_read("1" + _zeros(400) + "e-400", ONE_BITS, "400 integer zeros")
    # 4101 digits either side of the point: the value's magnitude, not the
    # big integers' 4096 bits, decides (10^4100 is past the double range,
    # 10^-4101 is a zero).
    var huge = "1" + _zeros(4100)
    _expect_refused(huge, _range_error(huge), "a 4101-digit integer")
    _expect_read("0." + _zeros(4100) + "1", UInt64(0), "4101 fraction digits")
    _expect_read(
        "0." + _zeros(1000001) + "1e1000002", ONE_BITS, "a million zeros"
    )
    _expect_read(
        "1" + _zeros(1000000) + "e-1000000", ONE_BITS, "a million int zeros"
    )
    print("  test_r6_exponents: PASS")


def test_r7_spellings() raises:
    _expect_refused('"inf"', _syntax_error("inf"), "inf")
    _expect_refused('"-inf"', _syntax_error("-inf"), "-inf")
    _expect_refused('"nan"', _syntax_error("nan"), "nan")
    _expect_refused('"infinity"', _syntax_error("infinity"), "infinity")
    _expect_refused('" 1.5"', _syntax_error(" 1.5"), "leading space")
    _expect_refused('"+1.5"', _syntax_error("+1.5"), "leading plus")
    _expect_refused('".5"', _syntax_error(".5"), "no integer digit")
    _expect_refused('"1."', _syntax_error("1."), "no fraction digit")
    _expect_refused('"1e"', _syntax_error("1e"), "no exponent digit")
    _expect_refused('""', _syntax_error(""), "empty string")
    _expect_refused(
        "true", "JsonError: as_float64() on a non-numeric value", "a bool"
    )
    _expect_read('"1E+2"', UInt64(0x4059000000000000), "1E+2 as a string")
    print("  test_r7_spellings: PASS")


def test_w1_non_finite_strings() raises:
    var inf = _f(UInt64(0x7FF0000000000000))
    var nan = _f(UInt64(0x7FF8000000000000))
    assert_equal(encode_json(F64One(nan)), String('{"v":"NaN"}'), "NaN")
    assert_equal(encode_json(F64One(inf)), String('{"v":"Infinity"}'), "inf")
    assert_equal(
        encode_json(F64One(-inf)), String('{"v":"-Infinity"}'), "-inf"
    )
    var vs = List[Float64]()
    vs.append(nan)
    vs.append(inf)
    vs.append(-inf)
    vs.append(Float64(1.5))
    var text = encode_json(F64List(vs^))
    assert_equal(
        text, String('{"vs":["NaN","Infinity","-Infinity",1.5]}'), "repeated"
    )
    var back = decode_json[F64List](text)
    assert_true(isnan(back.vs[0]), "NaN reads back")
    assert_equal(_bits(back.vs[1]), _bits(inf), "Infinity reads back")
    assert_equal(_bits(back.vs[2]), _bits(-inf), "-Infinity reads back")
    assert_true(isnan(decode_json[F64One]('{"v":"NaN"}').v), "NaN field")
    assert_true(
        isinf(decode_json[F64One]('{"v":"-Infinity"}').v), "-Infinity field"
    )
    print("  test_w1_non_finite_strings: PASS")


def test_w2_round_trip_extremes() raises:
    var cases = List[UInt64]()
    cases.append(MAX_BITS)
    cases.append(MAX_BITS | NEG_ZERO_BITS)
    cases.append(MIN_NORMAL_BITS)
    cases.append(MAX_SUBNORMAL_BITS)
    cases.append(MIN_SUBNORMAL_BITS)
    cases.append(NEG_ZERO_BITS)
    cases.append(UInt64(0x3FB999999999999A))  # 0.1
    cases.append(UInt64(0xBFF8000000000000))  # -1.5
    cases.append(UInt64(0x44B52D02C7E14AF6))  # 1e23
    cases.append(UInt64(0x3FD3333333333334))  # 0.30000000000000004
    cases.append(UInt64(0x00005C0AB9347ED7))  # 5e-310
    for i in range(len(cases)):
        var text = encode_json(F64One(_f(cases[i])))
        assert_equal(
            _bits(decode_json[F64One](text).v), cases[i], "round trip " + text
        )
    print("  test_w2_round_trip_extremes: PASS")


def test_f1_fast_path_edges() raises:
    _expect_read("1e22", UInt64(0x4480F0CF064DD592), "1e22")
    _expect_read("1e23", UInt64(0x44B52D02C7E14AF6), "1e23")
    _expect_read(
        "123456789012345e-22", UInt64(0x3E4A831BD731A260), "15 digits e-22"
    )
    _expect_read("7e-10", UInt64(0x3E080D43DE9CC603), "7e-10")
    _expect_read("0.1", UInt64(0x3FB999999999999A), "0.1")
    _expect_read("-1.5", UInt64(0xBFF8000000000000), "-1.5")
    _expect_read("-0.1", UInt64(0xBFB999999999999A), "-0.1")
    # 4.73e21 = (473 * 5^19) * 2^19 with an odd 54-bit 473 * 5^19: an exact
    # midpoint, which one IEEE multiply ties to even (...cda). A nonzero digit
    # 900 places in, past the 800 significant digits kept, puts the value
    # above it (...cdb), so the fast path must not run when a tail was dropped.
    _expect_read("4.73e21", UInt64(0x4470069EFB362CDA), "4.73e21")
    _expect_read(
        "4.73" + _zeros(900) + "1e21",
        UInt64(0x4470069EFB362CDB),
        "4.73e21 with a dropped nonzero tail",
    )
    _expect_read(
        "0.30000000000000004", UInt64(0x3FD3333333333334), "17 digits"
    )
    _expect_read(
        "8.98846567431158e307", UInt64(0x7FE0000000000000), "2^1023"
    )
    _expect_read("3e23", UInt64(0x44CFC3842BD1F072), "3e23 (exponent 23)")
    _expect_read("1e-23", UInt64(0x3B282DB34012B251), "1e-23 (exponent -23)")
    _expect_read(
        "0.9768070884241057", UInt64(0x3FEF4200F0690A5B), "16 digits"
    )
    print("  test_f1_fast_path_edges: PASS")


def main() raises:
    print("test_proto_codec_json_float64")
    test_r1_jsontestsuite_close_to_zero()
    test_r2_long_mantissas()
    test_r3_correct_rounding()
    test_r4_subnormals_and_zeros()
    test_r5_range()
    test_r6_exponents()
    test_r7_spellings()
    test_w1_non_finite_strings()
    test_w2_round_trip_extremes()
    test_f1_fast_path_edges()
