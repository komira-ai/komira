# =============================================================================
# test_proto_codec_json_float32_sweep_4.mojo — S1 shard 4 of 6.
# =============================================================================
#
# S1 runs every 16411th float32 bit pattern, bits = i * 16411 for i in
# [0, TOTAL), TOTAL = ceil(2^32 / 16411) = 261713 (every exponent, both
# signs, NaN and the infinities), through the proto3 JSON writer and the
# exact reader.
#
# A single welded test of all 261713 values takes longer than a coverage build
# (compiled without optimization) allows one test to run, so the sweep is
# split into 6 welded tests over disjoint index ranges:
#
#   shard k covers i in [k * TOTAL // 6, (k + 1) * TOTAL // 6)
#
# This file is shard 4: i in [174475, 218094), 43619 values. The shard files
# test_proto_codec_json_float32_sweep_0 .. _5 are identical except
# for SHARD and EXPECTED; their EXPECTED counts sum to 261713, the count of
# the single sweep they replace. Each shard asserts its own count, so a shard
# whose range drops or repeats an index fails.
#
# WHAT EACH VALUE PROVES, and the defect it catches: it round-trips
# bit-exactly through encode_json / decode_json (NaN reads back as NaN),
# has at most 9 significant digits, and no decimal one digit shorter reads
# back as the same float32. Catches: a writer that is not round-trip exact
# (the standard library's `String(Float32)` fails ~0.5% of this sweep at
# small magnitudes), one that prints the float64 expansion (up to 17
# digits), one that pads to a fixed 9 digits (`%.9g`), and a digit defect
# hitting about 1 value in 1000. The other legs of the float32 gate (W1-W3,
# R1-R6, E1) are in test_proto_codec_json_float32.mojo.
# =============================================================================

from std.math import isinf, isnan
from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    encode_json,
    decode_json,
)


comptime STRIDE = 16411
comptime SHARDS = 6
comptime SHARD = 4
# Every index i with i * STRIDE < 2^32: ceil(2^32 / STRIDE).
comptime TOTAL = 261713
# This shard's count, (SHARD + 1) * TOTAL // SHARDS - SHARD * TOTAL // SHARDS.
comptime EXPECTED = 43619


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


def _f(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


def _bits(v: Float32) -> UInt32:
    return bitcast[DType.uint32](v)


def _write_one(v: Float32) raises -> String:
    return encode_json(F32One(v))


def _read_one(doc: String) raises -> Float32:
    return decode_json[F32One](doc).v


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


def test_s1_sweep_shard() raises:
    assert_equal(TOTAL, ((1 << 32) + STRIDE - 1) // STRIDE, "TOTAL")
    var lo = SHARD * TOTAL // SHARDS
    var hi = (SHARD + 1) * TOTAL // SHARDS
    var checked = 0
    var i = lo
    while i < hi:
        var bits = i * STRIDE
        var v = _f(UInt32(bits))
        var json = _write_one(v)
        var back = _read_one(json)
        if isnan(v):
            assert_true(isnan(back), "sweep NaN: " + json)
        else:
            if _bits(back) != UInt32(bits):
                assert_equal(_bits(back), UInt32(bits), "sweep bits: " + json)
            if not isinf(v):
                # A float32 needs at most 9 significant digits; its
                # float64 expansion needs up to 17.
                var d = _significant_digits(json)
                if d > 9:
                    assert_true(False, "sweep: too many digits: " + json)
                _no_shorter_decimal(json, v)
        checked += 1
        i += 1
    assert_equal(checked, EXPECTED, "shard 4 covered its range")
    print("  test_s1_sweep_shard: PASS (", checked, "values from i =", lo, ")")


def main() raises:
    print("test_proto_codec_json_float32_sweep_4 — S1 shard 4 of 6")
    test_s1_sweep_shard()
    print("test_proto_codec_json_float32_sweep_4: ALL PASS")
