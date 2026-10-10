# =============================================================================
# test_proto_codec_json_float_edges.mojo — the proto3-JSON float readers'
# refusals and the float layout's three-digit exponent.
# =============================================================================
#
#   E1  a float field whose JSON value is a bool is refused by the JSON
#       value's own refusal (the float32 reader, as the double reader is in
#       test_proto_codec_json_float64). Catches: a bool read as 0 or 1.
#   E2  a double given as a numeric string followed by other characters
#       ("1.5x", "1e5x", "12abc") is refused, naming the text. Catches: a
#       parser that stops at the first byte it cannot use and returns what it
#       has.
#   E3  `_layout` (the writer's layout of 0.d1..dn * 10^k) writes a
#       three-digit exponent byte-for-byte as the double writer does. No
#       float32 has one, so only a direct call reaches it. Catches: a
#       hundreds digit dropped or misplaced.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    decode_json,
    write_proto3_json_f64,
)
from komira_proto_codec.proto3_json_float import _layout


@fieldwise_init
struct Floats(Serializable):
    """`message Floats { float f = 1; double d = 2; }`."""

    var f: Float32
    var d: Float64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_f32_field(1, "f", self.f)
        enc.write_f64_field(2, "d", self.d)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var f = Float32(0)
        var d = Float64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.json_name == "f":
                f = dec.read_f32()
            elif key.json_name == "d":
                d = dec.read_f64()
            else:
                dec.skip()
        return Floats(f, d)


def _refusal_of(doc: String) raises -> String:
    try:
        _ = decode_json[Floats](doc)
    except e:
        return String(e)
    return String("")


def test_e1_a_bool_float_is_refused() raises:
    for doc in [String('{"f":true}'), String('{"f":false}')]:
        assert_equal(
            _refusal_of(doc),
            String("JsonError: as_float64() on a non-numeric value"),
            doc,
        )
    assert_equal(
        decode_json[Floats](String('{"f":"1.5"}')).f,
        Float32(1.5),
        "the inversion: a numeric string reads",
    )
    print("  test_e1_a_bool_float_is_refused: PASS")


def test_e2_trailing_characters_are_refused() raises:
    for text in [String("1.5x"), String("1e5x"), String("12abc")]:
        assert_equal(
            _refusal_of(String('{"d":"') + text + '"}'),
            String("JsonError: not a proto3 double: ") + text,
            text,
        )
    assert_equal(
        decode_json[Floats](String('{"d":"1e5"}')).d,
        Float64(100000.0),
        "the inversion: the same text without the trailing byte reads",
    )
    print("  test_e2_trailing_characters_are_refused: PASS")


def _laid_out(digits: List[Int], k: Int) -> String:
    var d = InlineArray[UInt8, 20](fill=UInt8(0))
    for i in range(len(digits)):
        d[i] = UInt8(digits[i])
    var buf = List[UInt8]()
    _layout(buf, d, len(digits), k)
    return String(unsafe_from_utf8=Span(buf))


def _f64_text(v: Float64) -> String:
    var buf = List[UInt8]()
    write_proto3_json_f64(buf, v)
    return String(unsafe_from_utf8=Span(buf))


def test_e3_a_three_digit_exponent_is_laid_out_as_the_double_writer_does() raises:
    # v = 0.d1..dn * 10^k, so the decimal exponent of d1 is k - 1.
    assert_equal(_laid_out([1], 101), String("1e+100"), "1e100")
    assert_equal(_laid_out([1], 101), _f64_text(1e100), "1e100 vs double")
    assert_equal(_laid_out([9, 5], 300), String("9.5e+299"), "9.5e299")
    assert_equal(_laid_out([9, 5], 300), _f64_text(9.5e299), "vs double")
    assert_equal(_laid_out([1, 2, 5], -149), String("1.25e-150"), "1.25e-150")
    assert_equal(_laid_out([1, 2, 5], -149), _f64_text(1.25e-150), "vs double")
    # Below 100 the hundreds digit is not written.
    assert_equal(_laid_out([3], 39), String("3e+38"), "3e38")
    print(
        "  test_e3_a_three_digit_exponent_is_laid_out_as_the_double_writer_does:"
        " PASS"
    )


def main() raises:
    test_e1_a_bool_float_is_refused()
    test_e2_trailing_characters_are_refused()
    test_e3_a_three_digit_exponent_is_laid_out_as_the_double_writer_does()
