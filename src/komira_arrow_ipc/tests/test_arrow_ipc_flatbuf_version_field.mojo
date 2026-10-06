# =============================================================================
# test_arrow_ipc_flatbuf_version_field.mojo: Message.version and
# Footer.version are read as exactly their 2 bytes.
# =============================================================================
#
# `version` is an i16. `read_message` and `read_footer` read it as a u32 and
# masked the high half off, so the read reached 2 bytes past the field. When
# the field is the last thing in the flatbuffer, that read is past the
# payload: the bounds-checked reader refuses a well-formed table, and a reader
# without the check reads 2 bytes beyond the buffer.
#
# Each table below is hand-laid so its version field occupies the payload's
# last 2 bytes. The decoded version must be 4 (MetadataVersion V5). The same
# payload cut by one byte, inside the field, must be refused by the
# bounds-checked reader with a 2-byte width.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow_ipc.ipc_flatbuf import (
    flatbuf_reader_over,
    read_footer,
    read_message,
)


def _u16(mut b: List[UInt8], v: Int):
    b.append(UInt8(v & 0xFF))
    b.append(UInt8((v >> 8) & 0xFF))


def _u32(mut b: List[UInt8], v: Int):
    _u16(b, v & 0xFFFF)
    _u16(b, (v >> 16) & 0xFFFF)


def _buf(bytes: List[UInt8], n: Int) -> SharedAlignedBuffer[HeapRegion]:
    """The first `n` bytes of `bytes` as a payload of length `n`."""
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    for i in range(n):
        out.write_u8_at(i, bytes[i])
    out.set_length(n)
    return out^


def _message_ending_in_version() -> List[UInt8]:
    """Root offset, a 3-slot vtable at 4, the Message table at 14:
    soffset, header_tag (1) at +4, header uoffset at +8 (to +12) and the
    version (4) at +12..+14, the payload's last 2 bytes (28 bytes)."""
    var b = List[UInt8]()
    _u32(b, 14)  # root table position
    _u16(b, 10)  # vtable size: 4 + 3 slots
    _u16(b, 14)  # table size
    _u16(b, 12)  # field 0 version
    _u16(b, 4)  # field 1 header_type
    _u16(b, 8)  # field 2 header
    _u32(b, 10)  # table soffset: 14 - 4
    b.append(UInt8(1))  # header_type: Schema
    b.append(UInt8(0))
    b.append(UInt8(0))
    b.append(UInt8(0))
    _u32(b, 4)  # header uoffset: 22 + 4 = 26
    _u16(b, 4)  # version V5
    return b^


def _footer_ending_in_version() -> List[UInt8]:
    """Root offset, a 2-slot vtable at 4, the Footer table at 12: soffset,
    schema uoffset at +4 (to +8) and the version (4) at +8..+10, the
    payload's last 2 bytes (22 bytes)."""
    var b = List[UInt8]()
    _u32(b, 12)  # root table position
    _u16(b, 8)  # vtable size: 4 + 2 slots
    _u16(b, 10)  # table size
    _u16(b, 8)  # field 0 version
    _u16(b, 4)  # field 1 schema
    _u32(b, 8)  # table soffset: 12 - 4
    _u32(b, 4)  # schema uoffset: 16 + 4 = 20
    _u16(b, 4)  # version V5
    return b^


def _cut_error(n: Int, pos: Int) -> String:
    return (
        "FlatbufReader: read at pos " + String(pos)
        + " + width 2 exceeds payload length " + String(n)
    )


def test_message_version_at_payload_end_reads() raises:
    var bytes = _message_ending_in_version()
    assert_equal(len(bytes), 28)
    var buf = _buf(bytes, 28)
    var r = flatbuf_reader_over(buf)
    var msg = read_message(r, r.read_root_offset())
    assert_equal(msg.version, Int16(4))
    assert_equal(msg.header_tag, UInt8(1))
    assert_equal(msg.header_table_pos, 26)
    assert_equal(msg.body_length, Int64(0))


def test_message_version_cut_inside_field_is_refused() raises:
    var buf = _buf(_message_ending_in_version(), 27)
    var r = flatbuf_reader_over(buf)
    var got = String("")
    try:
        _ = read_message(r, r.read_root_offset())
    except e:
        got = String(e)
    assert_equal(got, _cut_error(27, 26))


def test_footer_version_at_payload_end_reads() raises:
    var bytes = _footer_ending_in_version()
    assert_equal(len(bytes), 22)
    var buf = _buf(bytes, 22)
    var r = flatbuf_reader_over(buf)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(footer.version, Int16(4))
    assert_equal(footer.schema_table_pos, 20)
    assert_equal(len(footer.dictionaries), 0)
    assert_equal(len(footer.record_batches), 0)


def test_footer_version_cut_inside_field_is_refused() raises:
    var buf = _buf(_footer_ending_in_version(), 21)
    var r = flatbuf_reader_over(buf)
    var got = String("")
    try:
        _ = read_footer(r, r.read_root_offset())
    except e:
        got = String(e)
    assert_equal(got, _cut_error(21, 20))


def test_version_absent_or_beyond_vtable_reads_zero() raises:
    """Controls for the reader's two default arms: a vtable too short to
    declare field 0, and a field-0 slot of 0 (absent)."""
    # Message vtable declaring no slots at all would also drop the header, so
    # these use the Footer, whose only required field is the schema.
    var b = List[UInt8]()
    _u32(b, 12)
    _u16(b, 8)
    _u16(b, 8)
    _u16(b, 0)  # field 0 absent
    _u16(b, 4)  # field 1 schema
    _u32(b, 8)
    _u32(b, 0)  # schema uoffset: 16 + 0 = 16
    var buf = _buf(b, len(b))
    var r = flatbuf_reader_over(buf)
    assert_equal(read_footer(r, r.read_root_offset()).version, Int16(0))


def test_vtable_without_slots_defaults_version() raises:
    """A vtable of 4 bytes declares no field, so version is the default and
    the Footer is refused only for its missing schema. A reader that took
    the slot anyway would read the table's soffset bytes as a field offset
    (4, so position 12, the payload end) and fail on that read instead."""
    var b = List[UInt8]()
    _u32(b, 8)
    _u16(b, 4)  # vtable size: no slots
    _u16(b, 4)
    _u32(b, 4)  # soffset: vtable at 8 - 4 = 4
    var buf = _buf(b, len(b))
    var r = flatbuf_reader_over(buf)
    var got = String("")
    try:
        _ = read_footer(r, r.read_root_offset())
    except e:
        got = String(e)
    assert_equal(got, "Footer: schema field missing")


def test_negative_vtable_position_is_refused() raises:
    """A table soffset pointing before the payload start."""
    var b = List[UInt8]()
    _u32(b, 4)
    _u32(b, 100)  # soffset: vtable at 4 - 100 < 0
    _u16(b, 0)
    var buf = _buf(b, len(b))
    var r = flatbuf_reader_over(buf)
    var got = String("")
    try:
        _ = read_footer(r, r.read_root_offset())
    except e:
        got = String(e)
    assert_equal(got, "FlatbufReader: invalid vtable position -96")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
