# =============================================================================
# komira_crypto/tests/test_asn1_primitives.mojo
# ASN.1 DER primitive parser smoke tests.
# =============================================================================
#
# Sub-tests:
#   1. der_parse_tag short-form (BOOLEAN, OCTET STRING, context-[0]).
#   2. der_parse_length short-form (0..127).
#   3. der_parse_length long-form (multi-byte length encoding).
#   4. der_parse_tlv combined.
#   5. der_parse_boolean (FALSE + TRUE + non-canonical-TRUE + length error).
#   6. der_parse_null (length 0 only).
#   7. der_parse_integer_to_int64 (positive + negative + sign-pad + overflow).
#   8. der_parse_integer_to_bytes (RSA-modulus style, sign-pad stripped).
#   9. der_parse_octet_string (byte-for-byte copy).
#  10. der_parse_bit_string (X.509 BIT STRING with unused_bits=0).
#  11. der_parse_utf8_string + printable + ia5.
#  12. der_parse_oid (RFC 5280 algorithm OIDs).
#  13. der_parse_utc_time (RFC 5280 century interpretation).
#  14. der_parse_generalized_time.
#  15. malformed-input raises (truncated tag, indefinite length, length overflow).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.asn1 import (
    ASN1_CLASS_UNIVERSAL,
    ASN1_CLASS_CONTEXT,
    ASN1_TAG_BOOLEAN,
    ASN1_TAG_OCTET_STRING,
    ASN1_TAG_INTEGER,
    ASN1_TAG_OID,
    ASN1_TAG_SEQUENCE,
    der_parse_tag,
    der_parse_length,
    der_parse_tlv,
    der_parse_boolean,
    der_parse_null,
    der_parse_integer_to_int64,
    der_parse_integer_to_bytes,
    der_parse_octet_string,
    der_parse_bit_string,
    der_parse_utf8_string,
    der_parse_printable_string,
    der_parse_ia5_string,
    der_parse_oid,
    der_parse_utc_time,
    der_parse_generalized_time,
    der_oid_eq,
)


