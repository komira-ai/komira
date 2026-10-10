# =============================================================================
# test_wkt_double_text.mojo — the numbers of google.protobuf.Value and
# DoubleValue read through the codec's double reader.
# =============================================================================
#
# Both read a JSON number with `read_proto3_json_f64` (komira_proto_codec):
# correctly rounded at any length, refused past the double range. Expected
# values are exact bit patterns.
#
# WHAT EACH LEG PROVES, and the defect it catches:
#   V1  a Value reads the JSONTestSuite y_number_double_close_to_zero
#       document (`[-0.000...0001]`, 80 digits) as -1e-78, and the 21-, 30-
#       and 48-digit integers of i_number_too_big_pos_int,
#       i_number_too_big_neg_int and i_number_very_big_negative_int; each
#       re-encodes and reads back as the same bits. Catches: the standard
#       library's `atof`, which refuses these literals ("String is not
#       convertible to float").
#   V2  a Value refuses a number past the double range (1e400, -1e400,
#       1e18446744073709551616) at decode, with "value out of double range".
#       Catches: decoding it to an infinity that the Value encoder then
#       refuses to write ("a Value number cannot be Infinity"), so a
#       document the decoder accepted could not be written back.
#   D1  DoubleValue reads the 80-digit literal and the smallest subnormal
#       (5e-324) bit-exactly, through decode_json and from_proto3_json, and
#       refuses 1e400 with the same message; "Infinity" still reads as +inf
#       and writes back as "Infinity". Catches: DoubleValue keeping its own
#       `atof` reader after the codec's was fixed.
# =============================================================================

from std.math import isinf
from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, encode_json

from komira_wkt import DoubleValue, Value, VALUE_KIND_LIST, VALUE_KIND_NUMBER


def _bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64](v)


def _zeros(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "0"
    return s^


def _single_number(doc: String) raises -> Float64:
    """The one number in the JSON array `doc`, read as a Value."""
    var v = decode_json[Value](doc)
    assert_equal(v.kind, VALUE_KIND_LIST, doc)
    ref arr = v.list_value[0]
    assert_equal(len(arr.values), 1, doc)
    assert_equal(arr.values[0].kind, VALUE_KIND_NUMBER, doc)
    return arr.values[0].number_value


def _expect_value_number(doc: String, bits: UInt64, what: String) raises:
    var x = _single_number(doc)
    assert_equal(_bits(x), bits, what)
    # A number the decoder accepted is one the encoder writes, and it reads
    # back as the same bits.
    var text = encode_json(decode_json[Value](doc))
    assert_equal(_bits(_single_number(text)), bits, what + " round trip")


def _expect_value_refused(doc: String, message: String) raises:
    var refused = False
    try:
        _ = decode_json[Value](doc)
    except e:
        refused = True
        assert_equal(String(e), message, doc)
    assert_true(refused, doc + " must be refused")


def _expect_double_value_refused(doc: String, message: String) raises:
    var refused = False
    try:
        _ = decode_json[DoubleValue](doc)
    except e:
        refused = True
        assert_equal(String(e), message, doc)
    assert_true(refused, doc + " must be refused")


def test_v1_long_literals() raises:
    _expect_value_number(
        "[-0." + _zeros(77) + "1]",
        UInt64(0xAFBDA48CE468E7C7),
        "y_number_double_close_to_zero",
    )
    _expect_value_number(
        "[100000000000000000000]",
        UInt64(0x4415AF1D78B58C40),
        "i_number_too_big_pos_int",
    )
    _expect_value_number(
        "[-123123123123123123123123123123]",
        UInt64(0xC5F8DD50F76AA1DC),
        "i_number_too_big_neg_int",
    )
    _expect_value_number(
        "[-237462374673276894279832749832423479823246327846]",
        UInt64(0xC9C4CC172FF39C42),
        "i_number_very_big_negative_int",
    )
    print("  test_v1_long_literals: PASS")


def test_v2_out_of_range_refused_at_decode() raises:
    _expect_value_refused(
        "[1e400]", "JsonError: value out of double range: 1e400 at $"
    )
    _expect_value_refused(
        "[-1e400]", "JsonError: value out of double range: -1e400 at $"
    )
    _expect_value_refused(
        "1e18446744073709551616",
        "JsonError: value out of double range: 1e18446744073709551616 at $",
    )
    print("  test_v2_out_of_range_refused_at_decode: PASS")


def test_d1_double_value() raises:
    var lit = "-0." + _zeros(77) + "1"
    assert_equal(
        _bits(decode_json[DoubleValue](lit).value),
        UInt64(0xAFBDA48CE468E7C7),
        "DoubleValue, 80 digits",
    )
    assert_equal(
        _bits(DoubleValue.from_proto3_json(lit).value),
        UInt64(0xAFBDA48CE468E7C7),
        "DoubleValue.from_proto3_json, 80 digits",
    )
    assert_equal(
        _bits(decode_json[DoubleValue]("5e-324").value),
        UInt64(1),
        "DoubleValue, the smallest subnormal",
    )
    _expect_double_value_refused(
        "1e400", "JsonError: value out of double range: 1e400 at $"
    )
    var inf = decode_json[DoubleValue]('"Infinity"')
    assert_true(isinf(inf.value) and inf.value > 0, "Infinity reads as +inf")
    assert_equal(encode_json(inf), String('"Infinity"'), "and writes back")
    print("  test_d1_double_value: PASS")


def main() raises:
    print("test_wkt_double_text")
    test_v1_long_literals()
    test_v2_out_of_range_refused_at_decode()
    test_d1_double_value()
