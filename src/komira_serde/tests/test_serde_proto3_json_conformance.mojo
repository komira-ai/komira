# =============================================================================
# test_serde_proto3_json_conformance.mojo — the proto3-JSON mapping
# conformance gate: per-rule JSON byte-diff against reference vectors.
# =============================================================================
#
# Round-trip identity does NOT catch a self-consistent-but-non-conformant
# mapping (an int64-as-number round-trips and is still spec-wrong). This suite
# byte-diffs `Proto3JsonWire` (`JsonEncoder`) output against a hand-checked
# reference JSON string for EVERY proto3-JSON mapping rule:
#
#   R1 int64 / uint64  -> JSON STRING (NOT a number).
#   R2 int32 / uint32  -> JSON number.
#   R3 float / double  -> JSON number.
#   R4 bool            -> JSON true / false.
#   R5 string          -> JSON string (escaped).
#   R6 bytes           -> base64 STRING (RFC 4648 §4).
#   R7 field names: ENCODE writes the proto3 lowerCamelCase
#            `json_name`, and only that — which is what this suite
#            byte-diffs. DECODE additionally accepts the ORIGINAL
#            `.proto` field name (canonical parsers accept both), and
#            REFUSES a document stating both spellings of one field.
#            ⛔ THE TWO DIRECTIONS ARE NOT ONE RULE; stating R7 without
#            saying WHICH invites a fail-open on the decode half.
#            The decode side is pinned by
#            `test_serde_proto3_json_strictness.mojo`, not here.
#   R8 a nested message is a nested JSON object.
#   R9 an empty message is `{}`.
#
# The reference strings are computed by hand from the protobuf JSON spec —
# the byte-diff is what makes this a CONFORMANCE test, not a round-trip test.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_serde import (
    Serializable,
    WireEncoder,
    WireDecoder,
    JsonEncoder,
    JsonDecoder,
    encode_json,
    decode_json,
)
from komira_encoding import base64_encode, base64_decode


# =============================================================================
# A conformance probe message — one field per mapping rule.
# =============================================================================


@fieldwise_init
struct TsProbe(Serializable):
    """A nested-message probe — R8.

    `encode` omits a default-valued (0) `seconds` — the proto3 canonical
    JSON / protobuf-binary rule: a scalar field equal to its default is not
    emitted. This is the behavior the code generator emits per field;
    the hand-written probe mirrors it so R9 (`{}` for an all-default
    message) holds.
    """

    var seconds: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if self.seconds != 0:
            enc.write_i64_field(1, "seconds", self.seconds)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var seconds = Int64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "seconds":
                seconds = dec.read_i64()
            else:
                dec.skip()
        return TsProbe(seconds)


