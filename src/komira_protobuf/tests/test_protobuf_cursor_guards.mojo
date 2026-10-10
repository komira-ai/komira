# =============================================================================
# test_protobuf_cursor_guards.mojo — PbFieldCursor's three refusals.
# =============================================================================
#
#   C1  the window check in `__init__`: start < 0, end < start and
#       end > len(bytes) are each refused; the empty window at the end and
#       the whole buffer are accepted.
#   C2  the message-boundary gate `_bound`, at each of its six call sites
#       (next_tag, read_varint, read_fixed32, read_fixed64, read_len,
#       skip): a sub-message minted by `read_message()` whose last field runs
#       into the parent's following bytes is refused, although every byte
#       read is inside the buffer. A field that ends exactly at the
#       sub-message end is accepted.
#   C3  the wire-type check of each accessor family (VARINT, FIXED32,
#       FIXED64, LEN), including an accessor called before any `next_tag()`;
#       the refusal happens before any byte is read, so the matching accessor
#       still reads the value afterwards.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true, assert_raises

from komira_protobuf import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    PbFieldCursor,
    pb_write_varint_field,
    pb_write_fixed32_field,
    pb_write_fixed64_field,
    pb_write_string_field,
)


# C1 ===========================================================================


def test_window_check() raises:
    var b = List[UInt8](
        [UInt8(8), UInt8(1), UInt8(8), UInt8(2), UInt8(8), UInt8(3)]
    )
    with assert_raises(
        contains="PbFieldCursor window [-1, 2) is not inside the 6-byte buffer"
    ):
        _ = PbFieldCursor(Span(b), -1, 2)
    with assert_raises(contains="PbFieldCursor window [3, 2)"):
        _ = PbFieldCursor(Span(b), 3, 2)
    with assert_raises(contains="PbFieldCursor window [0, 7)"):
        _ = PbFieldCursor(Span(b), 0, 7)
    var at_end = PbFieldCursor(Span(b), 6, 6)
    assert_false(at_end.has_next(), "empty window at end")
    var whole = PbFieldCursor(Span(b), 2, 6)
    var n = 0
    while whole.has_next():
        _ = whole.next_tag()
        n += Int(whole.read_varint())
    assert_equal(n, 5, "window [2, 6) reads fields 2 and 3")


# C2 ===========================================================================


def _parent(sub: List[UInt8], tail: List[UInt8]) -> List[UInt8]:
    """Field 1 (LEN) holding `sub`, then the raw `tail` bytes of the parent."""
    var out = List[UInt8]([UInt8(0x0A), UInt8(len(sub))])
    out.extend(sub.copy())
    out.extend(tail.copy())
    return out^


def _sub_of(parent: List[UInt8]) raises -> PbFieldCursor[origin_of(parent)]:
    var cur = PbFieldCursor.over(Span(parent))
    _ = cur.next_tag()
    return cur.read_message()


def test_bound_next_tag() raises:
    # Sub-message [0x88]: a tag varint whose continuation byte is the
    # parent's next byte.
    var p = _parent(List[UInt8]([UInt8(0x88)]), List[UInt8]([UInt8(0x01)]))
    var sub = _sub_of(p)
    assert_true(sub.has_next(), "one byte inside the sub-message")
    with assert_raises(
        contains="field tag runs past the end of its message (ends at 4,"
        " message ends at 3)"
    ):
        _ = sub.next_tag()


def test_bound_read_varint() raises:
    var p = _parent(
        List[UInt8]([UInt8(0x08), UInt8(0x80)]), List[UInt8]([UInt8(0x01)])
    )
    var sub = _sub_of(p)
    _ = sub.next_tag()
    with assert_raises(contains="varint field runs past the end of its message"):
        _ = sub.read_varint()


def test_bound_read_fixed32() raises:
    var p = _parent(
        List[UInt8]([UInt8(0x0D), UInt8(0xAA)]),
        List[UInt8]([UInt8(0xBB), UInt8(0xCC), UInt8(0xDD)]),
    )
    var sub = _sub_of(p)
    _ = sub.next_tag()
    with assert_raises(contains="fixed32 field runs past the end of its message"):
        _ = sub.read_fixed32()
    # The same field fitting exactly is read.
    var inner = List[UInt8]()
    pb_write_fixed32_field(inner, 1, 0xDDCCBBAA)
    var q = _parent(inner, List[UInt8]([UInt8(0xEE)]))
    var ok = _sub_of(q)
    _ = ok.next_tag()
    assert_equal(ok.read_fixed32(), UInt32(0xDDCCBBAA), "exact fixed32")
    assert_false(ok.has_next(), "sub-message consumed")


def test_bound_read_fixed64() raises:
    var tail = List[UInt8]()
    for i in range(7):
        tail.append(UInt8(i))
    var p = _parent(List[UInt8]([UInt8(0x09), UInt8(0xAA)]), tail)
    var sub = _sub_of(p)
    _ = sub.next_tag()
    with assert_raises(contains="fixed64 field runs past the end of its message"):
        _ = sub.read_fixed64()
    var inner = List[UInt8]()
    pb_write_fixed64_field(inner, 1, 0x0102030405060708)
    var q = _parent(inner, tail)
    var ok = _sub_of(q)
    _ = ok.next_tag()
    assert_equal(ok.read_fixed64(), UInt64(0x0102030405060708), "exact fixed64")


