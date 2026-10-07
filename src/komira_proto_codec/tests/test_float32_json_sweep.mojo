# =============================================================================
# test_float32_json_sweep.mojo — a dense strided sweep of float32 bit
# patterns through the proto3-JSON float32 writer and reader.
# =============================================================================
#
# Not a welded gate (run it with `buck2 test`): about 262000 values, each
# written once and read three times by the exact big-integer reader, which
# is too slow for a test compiled without optimization. The welded suite
# (`test_proto_codec_json_float32.mojo`) runs the same checks over a sweep
# 16 times sparser (leg S1) and over every binade's powers of two and
# all-ones mantissas (leg E1).
#
# WHAT IT PROVES. Every 16411th bit pattern (every exponent, every sign, and
# mantissas from the middle of each binade, which E1 never visits): a
# finite value's text reads back bit-exactly through `parse_decimal_f32`,
# has at most 9 significant digits, and no decimal one digit shorter reads
# back as the same float32. NaN and the infinities are skipped (the welded
# legs W2 and R4 pin their spellings).
#
# WHAT IT CATCHES that the welded suite does not: a digit-generation defect
# in `_shortest_digits` confined to a sparse set of mid-binade mantissas.
# The welded sweep samples 16384 patterns, so a defect hitting fewer than
# about 1 in 16000 values, or only mantissas it never samples, can pass
# it. A mutant appending a digit for about 1 value in 1000, on mantissas
# the welded sweep does not sample, leaves the welded suite green and turns
# this test red (about 260 values of this sweep).
# =============================================================================

from std.math import isinf, isnan
from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_proto_codec import parse_decimal_f32, write_proto3_json_f32


def _write(v: Float32) -> String:
    var buf = List[UInt8]()
    write_proto3_json_f32(buf, v)
    return String(unsafe_from_utf8=Span(buf))


def _bits(v: Float32) -> UInt32:
    return bitcast[DType.uint32](v)


def _significant_digits(text: String) -> Int:
    """Significant digits in the mantissa of the number `text`: from the
    first nonzero digit to the last nonzero digit."""
    var b = text.as_bytes()
    var first = -1
    var last = -1
    var pos = 0
    for i in range(len(b)):
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


def _no_shorter_decimal(text: String, v: Float32) raises:
    """Neither decimal one digit shorter than `text` (its digits truncated,
    and truncated plus one in the last place) reads back as `v`."""
    var b = text.as_bytes()
    var neg = False
    var mant = 0
    var nd = 0
    var frac_digits = 0
    var after_dot = False
    var exp = 0
    var exp_neg = False
    var in_exp = False
    for i in range(len(b)):
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
        var cand_text = String("-") if neg else String("")
        cand_text += String(cand) + "e" + String(exp + 1)
        # A candidate past float32 max is refused, which is not `v` either.
        var same = False
        try:
            same = _bits(parse_decimal_f32(cand_text)) == _bits(v)
        except:
            same = False
        assert_true(
            not same,
            "sweep: " + text + " is not shortest; " + cand_text + " reads back",
        )


def main() raises:
    var checked = 0
    var bits = 0
    while bits < (1 << 32):
        var v = bitcast[DType.float32](UInt32(bits))
        if not isnan(v) and not isinf(v):
            var text = _write(v)
            var back = _bits(parse_decimal_f32(text))
            if back != UInt32(bits):
                assert_equal(back, UInt32(bits), "sweep bits: " + text)
            if _significant_digits(text) > 9:
                assert_true(False, "sweep: too many digits: " + text)
            _no_shorter_decimal(text, v)
            checked += 1
        bits += 16411
    assert_true(checked > 258000, "sweep covered the finite values")
    print("test_float32_json_sweep: ALL PASS (", checked, "values )")
