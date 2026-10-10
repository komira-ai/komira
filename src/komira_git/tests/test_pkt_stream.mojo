# =============================================================================
# komira_git/tests/test_pkt_stream.mojo -- PktReader over input fed in
# pieces, and side-band framing.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: gitprotocol-pack ("side-band, side-band-64k":
# up to 65519 bytes of data plus the band byte per packet, band 1 data, 2
# progress, 3 error) and git's send_sideband (sideband.c), which writes at
# most LARGE_PACKET_MAX - 5 = 65515 data bytes per packet.
#
# WHAT EACH TEST CATCHES:
#   * test_sideband_chunks: a chunk limit off by one either side (65515 in
#     one packet, 65516 in two), a band byte left out, an empty write that
#     emits an empty packet.
#   * test_sideband_refusal: a band outside 1..3 accepted.
#   * test_reader_pieces: a reader that consumes a partial line, or loses
#     bytes across feeds.
#   * test_reader_rewind: rewind that does not restore the position.
#   * test_reader_compaction: the compaction after 64 KiB of read input
#     dropping or duplicating unread bytes.
#   * test_take_buffered: the bytes after the pkt-lines (a pack) lost.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    PKT_DATA,
    PKT_FLUSH,
    PKT_NEED_MORE,
    SIDEBAND_MAX_CHUNK,
    PktReader,
    append_pkt_data,
    append_pkt_flush,
    append_pkt_text,
    append_sideband,
)


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def test_sideband_chunks() raises:
    assert_equal(SIDEBAND_MAX_CHUNK, 65515)
    var data = List[UInt8](length=65516, fill=UInt8(0x61))
    var out = List[UInt8]()
    append_sideband(out, 1, Span(data)[0:65515])
    assert_equal(len(out), 65520)
    assert_equal(String(StringSlice(from_utf8=Span(out)[0:4])), "fff0")
    assert_equal(Int(out[4]), 1)
    out.clear()
    append_sideband(out, 2, Span(data))
    # 65515 bytes, then the last byte in a packet of its own.
    assert_equal(len(out), 65520 + 6)
    assert_equal(String(StringSlice(from_utf8=Span(out)[65520:65524])), "0006")
    assert_equal(Int(out[65524]), 2)
    assert_equal(Int(out[65525]), 0x61)
    out.clear()
    append_sideband(out, 3, Span(List[UInt8]()))
    assert_equal(len(out), 0)
    var abc = _b("abc")
    append_sideband(out, 1, Span(abc))
    assert_equal(String(StringSlice(from_utf8=Span(out))), "0008\x01abc")


def test_sideband_refusal() raises:
    var out = List[UInt8]()
    var x = _b("x")
    for band in range(-1, 5):
        if band >= 1 and band <= 3:
            continue
        try:
            append_sideband(out, band, Span(x))
            assert_true(False)
        except e:
            assert_equal(
                String(e),
                "komira_git: side-band: band " + String(band) + " is not 1, 2 or 3",
            )


def test_reader_pieces() raises:
    var wire = List[UInt8]()
    append_pkt_text(wire, "command=ls-refs\n")
    append_pkt_flush(wire)
    var r = PktReader()
    for i in range(len(wire) - 4):
        r.feed(Span(wire)[i : i + 1])
        if i < 19:
            assert_equal(r.read().kind, PKT_NEED_MORE)
    var line = r.read()
    assert_equal(line.kind, PKT_DATA)
    assert_equal(len(line.payload), 16)
    assert_equal(r.read().kind, PKT_NEED_MORE)
    r.feed(Span(wire)[len(wire) - 4 : len(wire)])
    assert_equal(r.read().kind, PKT_FLUSH)
    assert_equal(r.buffered(), 0)


def test_reader_rewind() raises:
    var wire = List[UInt8]()
    append_pkt_text(wire, "a")
    append_pkt_text(wire, "b")
    var r = PktReader()
    r.feed(Span(wire))
    var m = r.mark()
    _ = r.read()
    _ = r.read()
    r.rewind(m)
    var again = r.read()
    assert_equal(Int(again.payload[0]), 0x61)


def test_reader_compaction() raises:
    # 1100 lines of 64 bytes: 70400 bytes, past the 65536 compaction point.
    # Fed 1201 bytes at a time, so a feed never ends on a line boundary
    # (lcm(1201, 64) > 70400): the read position is never the end of the
    # buffer at a feed, and the buffer is compacted rather than cleared.
    var wire = List[UInt8]()
    var payload = List[UInt8](length=60, fill=UInt8(0x7A))
    for i in range(1100):
        payload[0] = UInt8(48 + i % 10)
        append_pkt_data(wire, Span(payload))
    var r = PktReader()
    var seen = 0
    var pos = 0
    while pos < len(wire):
        var end = pos + 1201 if pos + 1201 < len(wire) else len(wire)
        r.feed(Span(wire)[pos:end])
        pos = end
        while True:
            var line = r.read()
            if line.kind == PKT_NEED_MORE:
                break
            assert_equal(Int(line.payload[0]), 48 + seen % 10)
            assert_equal(len(line.payload), 60)
            seen += 1
    assert_equal(seen, 1100)
    assert_equal(r.buffered(), 0)


def test_take_buffered() raises:
    var wire = List[UInt8]()
    append_pkt_flush(wire)
    var pack = _b("PACK\x00\x00\x00\x02")
    for i in range(len(pack)):
        wire.append(pack[i])
    var r = PktReader()
    r.feed(Span(wire))
    assert_equal(r.read().kind, PKT_FLUSH)
    var rest = r.take_buffered()
    assert_equal(len(rest), 8)
    assert_equal(Int(rest[0]), 0x50)
    assert_equal(Int(rest[7]), 2)
    assert_equal(r.buffered(), 0)


def main() raises:
    test_sideband_chunks()
    test_sideband_refusal()
    test_reader_pieces()
    test_reader_rewind()
    test_reader_compaction()
    test_take_buffered()
    print("komira_git pkt stream tests passed")