def test_bound_read_len() raises:
    # Sub-message [0x0A, 0x05]: a 5-byte string whose payload is the parent's
    # next five bytes "hello". Without the gate the sub-message returns them.
    var hello = List[UInt8]("hello".as_bytes())
    var p = _parent(List[UInt8]([UInt8(0x0A), UInt8(0x05)]), hello)
    var sub = _sub_of(p)
    _ = sub.next_tag()
    with assert_raises(
        contains="length-delimited field runs past the end of its message"
    ):
        _ = sub.read_string()
    # Through read_message the same overrun is refused.
    var sub2 = _sub_of(p)
    _ = sub2.next_tag()
    with assert_raises(
        contains="length-delimited field runs past the end of its message"
    ):
        _ = sub2.read_message()
    var inner = List[UInt8]()
    pb_write_string_field(inner, 1, String("hi"))
    var q = _parent(inner, hello)
    var ok = _sub_of(q)
    _ = ok.next_tag()
    assert_equal(ok.read_string(), String("hi"), "exact string")


def test_bound_skip() raises:
    var p = _parent(
        List[UInt8]([UInt8(0x0D), UInt8(0xAA)]),
        List[UInt8]([UInt8(0xBB), UInt8(0xCC), UInt8(0xDD)]),
    )
    var sub = _sub_of(p)
    _ = sub.next_tag()
    with assert_raises(contains="skipped field runs past the end of its message"):
        sub.skip()
    var inner = List[UInt8]()
    pb_write_fixed32_field(inner, 1, 7)
    var q = _parent(inner, List[UInt8]([UInt8(0x01)]))
    var ok = _sub_of(q)
    _ = ok.next_tag()
    ok.skip()
    assert_false(ok.has_next(), "exact skip")


# C3 ===========================================================================


def _one_field(wire: Int) -> List[UInt8]:
    var m = List[UInt8]()
    if wire == PB_WIRE_VARINT:
        pb_write_varint_field(m, 1, 5)
    elif wire == PB_WIRE_FIXED32:
        pb_write_fixed32_field(m, 1, 5)
    elif wire == PB_WIRE_FIXED64:
        pb_write_fixed64_field(m, 1, 5)
    else:
        pb_write_string_field(m, 1, String("x"))
    return m^


def test_wire_mismatch_varint() raises:
    var m = _one_field(PB_WIRE_VARINT)
    var before = PbFieldCursor.over(Span(m))
    with assert_raises(contains="WIRE_MISMATCH: expected VARINT"):
        _ = before.read_varint()

    var f = _one_field(PB_WIRE_FIXED32)
    var c = PbFieldCursor.over(Span(f))
    var t = c.next_tag()
    assert_equal(t.wire_type, PB_WIRE_FIXED32, "fixed32 tag")
    with assert_raises(contains="WIRE_MISMATCH: expected VARINT"):
        _ = c.read_varint()
    with assert_raises(contains="WIRE_MISMATCH: expected VARINT"):
        _ = c.read_bool()
    with assert_raises(contains="WIRE_MISMATCH: expected VARINT"):
        _ = c.read_sint64()
    with assert_raises(contains="WIRE_MISMATCH: expected VARINT"):
        _ = c.read_sint32()
    assert_equal(c.read_fixed32(), UInt32(5), "position kept after refusals")


def test_wire_mismatch_fixed32() raises:
    var f = _one_field(PB_WIRE_FIXED64)
    var c = PbFieldCursor.over(Span(f))
    _ = c.next_tag()
    with assert_raises(contains="WIRE_MISMATCH: expected FIXED32"):
        _ = c.read_fixed32()
    with assert_raises(contains="WIRE_MISMATCH: expected FIXED32"):
        _ = c.read_float()
    assert_equal(c.read_fixed64(), UInt64(5), "position kept after refusals")


def test_wire_mismatch_fixed64() raises:
    var f = _one_field(PB_WIRE_FIXED32)
    var c = PbFieldCursor.over(Span(f))
    _ = c.next_tag()
    with assert_raises(contains="WIRE_MISMATCH: expected FIXED64"):
        _ = c.read_fixed64()
    with assert_raises(contains="WIRE_MISMATCH: expected FIXED64"):
        _ = c.read_double()
    assert_equal(c.read_fixed32(), UInt32(5), "position kept after refusals")


def test_wire_mismatch_len() raises:
    var f = _one_field(PB_WIRE_VARINT)
    var c = PbFieldCursor.over(Span(f))
    _ = c.next_tag()
    with assert_raises(contains="WIRE_MISMATCH: expected LEN"):
        _ = c.read_len()
    with assert_raises(contains="WIRE_MISMATCH: expected LEN"):
        _ = c.read_string()
    with assert_raises(contains="WIRE_MISMATCH: expected LEN"):
        _ = c.read_bytes()
    with assert_raises(contains="WIRE_MISMATCH: expected LEN"):
        _ = c.read_message()
    with assert_raises(contains="WIRE_MISMATCH: expected LEN"):
        _ = c.read_packed_varints()
    with assert_raises(contains="WIRE_MISMATCH: expected LEN"):
        _ = c.read_packed_sint64()
    assert_equal(c.read_varint(), UInt64(5), "position kept after refusals")
    var s = _one_field(PB_WIRE_LEN)
    var d = PbFieldCursor.over(Span(s))
    _ = d.next_tag()
    assert_equal(d.read_string(), String("x"), "LEN accessor on LEN tag")


def main() raises:
    test_window_check()
    test_bound_next_tag()
    test_bound_read_varint()
    test_bound_read_fixed32()
    test_bound_read_fixed64()
    test_bound_read_len()
    test_bound_skip()
    test_wire_mismatch_varint()
    test_wire_mismatch_fixed32()
    test_wire_mismatch_fixed64()
    test_wire_mismatch_len()
    print("test_protobuf_cursor_guards: ALL PASS")
