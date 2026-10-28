# =============================================================================
# test_proto_codec_json_int32_range.mojo — a 32-bit JSON integer outside its
# range is refused, never wrapped.
# =============================================================================
#
# The protobuf JSON mapping gives an int32 / uint32 field a decimal number or
# decimal text, and a parser must reject a value its type cannot hold (the
# reference conformance suite has a case for each). The text is read as a
# 64-bit integer first, so narrowing it without a check turns 4294967296 into
# 0 and -2147483649 into 2147483647 and the message decodes without a word.
#
#   I1  the five 32-bit scalar readers (int32, sint32, sfixed32 take the int32
#       range; uint32 and fixed32 the uint32 range) accept both ends of their
#       range, as a number and as text, and refuse one past either end, naming
#       the type's range and the value. Catches: a narrowing cast without a
#       range check (a wrapped value), a range one off at either end.
#   I2  the repeated readers and the map reader do the same for every element
#       or value, and name the offending value. Catches: a repeated reader
#       that stayed behind when the singular one was fixed.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import JsonDecoder


def _at(text: String) raises -> JsonDecoder:
    var d = JsonDecoder.from_text(text)
    _ = d.next_field()
    return d^


def _refusal(text: String, op: Int) -> String:
    try:
        var d = _at(text)
        if op == 0:
            _ = d.read_i32()
        elif op == 1:
            _ = d.read_sint32()
        elif op == 2:
            _ = d.read_sfixed32()
        elif op == 3:
            _ = d.read_u32()
        elif op == 4:
            _ = d.read_fixed32()
        elif op == 5:
            var x = List[Int32]()
            d.read_into_repeated_i32(x)
        elif op == 6:
            var x = List[Int32]()
            d.read_into_repeated_sint32(x)
        elif op == 7:
            var x = List[Int32]()
            d.read_into_repeated_sfixed32(x)
        elif op == 8:
            var x = List[UInt32]()
            d.read_into_repeated_u32(x)
        elif op == 9:
            var x = List[UInt32]()
            d.read_into_repeated_fixed32(x)
        elif op == 10:
            var x = Dict[String, Int32]()
            d.read_into_string_i32_map(x)
    except e:
        return String(e)
    return String("")


def test_i1_singular_readers() raises:
    comptime I = "JsonError: value out of int32 range: "
    comptime U = "JsonError: value out of uint32 range: "
    for op in range(3):
        assert_equal(_refusal('{"v":2147483647}', op), String(""))
        assert_equal(_refusal('{"v":-2147483648}', op), String(""))
        assert_equal(_refusal('{"v":"2147483647"}', op), String(""))
        assert_equal(_refusal('{"v":"-2147483648"}', op), String(""))
        assert_equal(_refusal('{"v":2147483648}', op), String(I) + "2147483648")
        assert_equal(_refusal('{"v":-2147483649}', op), String(I) + "-2147483649")
        assert_equal(_refusal('{"v":"2147483648"}', op), String(I) + "2147483648")
        assert_equal(_refusal('{"v":"4294967296"}', op), String(I) + "4294967296")
    for op in range(3, 5):
        assert_equal(_refusal('{"v":4294967295}', op), String(""))
        assert_equal(_refusal('{"v":"4294967295"}', op), String(""))
        assert_equal(_refusal('{"v":0}', op), String(""))
        assert_equal(_refusal('{"v":4294967296}', op), String(U) + "4294967296")
        assert_equal(_refusal('{"v":"4294967296"}', op), String(U) + "4294967296")
        assert_equal(
            _refusal('{"v":"18446744073709551615"}', op),
            String(U) + "18446744073709551615",
        )
    # The values at the ends decode to themselves.
    var d = _at('{"v":-2147483648}')
    assert_equal(d.read_i32(), Int32.MIN)
    d = _at('{"v":4294967295}')
    assert_equal(d.read_u32(), UInt32.MAX)
    print("  test_i1_singular_readers: PASS")


def test_i2_repeated_and_map_readers() raises:
    comptime I = "JsonError: value out of int32 range: "
    comptime U = "JsonError: value out of uint32 range: "
    for op in range(5, 8):
        assert_equal(_refusal('{"v":[2147483647,-2147483648]}', op), String(""))
        assert_equal(
            _refusal('{"v":[1,2147483648]}', op), String(I) + "2147483648"
        )
        assert_equal(
            _refusal('{"v":[-2147483649]}', op), String(I) + "-2147483649"
        )
    for op in range(8, 10):
        assert_equal(_refusal('{"v":[0,4294967295]}', op), String(""))
        assert_equal(
            _refusal('{"v":[1,4294967296]}', op), String(U) + "4294967296"
        )
    assert_equal(_refusal('{"m":{"a":2147483647,"b":-2147483648}}', 10), String(""))
    assert_equal(
        _refusal('{"m":{"a":1,"b":2147483648}}', 10), String(I) + "2147483648"
    )
    assert_equal(
        _refusal('{"m":{"a":"-2147483649"}}', 10), String(I) + "-2147483649"
    )
    var d = _at('{"v":[-2147483648,2147483647]}')
    var xs = List[Int32]()
    d.read_into_repeated_i32(xs)
    assert_equal(xs[0], Int32.MIN)
    assert_equal(xs[1], Int32.MAX)
    print("  test_i2_repeated_and_map_readers: PASS")


def main() raises:
    test_i1_singular_readers()
    test_i2_repeated_and_map_readers()
