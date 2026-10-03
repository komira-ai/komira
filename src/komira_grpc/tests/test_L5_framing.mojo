# =============================================================================
# test_L5_framing.mojo — ClientFramer sliding-buffer envelope extraction
# =============================================================================
#
# framing.mojo coverage: the 5-byte length-prefix framer over the Data
# frames.
#
# Coverage:
#   T1   Empty framer — try_pop_envelope returns None.
#   T2   Single-envelope round-trip via write_envelope → feed → pop.
#   T3   Multi-envelope stream — feed once with N envelopes, pop them in
#        order.
#   T4   Fragmented header — feed 3 bytes of header, then 2 more, then
#        payload; framer assembles correctly.
#   T5   Fragmented payload — feed header + half payload, then other half.
#   T6   Envelope-then-extra — feed an envelope plus the first 3 bytes of
#        the next header; pop yields exactly one envelope and the next
#        try_pop returns None (more bytes needed).
#   T7   PoppedEnvelope.is_compressed / is_end_stream flag inspection.
#   T8   Compaction — feed enough bytes to trigger compaction (>256B, >50%
#        consumed); subsequent pops still work.
#   T9   feed_owned move semantics — drained buffer is replaced outright.
#   T10  reset() empties the framer.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import ClientFramer, PoppedEnvelope
from komira_connect.envelope import (
    write_envelope,
    write_envelope_header,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
)


def test_t1_empty_framer() raises:
    """T1 — empty framer returns None."""
    var f = ClientFramer.new()
    assert_equal(f.unconsumed_len(), 0, "empty len 0")
    var opt = f.try_pop_envelope()
    assert_false(opt.__bool__(), "no envelope")


def test_t2_single_envelope() raises:
    """T2 — single-envelope round-trip."""
    # Build wire bytes
    var wire = List[UInt8]()
    var payload = List[UInt8]()
    payload.append(UInt8(0xDE))
    payload.append(UInt8(0xAD))
    payload.append(UInt8(0xBE))
    payload.append(UInt8(0xEF))
    write_envelope(wire, UInt8(0), Span(payload))

    var f = ClientFramer.new()
    f.feed(Span(wire))
    var opt = f.try_pop_envelope()
    assert_true(opt.__bool__(), "envelope available")
    var env = opt.take()
    assert_equal(env.flags, UInt8(0), "flags")
    assert_equal(len(env.payload), 4, "4-byte payload")
    assert_equal(env.payload[0], UInt8(0xDE), "byte 0")
    assert_equal(env.payload[1], UInt8(0xAD), "byte 1")
    assert_equal(env.payload[2], UInt8(0xBE), "byte 2")
    assert_equal(env.payload[3], UInt8(0xEF), "byte 3")

    # Now framer is drained
    var opt2 = f.try_pop_envelope()
    assert_false(opt2.__bool__(), "drained")


def test_t3_multi_envelope_stream() raises:
    """T3 — feed N envelopes, pop in order."""
    var wire = List[UInt8]()
    var p1 = List[UInt8]()
    p1.append(UInt8(1))
    var p2 = List[UInt8]()
    p2.append(UInt8(2))
    p2.append(UInt8(2))
    var p3 = List[UInt8]()
    p3.append(UInt8(3))
    p3.append(UInt8(3))
    p3.append(UInt8(3))
    write_envelope(wire, UInt8(0), Span(p1))
    write_envelope(wire, UInt8(0), Span(p2))
    write_envelope(wire, UInt8(0), Span(p3))

    var f = ClientFramer.new()
    f.feed(Span(wire))

    var opt1 = f.try_pop_envelope()
    var e1 = opt1.take()
    assert_equal(len(e1.payload), 1, "env1 size")
    assert_equal(e1.payload[0], UInt8(1), "env1 byte")

    var opt2 = f.try_pop_envelope()
    var e2 = opt2.take()
    assert_equal(len(e2.payload), 2, "env2 size")
    assert_equal(e2.payload[0], UInt8(2), "env2 byte")

    var opt3 = f.try_pop_envelope()
    var e3 = opt3.take()
    assert_equal(len(e3.payload), 3, "env3 size")
    assert_equal(e3.payload[0], UInt8(3), "env3 byte")


def test_t4_fragmented_header() raises:
    """T4 — feed header in fragments, then payload."""
    var f = ClientFramer.new()
    # Build full envelope wire
    var wire = List[UInt8]()
    var payload = List[UInt8]()
    payload.append(UInt8(0xAA))
    payload.append(UInt8(0xBB))
    write_envelope(wire, UInt8(0), Span(payload))
    # Feed first 3 header bytes
    var frag1 = List[UInt8]()
    frag1.append(wire[0])
    frag1.append(wire[1])
    frag1.append(wire[2])
    f.feed(Span(frag1))
    assert_false(f.try_pop_envelope().__bool__(), "not enough for header")
    # Feed next 2 header bytes
    var frag2 = List[UInt8]()
    frag2.append(wire[3])
    frag2.append(wire[4])
    f.feed(Span(frag2))
    # Header complete, payload not — still None
    assert_false(f.try_pop_envelope().__bool__(), "header complete but no payload")
    # Feed payload
    var frag3 = List[UInt8]()
    frag3.append(wire[5])
    frag3.append(wire[6])
    f.feed(Span(frag3))
    var e_opt = f.try_pop_envelope()
    var e = e_opt.take()
    assert_equal(len(e.payload), 2, "2-byte payload")
    assert_equal(e.payload[0], UInt8(0xAA), "byte 0")
    assert_equal(e.payload[1], UInt8(0xBB), "byte 1")