def _list_from_bytes(*vals: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def test_parse_tag_short_form() raises:
    """Short-form tag parsing: universal class + primitive + tag_number < 31."""
    # BOOLEAN (universal primitive, tag 1): 0x01
    var buf1 = _list_from_bytes(UInt8(0x01))
    var r1 = der_parse_tag(buf1, 0)
    assert_equal(Int(r1.tag.class_), Int(ASN1_CLASS_UNIVERSAL))
    assert_false(r1.tag.constructed)
    assert_equal(Int(r1.tag.tag_number), Int(ASN1_TAG_BOOLEAN))
    assert_equal(r1.next_pos, 1)

    # OCTET STRING (universal primitive, tag 4): 0x04
    var buf2 = _list_from_bytes(UInt8(0x04))
    var r2 = der_parse_tag(buf2, 0)
    assert_equal(Int(r2.tag.tag_number), Int(ASN1_TAG_OCTET_STRING))
    assert_false(r2.tag.constructed)

    # SEQUENCE (universal constructed, tag 16): 0x30
    var buf3 = _list_from_bytes(UInt8(0x30))
    var r3 = der_parse_tag(buf3, 0)
    assert_equal(Int(r3.tag.class_), Int(ASN1_CLASS_UNIVERSAL))
    assert_true(r3.tag.constructed)
    assert_equal(Int(r3.tag.tag_number), Int(ASN1_TAG_SEQUENCE))

    # Context-specific [0] EXPLICIT (constructed): 0xA0
    var buf4 = _list_from_bytes(UInt8(0xA0))
    var r4 = der_parse_tag(buf4, 0)
    assert_equal(Int(r4.tag.class_), Int(ASN1_CLASS_CONTEXT))
    assert_true(r4.tag.constructed)
    assert_equal(Int(r4.tag.tag_number), Int(0))


def test_parse_length_short_form() raises:
    """Single-byte length encoding (<128)."""
    var buf1 = _list_from_bytes(UInt8(0x00))
    var r1 = der_parse_length(buf1, 0)
    assert_equal(r1.length, 0)
    assert_equal(r1.next_pos, 1)

    var buf2 = _list_from_bytes(UInt8(0x7F))
    var r2 = der_parse_length(buf2, 0)
    assert_equal(r2.length, 127)

    var buf3 = _list_from_bytes(UInt8(0x05))
    var r3 = der_parse_length(buf3, 0)
    assert_equal(r3.length, 5)


def test_parse_length_long_form() raises:
    """Multi-byte length encoding (>= 128)."""
    # 0x81 0x80 = length 128 (the smallest long-form)
    var buf1 = _list_from_bytes(UInt8(0x81), UInt8(0x80))
    var r1 = der_parse_length(buf1, 0)
    assert_equal(r1.length, 128)
    assert_equal(r1.next_pos, 2)

    # 0x82 0x01 0x00 = length 256
    var buf2 = _list_from_bytes(UInt8(0x82), UInt8(0x01), UInt8(0x00))
    var r2 = der_parse_length(buf2, 0)
    assert_equal(r2.length, 256)
    assert_equal(r2.next_pos, 3)

    # 0x82 0x03 0xE8 = length 1000 (typical TBSCertificate length)
    var buf3 = _list_from_bytes(UInt8(0x82), UInt8(0x03), UInt8(0xE8))
    var r3 = der_parse_length(buf3, 0)
    assert_equal(r3.length, 1000)


def test_parse_length_indefinite_rejected() raises:
    """0x80 alone (indefinite length) is BER, not DER — must raise."""
    var buf = _list_from_bytes(UInt8(0x80))
    var raised = False
    try:
        var _r = der_parse_length(buf, 0)
    except _:
        raised = True
    assert_true(raised, "indefinite-length must raise")


def test_parse_tlv_combined() raises:
    """Full TLV walk: BOOLEAN TRUE at offset 0."""
    # 0x01 0x01 0xFF = BOOLEAN TRUE
    var buf = _list_from_bytes(UInt8(0x01), UInt8(0x01), UInt8(0xFF))
    var tlv = der_parse_tlv(buf, 0)
    assert_equal(Int(tlv.tag.tag_number), Int(ASN1_TAG_BOOLEAN))
    assert_equal(tlv.value_pos, 2)
    assert_equal(tlv.value_len, 1)
    assert_equal(tlv.end_pos, 3)
    # Read the value byte from the buf.
    var v = der_parse_boolean(buf[tlv.value_pos : tlv.value_pos + tlv.value_len])
    assert_true(v)


def test_parse_boolean() raises:
    """BOOLEAN FALSE + TRUE."""
    # FALSE: 0x00
    var f = _list_from_bytes(UInt8(0x00))
    assert_false(der_parse_boolean(f))
    # TRUE (canonical DER): 0xFF
    var t = _list_from_bytes(UInt8(0xFF))
    assert_true(der_parse_boolean(t))
    # TRUE (non-canonical but accepted for robustness): 0x01
    var t2 = _list_from_bytes(UInt8(0x01))
    assert_true(der_parse_boolean(t2))
    # Length != 1 must raise.
    var raised = False
    var bad = _list_from_bytes(UInt8(0x00), UInt8(0x00))
    try:
        var _r = der_parse_boolean(bad)
    except _:
        raised = True
    assert_true(raised, "BOOLEAN with length != 1 must raise")


def test_parse_null() raises:
    """NULL: length must be 0."""
    var empty = List[UInt8]()
    der_parse_null(empty)
    # Length != 0 must raise.
    var raised = False
    var bad = _list_from_bytes(UInt8(0x00))
    try:
        der_parse_null(bad)
    except _:
        raised = True
    assert_true(raised, "NULL with length != 0 must raise")


def test_parse_integer_int64() raises:
    """INTEGER decoded to Int64. Positive + negative + sign-pad."""
    # 0 (single 0x00 byte)
    var v0 = _list_from_bytes(UInt8(0x00))
    assert_equal(Int(der_parse_integer_to_int64(v0)), 0)

    # 1
    var v1 = _list_from_bytes(UInt8(0x01))
    assert_equal(Int(der_parse_integer_to_int64(v1)), 1)

    # 127 (max single positive without sign-pad)
    var v127 = _list_from_bytes(UInt8(0x7F))
    assert_equal(Int(der_parse_integer_to_int64(v127)), 127)

    # 128 — must encode with sign-pad as 0x00 0x80
    var v128 = _list_from_bytes(UInt8(0x00), UInt8(0x80))
    assert_equal(Int(der_parse_integer_to_int64(v128)), 128)

    # -1 (single byte 0xFF)
    var vm1 = _list_from_bytes(UInt8(0xFF))
    assert_equal(Int(der_parse_integer_to_int64(vm1)), -1)

    # -128 (single byte 0x80)
    var vm128 = _list_from_bytes(UInt8(0x80))
    assert_equal(Int(der_parse_integer_to_int64(vm128)), -128)

    # Big number 0x0100 = 256
    var v256 = _list_from_bytes(UInt8(0x01), UInt8(0x00))
    assert_equal(Int(der_parse_integer_to_int64(v256)), 256)

    # Empty must raise.
    var raised = False
    var empty = List[UInt8]()
    try:
        var _r = der_parse_integer_to_int64(empty)
    except _:
        raised = True
    assert_true(raised, "empty INTEGER must raise")


def test_parse_integer_to_bytes() raises:
    """INTEGER (large) decoded to canonical positive-magnitude bytes.
    Strip a single 0x00 sign-pad when present + MSB of next byte is set."""
    # 0x00 0x80 ... -> 0x80 ... (sign-pad stripped)
    var v1 = _list_from_bytes(UInt8(0x00), UInt8(0x80), UInt8(0x12), UInt8(0x34))
    var b1 = der_parse_integer_to_bytes(v1)
    assert_equal(len(b1), 3)
    assert_equal(Int(b1[0]), 0x80)
    assert_equal(Int(b1[1]), 0x12)
    assert_equal(Int(b1[2]), 0x34)

    # No leading 0x00 sign-pad: 0x12 0x34 -> 0x12 0x34
    var v2 = _list_from_bytes(UInt8(0x12), UInt8(0x34))
    var b2 = der_parse_integer_to_bytes(v2)
    assert_equal(len(b2), 2)
    assert_equal(Int(b2[0]), 0x12)
    assert_equal(Int(b2[1]), 0x34)

    # 0x00 0x12 ... NO sign-pad strip (MSB of next is unset). Keep as-is.
    var v3 = _list_from_bytes(UInt8(0x00), UInt8(0x12), UInt8(0x34))
    var b3 = der_parse_integer_to_bytes(v3)
    assert_equal(len(b3), 3)
    assert_equal(Int(b3[0]), 0x00)
    assert_equal(Int(b3[1]), 0x12)
    assert_equal(Int(b3[2]), 0x34)


def test_parse_octet_string() raises:
    """OCTET STRING: byte-for-byte copy."""
    var v = _list_from_bytes(UInt8(0xDE), UInt8(0xAD), UInt8(0xBE), UInt8(0xEF))
    var out = der_parse_octet_string(v)
    assert_equal(len(out), 4)
    assert_equal(Int(out[0]), 0xDE)
    assert_equal(Int(out[3]), 0xEF)


def test_parse_bit_string() raises:
    """BIT STRING with unused_bits=0 (X.509 subjectPublicKey shape)."""
    # First byte 0x00 = no unused bits; rest is byte data.
    var v = _list_from_bytes(UInt8(0x00), UInt8(0xDE), UInt8(0xAD), UInt8(0xBE))
    var r = der_parse_bit_string(v)
    assert_equal(Int(r.unused_bits), 0)
    assert_equal(len(r.bytes), 3)
    assert_equal(Int(r.bytes[0]), 0xDE)
    assert_equal(Int(r.bytes[2]), 0xBE)

    # unused_bits > 7 must raise.
    var raised = False
    var bad = _list_from_bytes(UInt8(0x08), UInt8(0xFF))
    try:
        var _r = der_parse_bit_string(bad)
    except _:
        raised = True
    assert_true(raised, "unused_bits > 7 must raise")


def test_parse_utf8_string() raises:
    """UTF8String — 'R3' (Let's Encrypt R3 CN)."""
    var v = _list_from_bytes(UInt8(0x52), UInt8(0x33))  # "R3"
    var s = der_parse_utf8_string(v)
    assert_equal(s, "R3")


def test_parse_printable_string() raises:
    """PrintableString — 'US' (Let's Encrypt R3 country code)."""
    var v = _list_from_bytes(UInt8(0x55), UInt8(0x53))  # "US"
    var s = der_parse_printable_string(v)
    assert_equal(s, "US")
    # Invalid char (e.g. '!' 0x21 not in PrintableString set) raises.
    var raised = False
    var bad = _list_from_bytes(UInt8(0x41), UInt8(0x21))  # "A!"
    try:
        var _s = der_parse_printable_string(bad)
    except _:
        raised = True
    assert_true(raised, "PrintableString with invalid char must raise")


def test_parse_ia5_string() raises:
    """IA5String — '*.example.com' (typical SAN dNSName)."""
    # "*.example.com"
    var v = _list_from_bytes(
        UInt8(0x2A), UInt8(0x2E), UInt8(0x65), UInt8(0x78), UInt8(0x61),
        UInt8(0x6D), UInt8(0x70), UInt8(0x6C), UInt8(0x65), UInt8(0x2E),
        UInt8(0x63), UInt8(0x6F), UInt8(0x6D),
    )
    var s = der_parse_ia5_string(v)
    assert_equal(s, "*.example.com")


def test_parse_oid_short() raises:
    """OBJECT IDENTIFIER — RFC 5280 sha256WithRSAEncryption (1.2.840.113549.1.1.11)."""
    # DER bytes: 0x2A 0x86 0x48 0x86 0xF7 0x0D 0x01 0x01 0x0B
    #   2A      -> 0x2A = 42 = 1*40 + 2 -> arc0=1, arc1=2
    #   86 48   -> 0x06 << 7 | 0x48 = 840
    #   86 F7 0D -> ((0x06 << 7) | 0x77) << 7 | 0x0D = (0x3F7 << 7) | 0x0D = 113549
    #   01 01 0B
    var v = _list_from_bytes(
        UInt8(0x2A), UInt8(0x86), UInt8(0x48), UInt8(0x86), UInt8(0xF7),
        UInt8(0x0D), UInt8(0x01), UInt8(0x01), UInt8(0x0B),
    )
    var arcs = der_parse_oid(v)
    assert_equal(len(arcs), 7)
    assert_equal(Int(arcs[0]), 1)
    assert_equal(Int(arcs[1]), 2)
    assert_equal(Int(arcs[2]), 840)
    assert_equal(Int(arcs[3]), 113549)
    assert_equal(Int(arcs[4]), 1)
    assert_equal(Int(arcs[5]), 1)
    assert_equal(Int(arcs[6]), 11)


def test_parse_oid_truncated_raises() raises:
    """OID byte with high bit set as the last byte (no terminator) raises."""
    var bad = _list_from_bytes(UInt8(0x2A), UInt8(0x86), UInt8(0x80))
    var raised = False
    try:
        var _r = der_parse_oid(bad)
    except _:
        raised = True
    assert_true(raised, "OID with truncated multi-byte arc must raise")


def test_oid_eq() raises:
    """der_oid_eq comparison helper."""
    var a = List[UInt32]()
    a.append(UInt32(1))
    a.append(UInt32(2))
    a.append(UInt32(840))
    var b = List[UInt32]()
    b.append(UInt32(1))
    b.append(UInt32(2))
    b.append(UInt32(840))
    assert_true(der_oid_eq(a, b))
    var c = List[UInt32]()
    c.append(UInt32(1))
    c.append(UInt32(2))
    c.append(UInt32(841))
    assert_false(der_oid_eq(a, c))
    # Different lengths.
    var d = List[UInt32]()
    d.append(UInt32(1))
    d.append(UInt32(2))
    assert_false(der_oid_eq(a, d))


def test_parse_utc_time() raises:
    """UTCTime '210101000000Z' = 2021-01-01 00:00:00 UTC."""
    # "210101000000Z" 13 bytes
    var v = _list_from_bytes(
        UInt8(0x32), UInt8(0x31), UInt8(0x30), UInt8(0x31), UInt8(0x30),
        UInt8(0x31), UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x30),
        UInt8(0x30), UInt8(0x30), UInt8(0x5A),  # 'Z'
    )
    var t = der_parse_utc_time(v)
    assert_equal(Int(t.year), 2021)
    assert_equal(Int(t.month), 1)
    assert_equal(Int(t.day), 1)
    assert_equal(Int(t.hour), 0)
    assert_equal(Int(t.minute), 0)
    assert_equal(Int(t.second), 0)

    # "850101120000Z" = 1985-01-01 (YY in [50,99] -> 19YY)
    var v2 = _list_from_bytes(
        UInt8(0x38), UInt8(0x35), UInt8(0x30), UInt8(0x31), UInt8(0x30),
        UInt8(0x31), UInt8(0x31), UInt8(0x32), UInt8(0x30), UInt8(0x30),
        UInt8(0x30), UInt8(0x30), UInt8(0x5A),
    )
    var t2 = der_parse_utc_time(v2)
    assert_equal(Int(t2.year), 1985)
    assert_equal(Int(t2.hour), 12)


