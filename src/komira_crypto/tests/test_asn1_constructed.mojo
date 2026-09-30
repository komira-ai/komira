# =============================================================================
# komira_crypto/tests/test_asn1_constructed.mojo
# ASN.1 DER constructed-type iteration.
# =============================================================================
#
# Sub-tests:
#   1. SEQUENCE of 3 INTEGERs — iter_count + sequential der_parse_tlv walk.
#   2. SET of 2 OCTET STRINGs.
#   3. Nested SEQUENCE — outer SEQUENCE containing an inner SEQUENCE.
#   4. EXPLICIT [3] context-class wrapper around an inner SEQUENCE
#      (the X.509 Extensions shape).
#   5. IMPLICIT [1] context-class shape (single-byte tag flip from
#      OCTET STRING universal -> context-1 IMPLICIT).
#   6. Empty SEQUENCE (length 0).
#   7. Child-TLV exceeding parent boundary raises.
#   8. der_expect_tag positive + negative.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.cert.asn1 import (
    ASN1_CLASS_UNIVERSAL,
    ASN1_CLASS_CONTEXT,
    ASN1_TAG_INTEGER,
    ASN1_TAG_OCTET_STRING,
    ASN1_TAG_SEQUENCE,
    ASN1_TAG_SET,
    der_parse_tlv,
    der_iter_count,
    der_expect_tag,
    der_parse_integer_to_int64,
    der_parse_octet_string,
)


def _list_from_bytes(*vals: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def test_sequence_of_three_integers() raises:
    """SEQUENCE { INTEGER 1, INTEGER 2, INTEGER 3 }.

    Wire form: 0x30 0x09 (SEQUENCE, 9 bytes value)
                 0x02 0x01 0x01 (INTEGER 1)
                 0x02 0x01 0x02 (INTEGER 2)
                 0x02 0x01 0x03 (INTEGER 3)
    """
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x09),
        UInt8(0x02), UInt8(0x01), UInt8(0x01),
        UInt8(0x02), UInt8(0x01), UInt8(0x02),
        UInt8(0x02), UInt8(0x01), UInt8(0x03),
    )
    var outer = der_parse_tlv(buf, 0)
    assert_equal(Int(outer.tag.class_), Int(ASN1_CLASS_UNIVERSAL))
    assert_true(outer.tag.constructed)
    assert_equal(Int(outer.tag.tag_number), Int(ASN1_TAG_SEQUENCE))
    assert_equal(outer.value_len, 9)
    assert_equal(outer.end_pos, 11)

    # Child count.
    var count = der_iter_count(buf, outer.value_pos, outer.end_pos)
    assert_equal(count, 3)

    # Sequential walk.
    var pos = outer.value_pos
    var seen = List[Int64]()
    while pos < outer.end_pos:
        var child = der_parse_tlv(buf, pos)
        assert_equal(Int(child.tag.tag_number), Int(ASN1_TAG_INTEGER))
        var v = der_parse_integer_to_int64(buf[child.value_pos : child.value_pos + child.value_len])
        seen.append(v)
        pos = child.end_pos
    assert_equal(len(seen), 3)
    assert_equal(Int(seen[0]), 1)
    assert_equal(Int(seen[1]), 2)
    assert_equal(Int(seen[2]), 3)


def test_set_of_octet_strings() raises:
    """SET { OCTET STRING 'AB', OCTET STRING 'CD' }.

    Wire form: 0x31 0x08 (SET, 8 bytes value)
                 0x04 0x02 0x41 0x42  ('AB')
                 0x04 0x02 0x43 0x44  ('CD')
    """
    var buf = _list_from_bytes(
        UInt8(0x31), UInt8(0x08),
        UInt8(0x04), UInt8(0x02), UInt8(0x41), UInt8(0x42),
        UInt8(0x04), UInt8(0x02), UInt8(0x43), UInt8(0x44),
    )
    var outer = der_parse_tlv(buf, 0)
    assert_equal(Int(outer.tag.tag_number), Int(ASN1_TAG_SET))
    assert_true(outer.tag.constructed)

    var count = der_iter_count(buf, outer.value_pos, outer.end_pos)
    assert_equal(count, 2)

    var pos = outer.value_pos
    var child1 = der_parse_tlv(buf, pos)
    assert_equal(Int(child1.tag.tag_number), Int(ASN1_TAG_OCTET_STRING))
    var b1 = der_parse_octet_string(buf[child1.value_pos : child1.value_pos + child1.value_len])
    assert_equal(len(b1), 2)
    assert_equal(Int(b1[0]), 0x41)
    assert_equal(Int(b1[1]), 0x42)
    pos = child1.end_pos
    var child2 = der_parse_tlv(buf, pos)
    var b2 = der_parse_octet_string(buf[child2.value_pos : child2.value_pos + child2.value_len])
    assert_equal(len(b2), 2)
    assert_equal(Int(b2[0]), 0x43)
    assert_equal(Int(b2[1]), 0x44)


def test_nested_sequence() raises:
    """SEQUENCE { SEQUENCE { INTEGER 42 } }.

    Wire form: 0x30 0x05 (outer SEQUENCE, 5 bytes)
                 0x30 0x03 (inner SEQUENCE, 3 bytes)
                   0x02 0x01 0x2A (INTEGER 42)
    """
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x05),
        UInt8(0x30), UInt8(0x03),
        UInt8(0x02), UInt8(0x01), UInt8(0x2A),
    )
    var outer = der_parse_tlv(buf, 0)
    var inner = der_parse_tlv(buf, outer.value_pos)
    assert_equal(Int(inner.tag.tag_number), Int(ASN1_TAG_SEQUENCE))
    assert_true(inner.tag.constructed)
    var leaf = der_parse_tlv(buf, inner.value_pos)
    var v = der_parse_integer_to_int64(buf[leaf.value_pos : leaf.value_pos + leaf.value_len])
    assert_equal(Int(v), 42)


