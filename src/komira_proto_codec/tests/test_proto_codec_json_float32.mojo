# =============================================================================
# test_proto_codec_json_float32.mojo — a proto3 `float` field in canonical JSON.
# =============================================================================
#
# proto3 JSON prints a `float` as the shortest decimal that parses back to
# the same float32, and the three non-finite values as the strings "NaN",
# "Infinity", "-Infinity". A reader refuses a number outside float32 range
# rather than turning it into an infinity.
#
# WHAT EACH LEG PROVES, and the defect it catches:
#   W1  a scalar `float` field prints the shortest float32 form (0.1 is
#       `0.1`, not its float64 expansion `0.10000000149011612`), including
#       the extremes (max, min normal, min subnormal), -0.0 and a value that
#       needs 8 digits. Catches: widening to Float64 before formatting.
#   W2  NaN / +Inf / -Inf print as the three spec strings, and read back.
#       Catches: writing `null` (which a reader takes as "absent", so the
#       value silently becomes 0.0).
#   W3  the `repeated float` element writer obeys W1 and W2 too. Catches: a
#       fix applied to the field writer only.
#   R1  the reader accepts float32 max (both its 8-digit spelling and its
#       17-digit float64 value) and its negation, bit-exact. Catches: a range check
#       that compares against the float64 value of the decimal and refuses
#       the shortest spelling of max (3.4028235e38 > FLT_MAX as a double).
#   R2  the reader REFUSES a finite value past float32 max (3.4028236e38,
#       1e39, a float64 overflow 1e400, the negatives, the string form, and
#       a repeated element). Catches: narrowing with no range check (the
#       value becomes inf).
#   R3  underflow is not an error: a value below the smallest subnormal
#       rounds to a signed zero, 1e-45 rounds to the smallest subnormal,
#       and "-0" / "-0.0" read as -0.0. Pins the documented rule (round to
#       nearest, sign kept), the same as the float64 reader.
#   R4  only the three spec spellings name a non-finite value: "inf",
#       "nan", "-inf" are refused. Catches: the lenient `atof` spellings
#       leaking through.
#   R5  the reader rounds the decimal STRAIGHT to float32: the writer's
#       `7.038531e-26` for 0x15AE43FD reads back as 0x15AE43FD, a decimal
#       just past a midpoint (1.0000000596046448) rounds up, an exact
#       midpoint ties to even, 2^-150 +- a little goes to the smallest
#       subnormal / zero, T - 1 (T = 2^128 - 2^103) is max and T is
#       refused, and a 100-digit decimal is read exactly. Catches: parsing
#       to Float64 then narrowing (double rounding at float32 midpoints).
#   E1  powers of two (the unequal-gap interval, both signs of the
#       exponent), the subnormal / normal boundary, and every binade's
#       all-zeros and all-ones mantissa: exact text for the named ones,
#       round trip and minimality for all. Catches: a wrong lower or upper
#       half-gap at a power of two (the strided sweep never visits one).
#   R6  long inputs: a 7-digit exponent offset by a million leading zeros
#       (or integer zeros against a 7-digit negative exponent) reads as
#       1.0 / 1.5, and a 26- or 50-digit exponent saturates to zero / out of
#       range. Catches: an exponent clamped at a fixed bound, which misreads
#       the offset cases (0.(1000001 zeros)1e1000002 read as 10^-900002,
#       i.e. zero).
#   S1  a strided sweep over float32 bit patterns (every 16411th, 261713
#       values, every exponent) is split over the welded tests
#       test_proto_codec_json_float32_sweep_0 .. _5 (disjoint index ranges,
#       each asserting its count; see their header).
# =============================================================================

from std.math import isnan
from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    encode_json,
    decode_json,
)