def test_parse_generalized_time() raises:
    """GeneralizedTime '20250915160000Z' = 2025-09-15 16:00:00 UTC."""
    # 15 bytes
    var v = _list_from_bytes(
        UInt8(0x32), UInt8(0x30), UInt8(0x32), UInt8(0x35), UInt8(0x30),
        UInt8(0x39), UInt8(0x31), UInt8(0x35), UInt8(0x31), UInt8(0x36),
        UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x30), UInt8(0x5A),
    )
    var t = der_parse_generalized_time(v)
    assert_equal(Int(t.year), 2025)
    assert_equal(Int(t.month), 9)
    assert_equal(Int(t.day), 15)
    assert_equal(Int(t.hour), 16)
    assert_equal(Int(t.minute), 0)
    assert_equal(Int(t.second), 0)


def test_truncated_buffer_raises() raises:
    """Truncated input must raise (not crash, not UB)."""
    var empty = List[UInt8]()
    var raised = False
    try:
        var _r = der_parse_tag(empty, 0)
    except _:
        raised = True
    assert_true(raised, "empty buffer in der_parse_tag must raise")

    # TLV with length declaring more bytes than buffer has.
    var buf = _list_from_bytes(UInt8(0x04), UInt8(0x05), UInt8(0x01), UInt8(0x02))
    raised = False
    try:
        var _t = der_parse_tlv(buf, 0)
    except _:
        raised = True
    assert_true(raised, "TLV with length-overflow must raise")


def main() raises:
    test_parse_tag_short_form()
    test_parse_length_short_form()
    test_parse_length_long_form()
    test_parse_length_indefinite_rejected()
    test_parse_tlv_combined()
    test_parse_boolean()
    test_parse_null()
    test_parse_integer_int64()
    test_parse_integer_to_bytes()
    test_parse_octet_string()
    test_parse_bit_string()
    test_parse_utf8_string()
    test_parse_printable_string()
    test_parse_ia5_string()
    test_parse_oid_short()
    test_parse_oid_truncated_raises()
    test_oid_eq()
    test_parse_utc_time()
    test_parse_generalized_time()
    test_truncated_buffer_raises()
    print("All 20 asn1 primitive tests PASSED")