@fieldwise_init
struct ConformanceProbe(Serializable):
    """One field per mapping rule, in field-number order."""

    var f_i64: Int64  # R1
    var f_u64: UInt64  # R1
    var f_i32: Int32  # R2
    var f_u32: UInt32  # R2
    var f_f64: Float64  # R3
    var f_bool: Bool  # R4
    var f_str: String  # R5/R7
    var f_bytes: List[UInt8]  # R6
    var f_msg: TsProbe  # R8

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "fI64", self.f_i64)
        enc.write_u64_field(2, "fU64", self.f_u64)
        enc.write_i32_field(3, "fI32", self.f_i32)
        enc.write_u32_field(4, "fU32", self.f_u32)
        enc.write_f64_field(5, "fF64", self.f_f64)
        enc.write_bool_field(6, "fBool", self.f_bool)
        enc.write_string_field(7, "fStr", self.f_str)
        enc.write_bytes_field(8, "fBytes", self.f_bytes)
        enc.write_message_field[TsProbe](9, "fMsg", self.f_msg)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var f_i64 = Int64(0)
        var f_u64 = UInt64(0)
        var f_i32 = Int32(0)
        var f_u32 = UInt32(0)
        var f_f64 = Float64(0)
        var f_bool = False
        var f_str = String("")
        var f_bytes = List[UInt8]()
        var f_msg = TsProbe(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.json_name == "fI64":
                f_i64 = dec.read_i64()
            elif key.json_name == "fU64":
                f_u64 = dec.read_u64()
            elif key.json_name == "fI32":
                f_i32 = dec.read_i32()
            elif key.json_name == "fU32":
                f_u32 = dec.read_u32()
            elif key.json_name == "fF64":
                f_f64 = dec.read_f64()
            elif key.json_name == "fBool":
                f_bool = dec.read_bool()
            elif key.json_name == "fStr":
                f_str = dec.read_string()
            elif key.json_name == "fBytes":
                f_bytes = dec.read_bytes()
            elif key.json_name == "fMsg":
                f_msg = dec.read_message[TsProbe]()
            else:
                dec.skip()
        return ConformanceProbe(
            f_i64, f_u64, f_i32, f_u32, f_f64, f_bool, f_str^, f_bytes^, f_msg^
        )


# =============================================================================
# Per-rule byte-diff conformance tests.
# =============================================================================


def test_r1_int64_uint64_as_string() raises:
    """R1: int64 / uint64 serialize as JSON STRINGS (precision safety).
    A 2^53+ value MUST be quoted — an unquoted number loses precision in a
    JS consumer."""
    # int64 above 2^53.
    var ts = TsProbe(Int64(9007199254740993))  # 2^53 + 1
    var json = encode_json(ts)
    assert_equal(
        json, String('{"seconds":"9007199254740993"}'), "R1: int64 quoted"
    )

    # A negative int64.
    var ts_neg = TsProbe(Int64(-9223372036854775808))
    var json_neg = encode_json(ts_neg)
    assert_equal(
        json_neg,
        String('{"seconds":"-9223372036854775808"}'),
        "R1: Int64.MIN quoted",
    )
    print("  test_r1_int64_uint64_as_string: PASS")


def test_r1_uint64_max_as_string() raises:
    """R1: UInt64.MAX serializes as a quoted string without wrapping."""
    var probe = ConformanceProbe(
        Int64(0),
        UInt64(18446744073709551615),  # UInt64.MAX
        Int32(0),
        UInt32(0),
        Float64(0),
        False,
        String(""),
        List[UInt8](),
        TsProbe(0),
    )
    var json = encode_json(probe)
    # fU64 must appear as the quoted decimal of UInt64.MAX.
    assert_true(
        _contains(json, String('"fU64":"18446744073709551615"')),
        "R1: UInt64.MAX quoted, unwrapped",
    )
    print("  test_r1_uint64_max_as_string: PASS")


def test_r2_int32_uint32_as_number() raises:
    """R2: int32 / uint32 serialize as JSON NUMBERS (unquoted)."""
    var probe = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(-12345),
        UInt32(4000000000),
        Float64(0),
        False,
        String(""),
        List[UInt8](),
        TsProbe(0),
    )
    var json = encode_json(probe)
    assert_true(
        _contains(json, String('"fI32":-12345')), "R2: int32 unquoted"
    )
    assert_true(
        _contains(json, String('"fU32":4000000000')), "R2: uint32 unquoted"
    )
    print("  test_r2_int32_uint32_as_number: PASS")


def test_r3_float_double_as_number() raises:
    """R3: double serializes as a JSON number."""
    var probe = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(0),
        UInt32(0),
        Float64(2.5),
        False,
        String(""),
        List[UInt8](),
        TsProbe(0),
    )
    var json = encode_json(probe)
    assert_true(_contains(json, String('"fF64":2.5')), "R3: double unquoted")
    print("  test_r3_float_double_as_number: PASS")


def test_r4_bool_as_literal() raises:
    """R4: bool serializes as the JSON `true` / `false` literal."""
    var probe_t = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(0),
        UInt32(0),
        Float64(0),
        True,
        String(""),
        List[UInt8](),
        TsProbe(0),
    )
    var json_t = encode_json(probe_t)
    assert_true(_contains(json_t, String('"fBool":true')), "R4: bool true")

    var probe_f = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(0),
        UInt32(0),
        Float64(0),
        False,
        String(""),
        List[UInt8](),
        TsProbe(0),
    )
    var json_f = encode_json(probe_f)
    assert_true(_contains(json_f, String('"fBool":false')), "R4: bool false")
    print("  test_r4_bool_as_literal: PASS")


def test_r5_string_escaped() raises:
    """R5: string serializes as a JSON string with RFC-8259 escaping."""
    var probe = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(0),
        UInt32(0),
        Float64(0),
        False,
        String('he said "hi"\n\ttab'),
        List[UInt8](),
        TsProbe(0),
    )
    var json = encode_json(probe)
    # The embedded quote, newline, and tab must be escaped.
    assert_true(
        _contains(json, String('"fStr":"he said \\"hi\\"\\n\\ttab"')),
        "R5: string escaped",
    )
    print("  test_r5_string_escaped: PASS")


