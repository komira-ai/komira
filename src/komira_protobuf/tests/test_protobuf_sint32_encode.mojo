# =============================================================================
# test_protobuf_sint32_encode.mojo — the bytes `pb_write_sint32_field` writes.
# =============================================================================
#
# A sint32 is the zigzag of a 32-bit value, an unsigned 32-bit number, so its
# varint is at most five bytes. The values come out of a list, so the compiler
# cannot fold them into the call.
#
#   S1  a zigzag with bit 31 set (the sint32 values from 2^30 up in magnitude,
#       the extremes included) is a five byte varint, not a ten byte one.
#       Catches: a 32-bit zigzag widened to 64 bits with its sign extended,
#       which writes 0xFFFFFFFFFFFFFFFF where 0x00000000FFFFFFFF is meant.
#   S2  the small values stay one byte (the inversion: a fix that masks too
#       much, or not enough, shows here).
# =============================================================================

from std.testing import assert_equal

from komira_protobuf import pb_write_sint32_field


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var hb = digits.as_bytes()
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        out += chr(Int(hb[(Int(b[i]) >> 4) & 0xF]))
        out += chr(Int(hb[Int(b[i]) & 0xF]))
    return out^


def _sint32(v: Int32) -> String:
    var out = List[UInt8]()
    pb_write_sint32_field(out, 1, v)
    return _hex(out)


def test_s1_a_zigzag_with_bit_31_set_is_five_bytes() raises:
    var vs = List[Int32]()
    vs.append(Int32.MIN)
    vs.append(Int32.MAX)
    vs.append(Int32(-1073741825))
    vs.append(Int32(1073741824))
    assert_equal(_sint32(vs[0]), "08 ff ff ff ff 0f", "Int32.MIN")
    assert_equal(_sint32(vs[1]), "08 fe ff ff ff 0f", "Int32.MAX")
    assert_equal(_sint32(vs[2]), "08 81 80 80 80 08", "-(2^30) - 1 zigzags to 2^31 + 1")
    assert_equal(_sint32(vs[3]), "08 80 80 80 80 08", "2^30 zigzags to 2^31")
    print("  test_s1_a_zigzag_with_bit_31_set_is_five_bytes: PASS")


def test_s2_small_values_stay_short() raises:
    var vs = List[Int32]()
    vs.append(Int32(0))
    vs.append(Int32(-1))
    vs.append(Int32(1))
    vs.append(Int32(-1073741824))
    vs.append(Int32(1073741823))
    assert_equal(_sint32(vs[0]), "08 00", "0")
    assert_equal(_sint32(vs[1]), "08 01", "-1")
    assert_equal(_sint32(vs[2]), "08 02", "1")
    assert_equal(_sint32(vs[3]), "08 ff ff ff ff 07", "-(2^30) zigzags to 2^31 - 1")
    assert_equal(_sint32(vs[4]), "08 fe ff ff ff 07", "2^30 - 1 zigzags to 2^31 - 2")
    print("  test_s2_small_values_stay_short: PASS")


def main() raises:
    test_s1_a_zigzag_with_bit_31_set_is_five_bytes()
    test_s2_small_values_stay_short()