def test_t5_fragmented_payload() raises:
    """T5 — header + half payload, then other half."""
    var f = ClientFramer.new()
    var payload = List[UInt8]()
    for i in range(10):
        payload.append(UInt8(i))
    var wire = List[UInt8]()
    write_envelope(wire, UInt8(0), Span(payload))
    # Header (5) + first 5 payload bytes
    var part1 = List[UInt8]()
    var i = 0
    while i < 10:
        part1.append(wire[i])
        i = i + 1
    f.feed(Span(part1))
    assert_false(f.try_pop_envelope().__bool__(), "payload incomplete")
    # Remaining 5 payload bytes
    var part2 = List[UInt8]()
    var j = 10
    while j < 15:
        part2.append(wire[j])
        j = j + 1
    f.feed(Span(part2))
    var e_opt = f.try_pop_envelope()
    var e = e_opt.take()
    assert_equal(len(e.payload), 10, "10-byte payload")
    var k = 0
    while k < 10:
        assert_equal(e.payload[k], UInt8(k), "byte k")
        k = k + 1


def test_t6_envelope_then_partial_next_header() raises:
    """T6 — envelope + first 3 bytes of next header; pop one, then None."""
    var f = ClientFramer.new()
    var payload = List[UInt8]()
    payload.append(UInt8(0x42))
    var wire1 = List[UInt8]()
    write_envelope(wire1, UInt8(0), Span(payload))
    f.feed(Span(wire1))
    # Append 3 bytes of a NEW header (not enough to complete it)
    var partial = List[UInt8]()
    partial.append(UInt8(0))
    partial.append(UInt8(0))
    partial.append(UInt8(0))
    f.feed(Span(partial))

    var e_opt = f.try_pop_envelope()
    var e = e_opt.take()
    assert_equal(len(e.payload), 1, "first envelope payload size")
    assert_equal(e.payload[0], UInt8(0x42), "byte")

    # Now only 3 bytes of header remain — not poppable
    assert_false(
        f.try_pop_envelope().__bool__(),
        "next envelope still buffered as 3-byte header fragment",
    )


def test_t7_flag_inspection() raises:
    """T7 — is_compressed + is_end_stream flag inspection."""
    var f = ClientFramer.new()
    var p = List[UInt8]()
    p.append(UInt8(0xFF))
    var wire = List[UInt8]()
    write_envelope(
        wire,
        ENVELOPE_FLAG_COMPRESSED | ENVELOPE_FLAG_END_STREAM,
        Span(p),
    )
    f.feed(Span(wire))
    var e_opt = f.try_pop_envelope()
    var e = e_opt.take()
    assert_true(e.is_compressed(), "compressed bit")
    assert_true(e.is_end_stream(), "end-stream bit")


def test_t8_compaction() raises:
    """T8 — feed enough bytes to trigger compaction, subsequent pops work."""
    var f = ClientFramer.new()
    # Build a string of ~30 envelopes each carrying 20 bytes
    # → total ~30 * 25 = ~750 bytes wire; consuming half triggers compact.
    var i = 0
    while i < 30:
        var p = List[UInt8]()
        var j = 0
        while j < 20:
            p.append(UInt8(j))
            j = j + 1
        var wire = List[UInt8]()
        write_envelope(wire, UInt8(0), Span(p))
        f.feed(Span(wire))
        i = i + 1

    # Pop them all
    var popped = 0
    while True:
        var opt = f.try_pop_envelope()
        if not opt.__bool__():
            break
        var e = opt.take()
        assert_equal(len(e.payload), 20, "each envelope 20 bytes")
        popped += 1
    assert_equal(popped, 30, "all 30 popped")


def test_t9_feed_owned_swap() raises:
    """T9 — feed_owned replaces buffer when drained."""
    var f = ClientFramer.new()
    var p = List[UInt8]()
    p.append(UInt8(0x77))
    var wire = List[UInt8]()
    write_envelope(wire, UInt8(0), Span(p))
    f.feed_owned(wire^)
    var e_opt = f.try_pop_envelope()
    var e = e_opt.take()
    assert_equal(len(e.payload), 1, "1-byte payload")
    assert_equal(e.payload[0], UInt8(0x77), "byte")


def test_t10_reset() raises:
    """T10 — reset() empties the framer."""
    var f = ClientFramer.new()
    var p = List[UInt8]()
    p.append(UInt8(0x33))
    p.append(UInt8(0x33))
    var wire = List[UInt8]()
    write_envelope(wire, UInt8(0), Span(p))
    f.feed(Span(wire))
    assert_true(f.unconsumed_len() > 0, "had data")
    f.reset()
    assert_equal(f.unconsumed_len(), 0, "empty after reset")
    assert_false(f.try_pop_envelope().__bool__(), "no envelope after reset")


def main() raises:
    test_t1_empty_framer()
    test_t2_single_envelope()
    test_t3_multi_envelope_stream()
    test_t4_fragmented_header()
    test_t5_fragmented_payload()
    test_t6_envelope_then_partial_next_header()
    test_t7_flag_inspection()
    test_t8_compaction()
    test_t9_feed_owned_swap()
    test_t10_reset()
    print("test_L5_framing: 10/10 PASS")