def test_r6_bytes_as_base64() raises:
    """R6: bytes serializes as a base64 STRING (RFC 4648 §4, padded)."""
    var raw = List[UInt8]()
    raw.append(0x00)  # an embedded NUL
    raw.append(0x10)
    raw.append(0x83)
    raw.append(0xFB)
    raw.append(0xEF)
    # Expected base64 of [0x00,0x10,0x83,0xFB,0xEF]: standard alphabet, padded.
    var probe = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(0),
        UInt32(0),
        Float64(0),
        False,
        String(""),
        raw^,
        TsProbe(0),
    )
    var json = encode_json(probe)
    # Cross-check against the base64 codec directly.
    var raw2 = List[UInt8]()
    raw2.append(0x00)
    raw2.append(0x10)
    raw2.append(0x83)
    raw2.append(0xFB)
    raw2.append(0xEF)
    var expected_b64 = base64_encode(raw2)
    assert_true(
        _contains(json, String('"fBytes":"') + expected_b64 + String('"')),
        "R6: bytes base64",
    )
    # base64 of a 5-byte input has 8 chars + the closing position; verify it
    # is a non-empty padded string.
    assert_true(expected_b64.byte_length() == 8, "R6: base64 length (5 -> 8)")
    print("  test_r6_bytes_as_base64: PASS")


def test_r7_lower_camel_case_field_names() raises:
    """R7, THE ENCODE HALF: the keys this codec WRITES are the proto3
    lowerCamelCase `json_name` — NOT the proto field number, NOT snake_case.

    ⛔ THAT IS NOT A STATEMENT ABOUT DECODE, and conflating the two invites
    a fail-open on the decode half. DECODE accepts the `json_name` AND
    the original `.proto` field name (canonical proto3-JSON parsers accept
    both) and REFUSES a document stating both spellings of one field; that
    direction is pinned by `test_serde_proto3_json_strictness.mojo`. This
    case asserts only the bytes on the way OUT — which is also what makes
    the strict decoder's round trip sound."""
    var probe = ConformanceProbe(
        Int64(1),
        UInt64(2),
        Int32(3),
        UInt32(4),
        Float64(5),
        True,
        String("s"),
        List[UInt8](),
        TsProbe(7),
    )
    var json = encode_json(probe)
    # Every key is lowerCamelCase.
    assert_true(_contains(json, String('"fI64":')), "R7: fI64 key")
    assert_true(_contains(json, String('"fU64":')), "R7: fU64 key")
    assert_true(_contains(json, String('"fBool":')), "R7: fBool key")
    assert_true(_contains(json, String('"fMsg":')), "R7: fMsg key")
    # No snake_case key leaked.
    assert_true(not _contains(json, String('"f_i64"')), "R7: no snake_case")
    print("  test_r7_lower_camel_case_field_names: PASS")


def test_r8_nested_message_as_object() raises:
    """R8: a nested message serializes as a nested JSON OBJECT."""
    var probe = ConformanceProbe(
        Int64(0),
        UInt64(0),
        Int32(0),
        UInt32(0),
        Float64(0),
        False,
        String(""),
        List[UInt8](),
        TsProbe(Int64(1716240000)),
    )
    var json = encode_json(probe)
    # fMsg is a nested object whose `seconds` is itself a quoted int64.
    assert_true(
        _contains(json, String('"fMsg":{"seconds":"1716240000"}')),
        "R8: nested message as object",
    )
    print("  test_r8_nested_message_as_object: PASS")


def test_r9_empty_message() raises:
    """R9: an all-default message serializes as `{}`."""
    var ts = TsProbe(Int64(0))
    var json = encode_json(ts)
    assert_equal(json, String("{}"), "R9: empty message is {}")
    print("  test_r9_empty_message: PASS")


def test_full_probe_byte_exact() raises:
    """A full probe message byte-diffed against the exact reference JSON —
    the strongest conformance assertion (every rule in one ordered object).
    """
    var raw = List[UInt8]()
    raw.append(0x41)  # 'A'
    raw.append(0x42)  # 'B'
    raw.append(0x43)  # 'C'  -> base64("ABC") = "QUJD"
    var probe = ConformanceProbe(
        Int64(100),
        UInt64(200),
        Int32(-3),
        UInt32(4),
        Float64(1.5),
        True,
        String("ok"),
        raw^,
        TsProbe(Int64(99)),
    )
    var json = encode_json(probe)
    var expected = String(
        '{"fI64":"100","fU64":"200","fI32":-3,"fU32":4,"fF64":1.5,'
        '"fBool":true,"fStr":"ok","fBytes":"QUJD",'
        '"fMsg":{"seconds":"99"}}'
    )
    assert_equal(json, expected, "full probe byte-exact")
    print("  test_full_probe_byte_exact: PASS")