@fieldwise_init
struct F32One(Serializable):
    """`message F32One { float v = 1; }`."""

    var v: Float32

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_f32_field(1, "v", self.v)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Float32(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "v":
                v = dec.read_f32()
            else:
                dec.skip()
        return F32One(v)


@fieldwise_init
struct F32List(Serializable):
    """`message F32List { repeated float vs = 1; }`."""

    var vs: List[Float32]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.begin_list_field(1, "vs")
        for i in range(len(self.vs)):
            enc.write_f32_element(1, self.vs[i])
        enc.end_list_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var vs = List[Float32]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "vs":
                dec.read_into_repeated_f32(vs)
            else:
                dec.skip()
        return F32List(vs^)


def _f(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


def _bits(v: Float32) -> UInt32:
    return bitcast[DType.uint32](v)


comptime F32_MAX_BITS = UInt32(0x7F7FFFFF)
comptime F32_MIN_NORMAL_BITS = UInt32(0x00800000)
comptime F32_MIN_SUBNORMAL_BITS = UInt32(0x00000001)
comptime F32_NEG_ZERO_BITS = UInt32(0x80000000)
comptime F32_POS_INF_BITS = UInt32(0x7F800000)
comptime F32_NEG_INF_BITS = UInt32(0xFF800000)


def _write_one(v: Float32) raises -> String:
    return encode_json(F32One(v))


def _read_one(doc: String) raises -> Float32:
    return decode_json[F32One](doc).v


def _expect_refused(doc: String, needle: String, what: String) raises:
    var refused = False
    try:
        _ = decode_json[F32One](doc)
    except e:
        refused = True
        assert_true(
            String(e).find(needle) >= 0,
            what + ": refusal names '" + needle + "', got: " + String(e),
        )
    assert_true(refused, what + ": " + doc + " must be refused")


def test_w1_shortest_scalar() raises:
    assert_equal(_write_one(Float32(0.1)), String('{"v":0.1}'), "0.1")
    assert_equal(_write_one(Float32(1.5)), String('{"v":1.5}'), "1.5")
    assert_equal(
        _write_one(Float32(1.0) / Float32(3.0)),
        String('{"v":0.33333334}'),
        "1/3 needs 8 digits",
    )
    assert_equal(
        _write_one(_f(F32_MAX_BITS)),
        String('{"v":3.4028235e+38}'),
        "float32 max",
    )
    assert_equal(
        _write_one(-_f(F32_MAX_BITS)),
        String('{"v":-3.4028235e+38}'),
        "-float32 max",
    )
    assert_equal(
        _write_one(_f(F32_MIN_NORMAL_BITS)),
        String('{"v":1.1754944e-38}'),
        "float32 min normal",
    )
    assert_equal(
        _write_one(_f(F32_MIN_SUBNORMAL_BITS)),
        String('{"v":1e-45}'),
        "float32 min subnormal",
    )
    assert_equal(
        _write_one(_f(F32_NEG_ZERO_BITS)), String('{"v":-0.0}'), "-0.0"
    )
    assert_equal(
        _write_one(Float32(16777216.0)),
        String('{"v":16777216.0}'),
        "2^24",
    )
    # Each written value reads back bit-exactly.
    var probes = List[UInt32]()
    probes.append(_bits(Float32(0.1)))
    probes.append(F32_MAX_BITS)
    probes.append(F32_MAX_BITS | F32_NEG_ZERO_BITS)
    probes.append(F32_MIN_NORMAL_BITS)
    probes.append(F32_MIN_SUBNORMAL_BITS)
    probes.append(F32_NEG_ZERO_BITS)
    for i in range(len(probes)):
        var back = _read_one(_write_one(_f(probes[i])))
        assert_equal(_bits(back), probes[i], "W1 round trip bits")
    print("  test_w1_shortest_scalar: PASS")


def test_w2_non_finite_strings() raises:
    var nan = _f(UInt32(0x7FC00000))
    assert_equal(_write_one(nan), String('{"v":"NaN"}'), "NaN")
    assert_equal(
        _write_one(_f(F32_POS_INF_BITS)),
        String('{"v":"Infinity"}'),
        "+Infinity",
    )
    assert_equal(
        _write_one(_f(F32_NEG_INF_BITS)),
        String('{"v":"-Infinity"}'),
        "-Infinity",
    )
    assert_true(isnan(_read_one(_write_one(nan))), "NaN reads back NaN")
    assert_equal(
        _bits(_read_one(_write_one(_f(F32_POS_INF_BITS)))),
        F32_POS_INF_BITS,
        "+Infinity reads back",
    )
    assert_equal(
        _bits(_read_one(_write_one(_f(F32_NEG_INF_BITS)))),
        F32_NEG_INF_BITS,
        "-Infinity reads back",
    )
    print("  test_w2_non_finite_strings: PASS")


def test_w3_repeated() raises:
    var vs = List[Float32]()
    vs.append(Float32(0.1))
    vs.append(_f(UInt32(0x7FC00000)))
    vs.append(_f(F32_NEG_INF_BITS))
    vs.append(_f(F32_NEG_ZERO_BITS))
    vs.append(_f(F32_MAX_BITS))
    var json = encode_json(F32List(vs.copy()))
    assert_equal(
        json,
        String('{"vs":[0.1,"NaN","-Infinity",-0.0,3.4028235e+38]}'),
        "repeated float",
    )
    var back = decode_json[F32List](json).vs.copy()
    assert_equal(len(back), 5, "repeated length")
    assert_equal(_bits(back[0]), _bits(Float32(0.1)), "repeated 0.1")
    assert_true(isnan(back[1]), "repeated NaN")
    assert_equal(_bits(back[2]), F32_NEG_INF_BITS, "repeated -inf")
    assert_equal(_bits(back[3]), F32_NEG_ZERO_BITS, "repeated -0.0")
    assert_equal(_bits(back[4]), F32_MAX_BITS, "repeated max")
    print("  test_w3_repeated: PASS")


def test_r1_max_accepted() raises:
    assert_equal(
        _bits(_read_one('{"v":3.4028235e38}')), F32_MAX_BITS, "max 8 digits"
    )
    assert_equal(
        _bits(_read_one('{"v":3.4028234663852886e38}')),
        F32_MAX_BITS,
        "max as its float64 value",
    )
    assert_equal(
        _bits(_read_one('{"v":-3.4028235e38}')),
        F32_MAX_BITS | F32_NEG_ZERO_BITS,
        "-max",
    )
    assert_equal(
        _bits(_read_one('{"v":"3.4028235e38"}')),
        F32_MAX_BITS,
        "max as a string",
    )
    assert_equal(
        _bits(_read_one('{"v":1.1754944e-38}')),
        F32_MIN_NORMAL_BITS,
        "min normal",
    )
    print("  test_r1_max_accepted: PASS")


def test_r2_past_max_refused() raises:
    comptime RANGE = "out of float32 range"
    _expect_refused('{"v":3.4028236e38}', RANGE, "just past max")
    _expect_refused('{"v":-3.4028236e38}', RANGE, "just past -max")
    _expect_refused('{"v":1e39}', RANGE, "1e39")
    _expect_refused('{"v":1e400}', RANGE, "float64 overflow")
    _expect_refused('{"v":-1e400}', RANGE, "negative float64 overflow")
    _expect_refused('{"v":"3.4028236e38"}', RANGE, "string past max")
    var refused = False
    try:
        _ = decode_json[F32List]('{"vs":[1.0,3.4028236e38]}')
    except e:
        refused = True
        assert_true(String(e).find(RANGE) >= 0, "repeated: " + String(e))
    assert_true(refused, "a repeated element past max must be refused")
    print("  test_r2_past_max_refused: PASS")


def test_r3_underflow_rounds() raises:
    assert_equal(
        _bits(_read_one('{"v":1e-45}')),
        F32_MIN_SUBNORMAL_BITS,
        "1e-45 is the smallest subnormal",
    )
    assert_equal(_bits(_read_one('{"v":1e-46}')), UInt32(0), "1e-46 is +0")
    assert_equal(
        _bits(_read_one('{"v":-1e-46}')), F32_NEG_ZERO_BITS, "-1e-46 is -0"
    )
    assert_equal(_bits(_read_one('{"v":1e-400}')), UInt32(0), "1e-400 is +0")
    assert_equal(_bits(_read_one('{"v":-0}')), F32_NEG_ZERO_BITS, "-0")
    assert_equal(_bits(_read_one('{"v":-0.0}')), F32_NEG_ZERO_BITS, "-0.0")
    print("  test_r3_underflow_rounds: PASS")


def test_r4_only_spec_spellings() raises:
    assert_true(isnan(_read_one('{"v":"NaN"}')), "NaN")
    assert_equal(
        _bits(_read_one('{"v":"Infinity"}')), F32_POS_INF_BITS, "Infinity"
    )
    assert_equal(
        _bits(_read_one('{"v":"-Infinity"}')), F32_NEG_INF_BITS, "-Infinity"
    )
    assert_equal(_read_one('{"v":"1.5"}'), Float32(1.5), "number as string")
    comptime BAD = "not a proto3 float"
    _expect_refused('{"v":"inf"}', BAD, "inf")
    _expect_refused('{"v":"-inf"}', BAD, "-inf")
    _expect_refused('{"v":"nan"}', BAD, "nan")
    _expect_refused('{"v":"infinity"}', BAD, "lowercase infinity")
    # A numeric string is JSON number syntax; `atof`'s extras are refused.
    _expect_refused('{"v":" 1.5"}', BAD, "leading space")
    _expect_refused('{"v":"+1.5"}', BAD, "leading plus")
    _expect_refused('{"v":"1.5f"}', BAD, "C suffix")
    _expect_refused('{"v":".5"}', BAD, "no integer digit")
    _expect_refused('{"v":"1."}', BAD, "no fraction digit")
    _expect_refused('{"v":"1e"}', BAD, "no exponent digit")
    _expect_refused('{"v":""}', BAD, "empty string")
    print("  test_r4_only_spec_spellings: PASS")


def _significant_digits(json: String) -> Int:
    """Significant digits in the mantissa of the number in `{"v":<number>}`:
    from the first nonzero digit to the last nonzero digit, so neither
    leading zeros (`0.001`) nor the trailing zeros of an integral value
    (`1000000000000000.0`) count."""
    var b = json.as_bytes()
    var first = -1
    var last = -1
    var pos = 0
    for i in range(5, len(b) - 1):
        var c = b[i]
        if c == UInt8(ord("e")):
            break
        if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
            if c != UInt8(ord("0")):
                if first < 0:
                    first = pos
                last = pos
            pos += 1
    if first < 0:
        return 0
    return last - first + 1


def _no_shorter_decimal(json: String, v: Float32) raises:
    """Neither decimal one digit shorter than the number in `{"v":<num>}`
    (its digits truncated, and truncated plus one in the last place) reads
    back as `v`. Those are the only two candidates: a shorter decimal inside
    v's rounding interval would lie between v and the printed one, or be
    one of them."""
    var b = json.as_bytes()
    var neg = False
    var mant = 0  # the significant digits as an integer
    var nd = 0
    var frac_digits = 0
    var after_dot = False
    var exp = 0
    var exp_neg = False
    var in_exp = False
    for i in range(5, len(b) - 1):
        var c = b[i]
        if c == UInt8(ord("-")):
            if in_exp:
                exp_neg = True
            else:
                neg = True
        elif c == UInt8(ord("+")):
            pass
        elif c == UInt8(ord(".")):
            after_dot = True
        elif c == UInt8(ord("e")):
            in_exp = True
        elif in_exp:
            exp = exp * 10 + Int(c - UInt8(ord("0")))
        else:
            var dg = Int(c - UInt8(ord("0")))
            if nd > 0 or dg != 0:
                mant = mant * 10 + dg
                nd += 1
            if after_dot:
                frac_digits += 1
    if exp_neg:
        exp = -exp
    exp -= frac_digits  # v ~ mant * 10^exp
    while nd > 0 and mant % 10 == 0:
        mant //= 10
        nd -= 1
        exp += 1
    if nd < 2:
        return
    var shorter = mant // 10
    for cand in [shorter, shorter + 1]:
        var text = String("-") if neg else String("")
        text += String(cand) + "e" + String(exp + 1)
        # Read through the codec's reader (correctly rounded); a candidate
        # past float32 max is refused, which is not `v` either.
        var same = False
        try:
            same = _bits(_read_one('{"v":' + text + "}")) == _bits(v)
        except:
            same = False
        assert_true(
            not same,
            "sweep: " + json + " is not shortest; " + text + " reads back",
        )


def _check_round_trip_and_minimal(bits: UInt32, what: String) raises:
    var v = _f(bits)
    var json = _write_one(v)
    assert_equal(_bits(_read_one(json)), bits, what + " round trip: " + json)
    assert_true(_significant_digits(json) <= 9, what + " digits: " + json)
    _no_shorter_decimal(json, v)


def test_r5_correct_rounding() raises:
    """The reader rounds the decimal straight to float32. Rounding to
    float64 first can land exactly on a float32 midpoint and then break the
    tie the wrong way."""
    # The writer prints 0x15AE43FD as 7.038531e-26; that decimal lies just
    # under the upper midpoint of 0x15AE43FD and its float64 rounding is
    # exactly that midpoint.
    assert_equal(
        _write_one(_f(UInt32(0x15AE43FD))),
        String('{"v":7.038531e-26}'),
        "0x15AE43FD text",
    )
    assert_equal(
        _bits(_read_one('{"v":7.038531e-26}')),
        UInt32(0x15AE43FD),
        "7.038531e-26 reads back as 0x15AE43FD",
    )
    assert_equal(
        _bits(_read_one('{"v":-7.038531e-26}')),
        UInt32(0x95AE43FD),
        "-7.038531e-26",
    )
    # Just above the midpoint 1 + 2^-24: rounds up.
    assert_equal(
        _bits(_read_one('{"v":1.0000000596046448}')),
        UInt32(0x3F800001),
        "1.0000000596046448",
    )
    assert_equal(
        _bits(_read_one('{"v":1.00000005960464477550}')),
        UInt32(0x3F800001),
        "1.00000005960464477550",
    )
    # Exactly the midpoint 1 + 2^-24: a tie, to the even mantissa (1.0).
    assert_equal(
        _bits(_read_one('{"v":1.000000059604644775390625}')),
        UInt32(0x3F800000),
        "midpoint 1 + 2^-24 ties to even",
    )
    assert_equal(
        _bits(_read_one('{"v":1.000000059604644775390626}')),
        UInt32(0x3F800001),
        "one unit past the midpoint",
    )
    assert_equal(
        _bits(_read_one('{"v":1.000000059604644775390624}')),
        UInt32(0x3F800000),
        "one unit under the midpoint",
    )
    # Exactly the midpoint 1 + 3 * 2^-24: a tie, to the even mantissa 2.
    assert_equal(
        _bits(_read_one('{"v":1.000000178813934326171875}')),
        UInt32(0x3F800002),
        "midpoint 1 + 3 * 2^-24 ties to even",
    )
    # Half the smallest subnormal is 2^-150 = 7.00649232162408535...e-46:
    # just above it is the smallest subnormal, just below it is zero.
    assert_equal(
        _bits(_read_one('{"v":7.0064923216240854e-46}')),
        F32_MIN_SUBNORMAL_BITS,
        "just above 2^-150",
    )
    assert_equal(
        _bits(_read_one('{"v":7.0064923216240853e-46}')),
        UInt32(0),
        "just below 2^-150",
    )
    # The overflow threshold T = 2^128 - 2^103 (the midpoint between max and
    # 2^128) under correct rounding: T - 1 is max, T itself is refused.
    assert_equal(
        _bits(_read_one('{"v":340282356779733661637539395458142568447}')),
        F32_MAX_BITS,
        "T - 1 is max",
    )
    assert_equal(
        _bits(_read_one('{"v":3.40282356779733661637539395458142568447e38}')),
        F32_MAX_BITS,
        "T - 1 in exponent form is max",
    )
    _expect_refused(
        '{"v":340282356779733661637539395458142568448}',
        "out of float32 range",
        "T",
    )
    # A long digit string is read exactly, not refused for its length.
    assert_equal(
        _bits(
            _read_one(
                '{"v":0.1000000014901161193847656250000000000000000000000'
                + "00000000000000000000000000000000000000000000000000001}"
            )
        ),
        _bits(Float32(0.1)),
        "a 100-digit decimal",
    )
    print("  test_r5_correct_rounding: PASS")


def test_e1_binade_edges() raises:
    """Powers of two (the unequal-gap case on both sides of 1), the
    subnormal / normal boundary, and the all-ones mantissa of every
    binade. The strided sweep visits none of the powers of two."""
    assert_equal(_write_one(_f(UInt32(0x3F800000))), String('{"v":1.0}'), "1")
    assert_equal(_write_one(_f(UInt32(0x3F000000))), String('{"v":0.5}'), "0.5")
    assert_equal(
        _write_one(_f(UInt32(0x01000000))),
        String('{"v":2.3509887e-38}'),
        "2^-125",
    )
    assert_equal(
        _write_one(_f(UInt32(0x7F000000))),
        String('{"v":1.7014118e+38}'),
        "2^127",
    )
    assert_equal(
        _write_one(_f(UInt32(0x007FFFFF))),
        String('{"v":1.1754942e-38}'),
        "largest subnormal",
    )
    assert_equal(
        _write_one(_f(UInt32(0x00800001))),
        String('{"v":1.1754945e-38}'),
        "smallest normal + 1",
    )
    assert_equal(
        _write_one(_f(UInt32(0x00000002))), String('{"v":3e-45}'), "2 * 2^-149"
    )
    var named = List[UInt32]()
    named.append(UInt32(0x3F800000))
    named.append(UInt32(0x3F000000))
    named.append(UInt32(0x01000000))
    named.append(UInt32(0x7F000000))
    named.append(UInt32(0x007FFFFF))
    named.append(UInt32(0x00800001))
    named.append(UInt32(0x00000002))
    for i in range(len(named)):
        _check_round_trip_and_minimal(named[i], "named edge")
    # Every exponent field, mantissa all zeros (a power of two; field 0 is
    # zero, skipped) and all ones, both signs.
    for field in range(0, 255):
        for sign in range(2):
            var hi = (UInt32(sign) << UInt32(31)) | (UInt32(field) << UInt32(23))
            if field > 0:
                _check_round_trip_and_minimal(hi, "power of two")
            _check_round_trip_and_minimal(hi | UInt32(0x7FFFFF), "all ones")
    print("  test_e1_binade_edges: PASS")


def _zeros(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "0"
    return s^


def test_r6_long_inputs() raises:
    """The exponent is read exactly however long the digit string is: a
    huge exponent offset by as many leading or trailing zeros is an
    ordinary value, not one bent by an exponent cap. (A cap at 100000 stops
    reading the exponent after the digit that reaches it, so it bites from
    a 7-digit exponent on: 1000002 was read as 100000.)"""
    var one = UInt32(0x3F800000)
    # 0.(100001 zeros)1 * 10^100002 = 1 (a 6-digit exponent).
    assert_equal(
        _bits(_read_one('{"v":0.' + _zeros(100001) + "1e100002}")),
        one,
        "leading zeros against a 6-digit exponent",
    )
    # 0.(1000001 zeros)1 * 10^1000002 = 1
    assert_equal(
        _bits(_read_one('{"v":0.' + _zeros(1000001) + "1e1000002}")),
        one,
        "leading zeros against a huge positive exponent",
    )
    # 1(1000001 zeros) * 10^-1000001 = 1
    assert_equal(
        _bits(_read_one('{"v":1' + _zeros(1000001) + "e-1000001}")),
        one,
        "integer zeros against a huge negative exponent",
    )
    # 1(1000000 zeros).0 * 10^-1000000 = 1, as a numeric string
    assert_equal(
        _bits(_read_one('{"v":"1' + _zeros(1000000) + '.0e-1000000"}')),
        one,
        "the same as a numeric string",
    )
    # 0.(1500000 zeros)15 * 10^1500001 = 1.5
    assert_equal(
        _read_one('{"v":0.' + _zeros(1500000) + "15e1500001}"),
        Float32(1.5),
        "1.5 behind 1500000 leading zeros",
    )
    # A long exponent with no offset still saturates the right way.
    _expect_refused(
        '{"v":1e' + _zeros(30) + "99999999999999999999999}",
        "out of float32 range",
        "a 50-digit positive exponent",
    )
    assert_equal(
        _bits(_read_one('{"v":-1e-99999999999999999999999999}')),
        F32_NEG_ZERO_BITS,
        "a 26-digit negative exponent",
    )
    print("  test_r6_long_inputs: PASS")


def main() raises:
    print("test_proto_codec_json_float32 — proto3 JSON float32 gate")
    test_w1_shortest_scalar()
    test_w2_non_finite_strings()
    test_w3_repeated()
    test_r1_max_accepted()
    test_r2_past_max_refused()
    test_r3_underflow_rounds()
    test_r4_only_spec_spellings()
    test_r5_correct_rounding()
    test_e1_binade_edges()
    test_r6_long_inputs()
    print("test_proto_codec_json_float32: ALL PASS")
