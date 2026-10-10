# =============================================================================
# test_orc_packed_varint_block_bound.mojo — a packed repeated varint field is
# decoded inside its own LEN block, never from the bytes after it.
# =============================================================================
#
# `OrcRawType.parse` (field 2, `subtypes`) and `OrcRowIndexEntry.parse`
# (field 1, `positions`) decode packed varint blocks with their own loops.
# Each value must end inside `[payload_start, payload_end)`. A varint that
# starts in the block and whose continuation bit points past the block end is
# malformed: the parser must raise, not decode the value from the next field
# or the bytes after the message (komira-ai/komira#1241).
#
# Coverage:
#   P1  OrcRowIndexEntry: block [0x80], then 0x01 outside the message -> raise.
#   P1b OrcRowIndexEntry: block [0x80], then field 2 (statistics, empty)
#       inside the same message -> raise. Bounding the read by the message
#       end instead of the block end would decode [0x80 0x12] = 2304 from
#       the next field's tag; P1 alone cannot tell those bounds apart.
#   P2  OrcRawType: block [0x80], then field 1 (kind=5) -> raise (before the
#       fix: subtypes == [1024], the next field's tag byte read as payload).
#   P3  Both: a valid block whose last value is multi-byte and ends exactly
#       at the block end still decodes (the bound is the block end, not one
#       byte short of it), and the field after the block is still parsed.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import OrcRawType, OrcRowIndexEntry


def _assert_block_overrun(err: Error) raises:
    var msg = String(err)
    assert_true(
        "ProtobufError.MALFORMED" in msg and "varint runs past" in msg,
        String("expected a varint-overrun refusal, got: ") + msg,
    )


def test_row_index_positions_varint_past_block_raises() raises:
    """P1: positions block [0x80]; the 0x01 at index 3 is outside it."""
    var b = List[UInt8]([UInt8(0x0A), UInt8(0x01), UInt8(0x80), UInt8(0x01)])
    var raised = False
    try:
        var e = OrcRowIndexEntry.parse(Span(b), 0, 3)
        print("unexpected positions len:", len(e.positions))
    except err:
        _assert_block_overrun(err)
        raised = True
    assert_true(raised, "positions varint crossing the block end decoded")


def test_row_index_positions_varint_into_next_field_raises() raises:
    """P1b: positions block [0x80]; the next byte is field 2's tag (0x12),
    still inside the message, so only the block end refuses it."""
    var b = List[UInt8](
        [UInt8(0x0A), UInt8(0x01), UInt8(0x80), UInt8(0x12), UInt8(0x00)]
    )
    var raised = False
    try:
        var e = OrcRowIndexEntry.parse(Span(b), 0, 5)
        print("unexpected positions len:", len(e.positions))
    except err:
        _assert_block_overrun(err)
        raised = True
    assert_true(raised, "positions varint read into the next field decoded")


def test_raw_type_subtypes_varint_past_block_raises() raises:
    """P2: subtypes block [0x80]; the next byte is field 1's tag (0x08)."""
    var t = List[UInt8](
        [UInt8(0x12), UInt8(0x01), UInt8(0x80), UInt8(0x08), UInt8(0x05)]
    )
    var raised = False
    try:
        var r = OrcRawType.parse(Span(t), 0, 5)
        print("unexpected subtypes len:", len(r.subtypes), "kind:", r.kind)
    except err:
        _assert_block_overrun(err)
        raised = True
    assert_true(raised, "subtypes varint crossing the block end decoded")


def test_valid_packed_blocks_still_decode() raises:
    """P3: [0x05, 0x80 0x01] is {5, 128}, the 2-byte value ending at the
    block end; the field after the block is still read."""
    # OrcRowIndexEntry: positions block of 3 bytes, then a 4th trailing byte
    # outside the message that must not be touched.
    var b = List[UInt8](
        [
            UInt8(0x0A),
            UInt8(0x03),
            UInt8(0x05),
            UInt8(0x80),
            UInt8(0x01),
            UInt8(0xFF),
        ]
    )
    var e = OrcRowIndexEntry.parse(Span(b), 0, 5)
    assert_equal(len(e.positions), 2)
    assert_equal(e.positions[0], 5)
    assert_equal(e.positions[1], 128)

    # OrcRawType: subtypes block {5, 128}, then kind = 12.
    var t = List[UInt8](
        [
            UInt8(0x12),
            UInt8(0x03),
            UInt8(0x05),
            UInt8(0x80),
            UInt8(0x01),
            UInt8(0x08),
            UInt8(0x0C),
        ]
    )
    var r = OrcRawType.parse(Span(t), 0, 7)
    assert_equal(len(r.subtypes), 2)
    assert_equal(r.subtypes[0], 5)
    assert_equal(r.subtypes[1], 128)
    assert_equal(r.kind, 12)


def main() raises:
    # Each case runs even when an earlier one fails, so a red run names
    # every site that still reads past its block.
    var failed = 0
    try:
        test_row_index_positions_varint_past_block_raises()
    except err:
        print("FAIL P1 OrcRowIndexEntry positions:", err)
        failed += 1
    try:
        test_row_index_positions_varint_into_next_field_raises()
    except err:
        print("FAIL P1b OrcRowIndexEntry positions into next field:", err)
        failed += 1
    try:
        test_raw_type_subtypes_varint_past_block_raises()
    except err:
        print("FAIL P2 OrcRawType subtypes:", err)
        failed += 1
    try:
        test_valid_packed_blocks_still_decode()
    except err:
        print("FAIL P3 valid packed blocks:", err)
        failed += 1
    if failed != 0:
        raise Error(String(failed) + " packed-varint bound case(s) failed")
    print("test_orc_packed_varint_block_bound: ALL PASS")
