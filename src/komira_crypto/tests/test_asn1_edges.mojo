# =============================================================================
# komira_crypto/tests/test_asn1_edges.mojo
#
# The DER primitive paths test_asn1_primitives does not reach: long-form tag
# numbers (X.690 8.1.2.4) at one, two and four bytes and past the four-byte
# cap, empty INTEGER / BIT STRING / OID values, an IA5 byte above 0x7F, the
# field-range refusals of UTCTime and GeneralizedTime at each side of each
# bound, and der_iter_count's range and child-boundary refusals. Every
# refusal is matched on its message, so a refusal raised by a different check
# does not pass.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.asn1 import (
    ASN1_CLASS_CONTEXT,
    ASN1_CLASS_APPLICATION,
    der_parse_tag,
    der_parse_integer_to_bytes,
    der_parse_bit_string,
    der_parse_ia5_string,
    der_parse_oid,
    der_parse_utc_time,
    der_parse_generalized_time,
    der_iter_count,
)


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _s(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in text.as_bytes():
        out.append(c)
    return out^


def _tag_err(buf: List[UInt8]) -> String:
    try:
        _ = der_parse_tag(Span(buf), 0)
    except e:
        return String(e)
    return String("no error")


def _utc_err(text: String) -> String:
    var v = _s(text)
    try:
        _ = der_parse_utc_time(Span(v))
    except e:
        return String(e)
    return String("no error")


def _gen_err(text: String) -> String:
    var v = _s(text)
    try:
        _ = der_parse_generalized_time(Span(v))
    except e:
        return String(e)
    return String("no error")


def _has(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


# -----------------------------------------------------------------------------
# Long-form tags
# -----------------------------------------------------------------------------


def test_long_form_tag_two_bytes() raises:
    # [129] context, primitive: 0x9F, then 0x81 0x01 = (1 << 7) | 1.
    var buf = _b(0x9F, 0x81, 0x01, 0x00)
    var r = der_parse_tag(Span(buf), 0)
    assert_equal(Int(r.tag.class_), Int(ASN1_CLASS_CONTEXT), "class")
    assert_false(r.tag.constructed, "primitive")
    assert_equal(Int(r.tag.tag_number), 129, "tag number")
    assert_equal(r.next_pos, 3, "next_pos after two tag-number bytes")


def test_long_form_tag_one_byte_constructed() raises:
    # Application class, constructed, tag 31 (the smallest long-form number).
    var buf = _b(0x7F, 0x1F)
    var r = der_parse_tag(Span(buf), 0)
    assert_equal(Int(r.tag.class_), Int(ASN1_CLASS_APPLICATION), "class")
    assert_true(r.tag.constructed, "constructed")
    assert_equal(Int(r.tag.tag_number), 31, "tag number")
    assert_equal(r.next_pos, 2, "next_pos")


def test_long_form_tag_four_bytes_is_the_cap() raises:
    # Four 7-bit groups, all ones: 2^28 - 1.
    var buf = _b(0x1F, 0xFF, 0xFF, 0xFF, 0x7F)
    var r = der_parse_tag(Span(buf), 0)
    assert_equal(Int(r.tag.tag_number), (1 << 28) - 1, "28-bit tag")
    assert_equal(r.next_pos, 5, "next_pos")


def test_long_form_tag_refusals() raises:
    var e = _tag_err(_b(0x1F))
    assert_true(_has(e, "truncated long-form tag"), "no tag-number byte: " + e)
    e = _tag_err(_b(0x1F, 0x81))
    assert_true(_has(e, "truncated long-form tag"), "unterminated: " + e)
    e = _tag_err(_b(0x1F, 0x81, 0x81, 0x81, 0x81, 0x01))
    assert_true(_has(e, "long-form tag exceeds 4 bytes"), "five bytes: " + e)


# -----------------------------------------------------------------------------
# Empty and out-of-alphabet values
# -----------------------------------------------------------------------------


def test_empty_values_are_refused() raises:
    var empty = List[UInt8]()
    var msg = String("no error")
    try:
        _ = der_parse_integer_to_bytes(Span(empty))
    except e:
        msg = String(e)
    assert_true(_has(msg, "der_parse_integer_to_bytes: empty value"), msg)

    msg = String("no error")
    try:
        _ = der_parse_bit_string(Span(empty))
    except e:
        msg = String(e)
    assert_true(_has(msg, "der_parse_bit_string: empty value"), msg)

    msg = String("no error")
    try:
        _ = der_parse_oid(Span(empty))
    except e:
        msg = String(e)
    assert_true(_has(msg, "der_parse_oid: empty value"), msg)


def test_bit_string_unused_bits_without_data() raises:
    # An empty bit string must say 0 unused bits.
    var ok = _b(0x00)
    var r = der_parse_bit_string(Span(ok))
    assert_equal(len(r.bytes), 0, "no data bytes")
    var bad = _b(0x03)
    var msg = String("no error")
    try:
        _ = der_parse_bit_string(Span(bad))
    except e:
        msg = String(e)
    assert_true(_has(msg, "empty bit-data with non-zero unused_bits"), msg)


def test_ia5_high_byte_is_refused() raises:
    var top = _b(0x41, 0x7F)
    var ia5 = der_parse_ia5_string(Span(top))
    assert_equal(ia5.byte_length(), 2, "0x7F is IA5")
    assert_equal(Int(ia5.as_bytes()[1]), 0x7F, "0x7F kept")
    var high = _b(0x41, 0x80)
    var msg = String("no error")
    try:
        _ = der_parse_ia5_string(Span(high))
    except e:
        msg = String(e)
    assert_true(_has(msg, "byte > 0x7F"), msg)


# -----------------------------------------------------------------------------
# Time fields
# -----------------------------------------------------------------------------


def test_utc_time_field_bounds() raises:
    var tv = _s("491231235960Z")
    var t = der_parse_utc_time(Span(tv))
    assert_equal(Int(t.year), 2049, "year")
    assert_equal(Int(t.day), 31, "day 31 accepted")
    assert_equal(Int(t.hour), 23, "hour 23 accepted")
    assert_equal(Int(t.minute), 59, "minute 59 accepted")
    assert_equal(Int(t.second), 60, "leap second accepted")
    assert_true(_has(_utc_err("490100000000Z"), "day out of range"), "day 00")
    assert_true(_has(_utc_err("490132000000Z"), "day out of range"), "day 32")
    assert_true(_has(_utc_err("490101240000Z"), "hour out of range"), "hour 24")
    assert_true(_has(_utc_err("490101006000Z"), "minute out of range"), "minute 60")
    assert_true(_has(_utc_err("490101000061Z"), "second out of range"), "second 61")


def test_time_digits_are_checked() raises:
    # '/' (0x2F) and ':' (0x3A) sit just outside '0'..'9'.
    assert_true(_has(_utc_err("4/0101000000Z"), "expected ASCII digit"), "slash")
    assert_true(_has(_utc_err("4:0101000000Z"), "expected ASCII digit"), "colon")
    assert_true(_has(_gen_err("20:00101000000Z"), "expected ASCII digit"), "gen colon")


def test_generalized_time_field_bounds() raises:
    var gv = _s("20501231235960Z")
    var t = der_parse_generalized_time(Span(gv))
    assert_equal(Int(t.year), 2050, "year")
    assert_equal(Int(t.month), 12, "month 12 accepted")
    assert_equal(Int(t.second), 60, "leap second accepted")
    assert_true(_has(_gen_err("20500101000000X"), "must end with 'Z'"), "no Z")
    assert_true(_has(_gen_err("20500001000000Z"), "month out of range"), "month 00")
    assert_true(_has(_gen_err("20501301000000Z"), "month out of range"), "month 13")
    assert_true(_has(_gen_err("20500100000000Z"), "day out of range"), "day 00")
    assert_true(_has(_gen_err("20500132000000Z"), "day out of range"), "day 32")
    assert_true(_has(_gen_err("20500101240000Z"), "hour out of range"), "hour 24")
    assert_true(_has(_gen_err("20500101006000Z"), "minute out of range"), "minute 60")
    assert_true(_has(_gen_err("20500101000061Z"), "second out of range"), "second 61")


# -----------------------------------------------------------------------------
# der_iter_count
# -----------------------------------------------------------------------------


def _iter_err(buf: List[UInt8], start: Int, end: Int) -> String:
    try:
        _ = der_iter_count(Span(buf), start, end)
    except e:
        return String(e)
    return String("no error")


def test_iter_count() raises:
    # Two children: OCTET STRING (2 bytes) and NULL.
    var buf = _b(0x04, 0x02, 0xAA, 0xBB, 0x05, 0x00)
    assert_equal(der_iter_count(Span(buf), 0, 6), 2, "two children")
    assert_equal(der_iter_count(Span(buf), 4, 6), 1, "second child only")
    assert_equal(der_iter_count(Span(buf), 6, 6), 0, "empty range")
    assert_true(_has(_iter_err(buf, -1, 6), "invalid range"), "start < 0")
    assert_true(_has(_iter_err(buf, 4, 3), "invalid range"), "end < start")
    assert_true(_has(_iter_err(buf, 0, 7), "invalid range"), "end > len")
    assert_true(
        _has(_iter_err(buf, 0, 3), "child TLV exceeds parent boundary"),
        "child runs past the range",
    )


def main() raises:
    test_long_form_tag_two_bytes()
    test_long_form_tag_one_byte_constructed()
    test_long_form_tag_four_bytes_is_the_cap()
    test_long_form_tag_refusals()
    test_empty_values_are_refused()
    test_bit_string_unused_bits_without_data()
    test_ia5_high_byte_is_refused()
    test_utc_time_field_bounds()
    test_time_digits_are_checked()
    test_generalized_time_field_bounds()
    test_iter_count()
    print("test_asn1_edges: 11 tests PASS")
