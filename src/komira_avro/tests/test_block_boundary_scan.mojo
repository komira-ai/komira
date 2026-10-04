# =============================================================================
# test_block_boundary_scan.mojo — OCF block-boundary discovery (sync walk).
# =============================================================================
#
# Acceptance:
#   discover N blocks in a synthetic OCF fixture (built in-test; no external
#   Avro library needed).
#
# Coverage:
#   T1  discover N=3 blocks; per-block object_count + payload_len + offset.
#   T2  empty file (header only, no blocks) -> 0 blocks.
#   T3  sync-marker mismatch (corrupt trailing sync) -> raises.
#   T4  truncated block (payload overruns file) -> raises.
#   T5  scalar resync helper finds the next sync marker after an offset.
#   T6  larger fixture (many small blocks) discovers exact count.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    scan_ocf_blocks,
    find_sync_marker_from,
    decode_ocf_header,
    OCF_SYNC_LEN,
)


# -----------------------------------------------------------------------------
# In-test OCF binary encoders (shared shape with the header test).
# -----------------------------------------------------------------------------

def _encode_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _encode_string(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _encode_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _encode_bytes_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _encode_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


comptime _SCHEMA = String(
    '{"type":"record","name":"R","fields":[{"name":"v","type":"long"}]}'
)


def _make_header(mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _encode_long(Int64(2), out)
    _encode_string(String("avro.schema"), out)
    _encode_bytes_str(_SCHEMA, out)
    _encode_string(String("avro.codec"), out)
    _encode_bytes_str(String("null"), out)
    _encode_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _append_block(
    mut out: List[UInt8], object_count: Int64, payload: List[UInt8], good_sync: Bool
):
    """Append one OCF block: object_count + byte_count + payload + sync."""
    _encode_long(object_count, out)
    _encode_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        # Optionally corrupt the first sync byte to simulate damage.
        if i == 0 and not good_sync:
            out.append(UInt8(0x00))
        else:
            out.append(s[i])


def _payload(n: Int) -> List[UInt8]:
    var p = List[UInt8]()
    for i in range(n):
        p.append(UInt8(i & 0xFF))
    return p^


def test_discover_three_blocks() raises:
    """T1: a 3-block fixture discovers exactly 3 blocks with right metadata."""
    var buf = List[UInt8]()
    _make_header(buf)
    _append_block(buf, Int64(10), _payload(20), True)
    _append_block(buf, Int64(5), _payload(8), True)
    _append_block(buf, Int64(7), _payload(13), True)

    var blocks = scan_ocf_blocks(Span(buf))
    assert_equal(len(blocks), 3, "block count")
    assert_equal(blocks[0].object_count, Int64(10))
    assert_equal(blocks[0].payload_len, 20)
    assert_equal(blocks[1].object_count, Int64(5))
    assert_equal(blocks[1].payload_len, 8)
    assert_equal(blocks[2].object_count, Int64(7))
    assert_equal(blocks[2].payload_len, 13)
    # Payload offset of block 0 must point into the buffer just past the two
    # block-header varints (after header_len).
    var hdr = decode_ocf_header(Span(buf))
    assert_true(blocks[0].payload_offset > hdr.header_len, "payload after header")


def test_empty_file_zero_blocks() raises:
    """T2: a header-only file has zero blocks."""
    var buf = List[UInt8]()
    _make_header(buf)
    var blocks = scan_ocf_blocks(Span(buf))
    assert_equal(len(blocks), 0, "no blocks in header-only file")


def test_sync_mismatch_raises() raises:
    """T3: a corrupt trailing sync marker raises SYNC_MISMATCH."""
    var buf = List[UInt8]()
    _make_header(buf)
    _append_block(buf, Int64(3), _payload(6), False)  # corrupt sync
    var raised = False
    try:
        var _b = scan_ocf_blocks(Span(buf))
    except:
        raised = True
    assert_true(raised, "corrupt sync marker must raise")


def test_truncated_block_raises() raises:
    """T4: a block whose declared byte_count overruns the file raises."""
    var buf = List[UInt8]()
    _make_header(buf)
    # object_count then a huge byte_count with no payload bytes following.
    _encode_long(Int64(1), buf)
    _encode_long(Int64(9999), buf)
    var raised = False
    try:
        var _b = scan_ocf_blocks(Span(buf))
    except:
        raised = True
    assert_true(raised, "truncated block must raise")


def test_scalar_resync_finds_marker() raises:
    """T5: the scalar resync helper finds the next sync marker after offset."""
    var buf = List[UInt8]()
    _make_header(buf)
    _append_block(buf, Int64(2), _payload(5), True)
    var hdr = decode_ocf_header(Span(buf))
    # Search from the first block start; expect the first sync marker (end of
    # block 0) to be found.
    var next_off = find_sync_marker_from(Span(buf), hdr.header_len, hdr.sync_marker)
    assert_true(next_off > 0, "resync must find the block-0 trailing sync")
    assert_equal(next_off, len(buf), "next block starts at end-of-file here")


def test_many_small_blocks() raises:
    """T6: a fixture with many tiny blocks discovers the exact count."""
    var buf = List[UInt8]()
    _make_header(buf)
    var n = 64
    for i in range(n):
        _append_block(buf, Int64(i + 1), _payload(3), True)
    var blocks = scan_ocf_blocks(Span(buf))
    assert_equal(len(blocks), n, "discovered all small blocks")
    # Spot-check object counts are in order.
    assert_equal(blocks[0].object_count, Int64(1))
    assert_equal(blocks[n - 1].object_count, Int64(n))


def main() raises:
    test_discover_three_blocks()
    test_empty_file_zero_blocks()
    test_sync_mismatch_raises()
    test_truncated_block_raises()
    test_scalar_resync_finds_marker()
    test_many_small_blocks()
    print("test_block_boundary_scan: ALL PASS")