def test_explicit_context_tag_wrapper() raises:
    """[3] EXPLICIT SEQUENCE { INTEGER 99 } — the X.509 Extensions shape.

    Wire form: 0xA3 0x05 (context [3] constructed, 5 bytes)
                 0x30 0x03 (inner SEQUENCE, 3 bytes)
                   0x02 0x01 0x63 (INTEGER 99)

    Tag byte 0xA3 = 10_1_00011 = class=context (0b10), constructed=1,
    tag_number=3.
    """
    var buf = _list_from_bytes(
        UInt8(0xA3), UInt8(0x05),
        UInt8(0x30), UInt8(0x03),
        UInt8(0x02), UInt8(0x01), UInt8(0x63),
    )
    var wrapper = der_parse_tlv(buf, 0)
    assert_equal(Int(wrapper.tag.class_), Int(ASN1_CLASS_CONTEXT))
    assert_true(wrapper.tag.constructed)
    assert_equal(Int(wrapper.tag.tag_number), Int(3))

    var inner = der_parse_tlv(buf, wrapper.value_pos)
    assert_equal(Int(inner.tag.class_), Int(ASN1_CLASS_UNIVERSAL))
    assert_equal(Int(inner.tag.tag_number), Int(ASN1_TAG_SEQUENCE))

    var leaf = der_parse_tlv(buf, inner.value_pos)
    var v = der_parse_integer_to_int64(buf[leaf.value_pos : leaf.value_pos + leaf.value_len])
    assert_equal(Int(v), 99)


def test_implicit_context_tag() raises:
    """[1] IMPLICIT OCTET STRING — tag-flip with primitive encoding.

    Wire form: 0x81 0x02 0xCA 0xFE
    Tag byte 0x81 = 10_0_00001 = class=context (0b10), constructed=0,
    tag_number=1. The value is interpreted as if it were an OCTET STRING
    by the context (caller knows the schema).
    """
    var buf = _list_from_bytes(
        UInt8(0x81), UInt8(0x02), UInt8(0xCA), UInt8(0xFE),
    )
    var tlv = der_parse_tlv(buf, 0)
    assert_equal(Int(tlv.tag.class_), Int(ASN1_CLASS_CONTEXT))
    assert_false(tlv.tag.constructed)
    assert_equal(Int(tlv.tag.tag_number), Int(1))
    # Re-decode as OCTET STRING (caller's schema decision).
    var b = der_parse_octet_string(buf[tlv.value_pos : tlv.value_pos + tlv.value_len])
    assert_equal(len(b), 2)
    assert_equal(Int(b[0]), 0xCA)
    assert_equal(Int(b[1]), 0xFE)


def test_empty_sequence() raises:
    """SEQUENCE {} — length-0 constructed value."""
    var buf = _list_from_bytes(UInt8(0x30), UInt8(0x00))
    var tlv = der_parse_tlv(buf, 0)
    assert_equal(Int(tlv.tag.tag_number), Int(ASN1_TAG_SEQUENCE))
    assert_true(tlv.tag.constructed)
    assert_equal(tlv.value_len, 0)
    var count = der_iter_count(buf, tlv.value_pos, tlv.end_pos)
    assert_equal(count, 0)


def test_child_exceeds_parent_raises() raises:
    """A constructed value with a child whose length exceeds the parent
    boundary must raise (no out-of-bounds read).

    Wire form: 0x30 0x03 (SEQUENCE, 3 bytes)
                 0x02 0x05 0x01 0x02 0x03 (INTEGER claiming 5 bytes
                                             but only 3 inside the parent)
    """
    var buf = _list_from_bytes(
        UInt8(0x30), UInt8(0x03),
        UInt8(0x02), UInt8(0x05), UInt8(0x01), UInt8(0x02), UInt8(0x03),
    )
    var outer = der_parse_tlv(buf, 0)
    var raised = False
    try:
        var _c = der_iter_count(buf, outer.value_pos, outer.end_pos)
    except _:
        raised = True
    assert_true(raised, "child TLV exceeding parent must raise")


def test_expect_tag_positive_and_negative() raises:
    """der_expect_tag passes when shape matches; raises on mismatch."""
    var buf = _list_from_bytes(UInt8(0x30), UInt8(0x00))  # SEQUENCE {}
    # Positive: matches universal SEQUENCE.
    var tlv = der_expect_tag(buf, 0, ASN1_CLASS_UNIVERSAL, ASN1_TAG_SEQUENCE)
    assert_equal(tlv.value_len, 0)
    # Negative: assert it's an INTEGER -> raises.
    var raised = False
    try:
        var _t = der_expect_tag(buf, 0, ASN1_CLASS_UNIVERSAL, ASN1_TAG_INTEGER)
    except _:
        raised = True
    assert_true(raised, "wrong-tag expect must raise")
    # Negative: wrong class.
    raised = False
    try:
        var _t = der_expect_tag(buf, 0, ASN1_CLASS_CONTEXT, ASN1_TAG_SEQUENCE)
    except _:
        raised = True
    assert_true(raised, "wrong-class expect must raise")


def main() raises:
    test_sequence_of_three_integers()
    test_set_of_octet_strings()
    test_nested_sequence()
    test_explicit_context_tag_wrapper()
    test_implicit_context_tag()
    test_empty_sequence()
    test_child_exceeds_parent_raises()
    test_expect_tag_positive_and_negative()
    print("All 8 asn1 constructed-type tests PASSED")