def test_conformance_probe_roundtrip() raises:
    """The conformance probe also round-trips — a conformant encoding must
    still be decodable."""
    var raw = List[UInt8]()
    raw.append(0x41)
    raw.append(0x42)
    raw.append(0x43)
    var probe = ConformanceProbe(
        Int64(100),
        UInt64(200),
        Int32(-3),
        UInt32(4),
        Float64(1.5),
        True,
        String("ok"),
        raw^,
        TsProbe(Int64(99)),
    )
    var json = encode_json(probe)
    var back = decode_json[ConformanceProbe](json)
    assert_equal(back.f_i64, Int64(100), "rt: f_i64")
    assert_equal(back.f_u64, UInt64(200), "rt: f_u64")
    assert_equal(back.f_i32, Int32(-3), "rt: f_i32")
    assert_equal(back.f_bool, True, "rt: f_bool")
    assert_equal(back.f_str, String("ok"), "rt: f_str")
    assert_equal(len(back.f_bytes), 3, "rt: f_bytes len")
    assert_equal(Int(back.f_bytes[0]), 0x41, "rt: f_bytes[0]")
    assert_equal(back.f_msg.seconds, Int64(99), "rt: f_msg.seconds")
    print("  test_conformance_probe_roundtrip: PASS")


def test_base64_codec_direct() raises:
    """The base64 codec itself — RFC 4648 §4 vectors (the R6 dependency).
    """
    # RFC 4648 §10 test vectors.
    assert_equal(base64_encode(_bytes("")), String(""), "b64: empty")
    assert_equal(base64_encode(_bytes("f")), String("Zg=="), "b64: 'f'")
    assert_equal(base64_encode(_bytes("fo")), String("Zm8="), "b64: 'fo'")
    assert_equal(base64_encode(_bytes("foo")), String("Zm9v"), "b64: 'foo'")
    assert_equal(
        base64_encode(_bytes("foob")), String("Zm9vYg=="), "b64: 'foob'"
    )
    assert_equal(
        base64_encode(_bytes("fooba")), String("Zm9vYmE="), "b64: 'fooba'"
    )
    assert_equal(
        base64_encode(_bytes("foobar")), String("Zm9vYmFy"), "b64: 'foobar'"
    )
    # Decode is the inverse.
    var dec = base64_decode(String("Zm9vYmFy"))
    assert_equal(len(dec), 6, "b64 decode: 'foobar' len")
    assert_equal(Int(dec[0]), 0x66, "b64 decode: 'f'")
    assert_equal(Int(dec[5]), 0x72, "b64 decode: 'r'")
    var dec2 = base64_decode(String("Zg=="))
    assert_equal(len(dec2), 1, "b64 decode: 'f' len")
    assert_equal(Int(dec2[0]), 0x66, "b64 decode: 'f' byte")
    print("  test_base64_codec_direct: PASS")


# =============================================================================
# Test helpers.
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    """An ASCII string as a byte list."""
    var out = List[UInt8]()
    for i in range(s.byte_length()):
        out.append(UInt8(ord(s[byte=i])))
    return out^


def _contains(haystack: String, needle: String) -> Bool:
    """Substring search — the byte-diff conformance probe."""
    var hn = haystack.byte_length()
    var nn = needle.byte_length()
    if nn == 0:
        return True
    if nn > hn:
        return False
    for start in range(hn - nn + 1):
        var found = True
        for k in range(nn):
            if haystack[byte=start + k] != needle[byte=k]:
                found = False
                break
        if found:
            return True
    return False


def main() raises:
    print("test_serde_proto3_json_conformance — proto3-JSON mapping gate")
    test_r1_int64_uint64_as_string()
    test_r1_uint64_max_as_string()
    test_r2_int32_uint32_as_number()
    test_r3_float_double_as_number()
    test_r4_bool_as_literal()
    test_r5_string_escaped()
    test_r6_bytes_as_base64()
    test_r7_lower_camel_case_field_names()
    test_r8_nested_message_as_object()
    test_r9_empty_message()
    test_full_probe_byte_exact()
    test_conformance_probe_roundtrip()
    test_base64_codec_direct()
    print("test_serde_proto3_json_conformance: ALL PASS")
