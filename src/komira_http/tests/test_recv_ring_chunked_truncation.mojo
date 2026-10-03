# =============================================================================
# src/komira_http/tests/test_recv_ring_chunked_truncation.mojo
# =============================================================================
# ⛔ THE FALSIFIER FOR "A TRUNCATED CHUNKED BODY IS REPORTED AS TRUNCATED, AT
#    EVERY BYTE OFFSET IT CAN BE CUT AT".
#
# THE PRODUCTION DEFECT THIS IS ABOUT, byte for byte:
#
#     ERROR reconciler: find_stale_jobs failed:
#       HttpError[EOF_MID_RESPONSE: chunked body unterminated]
#
# raised at `response_body.mojo` `_finalize_on_eof`, CHUNKED arm.
#
# ⚠ THE UNCOMFORTABLE PART. Without this file, THAT LINE IS REACHED BY NO
# TEST. The other premature-EOF test
# (`test_recv_ring_body.mojo`, "Test 8: EOF mid-CL-body") is
# Content-Length-framed: it asserts a substring that matches the
# CONTENT_LENGTH arm ("short body — CL=… got=…") and can never distinguish
# the CHUNKED arm from it. The sibling
# `test_recv_ring_chunked_split_inside_framing.mojo` has ONE truncation case,
# hand-picked at one offset, as its anti-over-fit guard. Coverage by file
# count is not coverage.
#
# ★ THE METHOD, TAKEN FROM A REFERENCE IMPLEMENTATION. Go's
# `net/http/internal.TestIncompleteChunk` (golang/go issue 48861) drives EVERY
# proper prefix of a known-good chunked wire through the decoder and requires
# every one of them to report unexpected-EOF. It is ~10 lines and it is the
# single highest-yield chunked test there is, because "where did the peer cut
# us off" is not a case you can pick — it is a byte offset chosen by a TCP
# segment boundary, a Cloud Run 504, or an LB idle timer.
#
# ⚠ ONE DELIBERATE ADAPTATION OF GO'S FIXTURE, AND IT IS NOT A WEAKENING.
# Go's `valid` ends at "0\r\n", because Go's INTERNAL chunked reader stops at
# the last-chunk line and leaves the trailer section to `http.Transport`. OUR
# decoder implements the whole production in one place —
#     chunked-body = *chunk last-chunk trailer-section CRLF   (RFC 9112 §7.1)
# — so the complete wire here ends "0\r\n\r\n". Go's exact string is therefore
# a PROPER PREFIX of ours and is swept as one; `test_eof_after_last_chunk_
# line_before_final_crlf_is_incomplete` pins that specific offset by name,
# because "we already got the zero chunk, call it done" is the most tempting
# wrong answer in this decoder and it is silent data loss.
#
# ⛔ EVERY ASSERTION HERE IS ON THE ERROR'S KIND AND DETAIL, NEVER ON
# `caught == True`. The two pre-existing EOF tests in `test_state_machine.mojo`
# do `except _e: caught = True`, which stays GREEN if the driver raises a 250s
# TIMEOUT instead — and a 250s stall THEN a 504 is precisely the production
# symptom. An assertion that cannot tell the bug from the fix is not an
# assertion.
#
# No UnsafePointer crosses a boundary here; no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.response_body import RecvRingBody
from komira_http.transport.scripted import ScriptedStream


# The substring that identifies the CHUNKED arm of `_finalize_on_eof`. It is
# NOT "EOF_MID_RESPONSE" alone: the CONTENT_LENGTH arm emits that prefix too,
# which is exactly how the one EOF test we already owned managed to look like
# chunked coverage without being any.
comptime _CHUNKED_EOF = "chunked body unterminated"

# Go's `net/http/internal` fixture (issue 48861), with our grammar's final
# CRLF appended. The middle chunk is the interesting one: its 5 declared data
# bytes are "abc\r\n" — the CRLF is INSIDE the payload, so a decoder that
# scans for CRLF instead of counting declared bytes mis-frames here and a
# prefix sweep catches it.
comptime _WIRE_GO = "4\r\nabcd\r\n5\r\nabc\r\n\r\n0\r\n\r\n"
comptime _PAYLOAD_GO = "abcdabc\r\n"

# Two plain chunks, last-chunk, final CRLF.
comptime _WIRE_TWO = "3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n"
comptime _PAYLOAD_TWO = "foobar"

# One 0x10-byte chunk and a NON-EMPTY trailer section. Truncation anywhere in
# the trailers must still be INCOMPLETE — the trailer section and the CRLF
# that closes it are part of the message, not an optional postscript.
comptime _WIRE_TRAILER = "10\r\n0123456789abcdef\r\n0\r\nX-T: v\r\n\r\n"
comptime _PAYLOAD_TRAILER = "0123456789abcdef"


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _prefix_bytes(s: String, upto: Int) -> List[UInt8]:
    """The first `upto` bytes of `s`. Truncating the ScriptedStream read
    script IS an EOF at that offset — the mock returns Eof as soon as the
    cursor reaches the end of the script."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < upto and i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _bytes_eq(buf: List[UInt8], s: String) -> Bool:
    var b = s.as_bytes()
    if buf.__len__() != len(b):
        return False
    var i = 0
    while i < buf.__len__():
        if buf[i] != b[i]:
            return False
        i = i + 1
    return True


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _drain(
    mut body: RecvRingBody[ScriptedStream],
    mut reactor: Reactor[NoopSink],
    ref tok: CancellationToken,
    mut out: List[UInt8],
) raises -> String:
    """Drive poll_frame to End, concatenating Data frames into `out`.
    Returns "" on a clean End, or the Error frame's detail string.

    Never raises on a body-level error: the DETAIL is the subject of every
    assertion in this file, so it has to survive as a value. `ITER_CAP` is
    returned rather than looping forever — a decoder that can make no
    progress but keeps answering Pending is the OTHER half of the failure,
    and a hang is not a test result."""
    var iter = 0
    while True:
        iter = iter + 1
        if iter > 200000:
            return String("ITER_CAP")
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        if f.is_end():
            return String("")
        if f.is_error():
            return f.error_detail()
        if f.is_data():
            var chunk = f.take_data_chunk()
            var k = 0
            while k < chunk.__len__():
                out.append(chunk[k])
                k = k + 1
    return String("")


def _sweep_every_proper_prefix(wire: String, label: String) raises:
    """THE GO 48861 SWEEP. For every proper prefix wire[:i], i in
    [0, len(wire)), the body must report the CHUNKED truncation error.

    A prefix that decodes some complete chunks legitimately yields Data
    frames first — that is asserted separately by
    `test_partial_chunk_data_is_delivered_before_the_error`. What may NEVER
    happen at any i < len(wire) is a clean End, because a clean End over a
    truncated body is SILENT DATA LOSS: the caller gets a short body and no
    indication that it is short."""
    var full = _make_bytes(wire)
    var n = full.__len__()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var i = 0
    while i < n:
        var stream = ScriptedStream.from_read_script(_prefix_bytes(wire, i))
        var body = RecvRingBody[ScriptedStream].new_chunked(
            stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
        )
        var got = List[UInt8]()
        var detail = _drain(body, reactor, tok, got)
        assert_true(
            detail.find(String(_CHUNKED_EOF)) >= 0,
            label
            + String(" prefix i=")
            + String(i)
            + String(" of ")
            + String(n)
            + String(": expected the CHUNKED truncation error, got detail=<")
            + detail
            + String(">"),
        )
        i = i + 1


# =============================================================================
# Case 1 — Go TestIncompleteChunk (golang/go#48861), ported.
# =============================================================================


def test_incomplete_chunk_every_prefix_go_48861() raises:
    _sweep_every_proper_prefix(String(_WIRE_GO), String("go48861"))


def test_complete_go_48861_wire_yields_payload_then_end() raises:
    """The other half of Go's test, and the one that keeps the sweep honest:
    the UNTRUNCATED wire must decode cleanly and deliver every byte. A
    decoder that reported truncation unconditionally would pass the sweep."""
    var stream = ScriptedStream.from_read_script(_make_bytes(String(_WIRE_GO)))
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_equal(detail, String(""), String("complete wire must drain clean"))
    assert_true(
        _bytes_eq(got, String(_PAYLOAD_GO)),
        String("complete wire payload mismatch, got len=")
        + String(got.__len__()),
    )


# =============================================================================
# Case 2 — two chunks, last-chunk, final CRLF.
# =============================================================================


def test_incomplete_chunk_every_prefix_two_chunks() raises:
    _sweep_every_proper_prefix(String(_WIRE_TWO), String("twochunk"))


def test_complete_two_chunk_wire_yields_payload_then_end() raises:
    var stream = ScriptedStream.from_read_script(_make_bytes(String(_WIRE_TWO)))
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_equal(detail, String(""))
    assert_true(_bytes_eq(got, String(_PAYLOAD_TWO)))


# =============================================================================
# Case 3 — truncation INSIDE a trailer section is still incomplete.
# =============================================================================


def test_incomplete_chunk_every_prefix_with_trailers() raises:
    """⚠ THE TRAILER SECTION IS PART OF THE MESSAGE. A wire cut after
    "0\\r\\n" but partway through "X-T: v\\r\\n\\r\\n" has delivered every
    body byte, which makes "just call it done" look free. It is not: the
    trailers may carry `grpc-status`, a checksum, or a signature, and a peer
    that cut us off there also cut off whatever it was about to say about the
    bytes we did get."""
    _sweep_every_proper_prefix(String(_WIRE_TRAILER), String("trailer"))


def test_complete_trailer_wire_yields_payload_then_end() raises:
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String(_WIRE_TRAILER))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_equal(detail, String(""))
    assert_true(_bytes_eq(got, String(_PAYLOAD_TRAILER)))


# =============================================================================
# Case 4 — EOF after "0\r\n" but BEFORE the terminating CRLF.
# =============================================================================


def test_eof_after_last_chunk_line_before_final_crlf_is_incomplete() raises:
    """RFC 9112 §7.1: `chunked-body = *chunk last-chunk trailer-section CRLF`.
    The final CRLF is part of the grammar, so a stream that ends at the
    last-chunk line has NOT delivered a complete message even though it has
    delivered every body byte.

    ⛔ THE REASON THIS IS PINNED SEPARATELY RATHER THAN LEFT TO THE SWEEP.
    This is the one offset where returning End is both WRONG and INVISIBLE:
    the payload is already complete, so no caller would notice, and a decoder
    "helpfully" accepting it cannot then tell a clean close from a peer that
    died between the zero chunk and its trailers."""
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String("4\r\nabcd\r\n0\r\n"))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_true(
        detail.find(String(_CHUNKED_EOF)) >= 0,
        String("EOF after '0\\r\\n' must be INCOMPLETE, got detail=<")
        + detail
        + String(">"),
    )
    # The body bytes that DID arrive are still delivered — losing them on the
    # error path would be a second, quieter bug.
    assert_true(
        _bytes_eq(got, String("abcd")),
        String("bytes decoded before the truncation must still be delivered"),
    )


# =============================================================================
# Case 5 — End is idempotent (hyper: test_read_chunked_after_eof).
# =============================================================================


def test_end_is_idempotent_after_complete_body() raises:
    """A caller that polls once more after End must get End again — not an
    error, not a wire read, and above all not a hang. This is where decoders
    loop: `_done` is the only thing standing between a post-End poll and the
    read path, which on a closed socket answers Eof and re-enters
    `_finalize_on_eof` forever."""
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String("3\r\nfoo\r\n0\r\n\r\n"))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_equal(detail, String(""))
    assert_true(_bytes_eq(got, String("foo")))
    # Three more polls past End. Every one must be End.
    var k = 0
    while k < 3:
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        assert_true(
            f.is_end(),
            String("poll #") + String(k + 1) + String(" after End was not End"),
        )
        k = k + 1


def test_end_is_idempotent_after_empty_chunked_body() raises:
    """Same contract with zero body bytes — the "0\\r\\n\\r\\n"-only wire,
    where the FIRST frame the caller ever sees is End."""
    var stream = ScriptedStream.from_read_script(_make_bytes(String("0\r\n\r\n")))
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var k = 0
    while k < 4:
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        assert_true(
            f.is_end(),
            String("poll #") + String(k + 1) + String(" was not End"),
        )
        k = k + 1


# =============================================================================
# Case 6 — partial chunk DATA is delivered before the error.
# =============================================================================


def test_partial_chunk_data_is_delivered_before_the_error() raises:
    """"9\\r\\nfoo bar" declares 9 bytes and delivers 7. Those 7 bytes MUST
    reach the caller as a Data frame BEFORE the truncation error.

    `_finalize_on_eof` does emit `_accum` first, but nothing tested it, so a
    refactor that dropped accumulated bytes on the error path would be
    SILENT: the caller raises either way, and the only difference is whether
    a retry-after-partial or a streaming consumer saw the bytes it had
    already been handed."""
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String("9\r\nfoo bar"))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_true(
        detail.find(String(_CHUNKED_EOF)) >= 0,
        String("7-of-9 chunk must report truncation, got detail=<")
        + detail
        + String(">"),
    )
    assert_true(
        _bytes_eq(got, String("foo bar")),
        String("the 7 delivered bytes must reach the caller first, got len=")
        + String(got.__len__()),
    )


def test_partial_chunk_data_from_pre_body_is_delivered_before_the_error() raises:
    """Same contract across the HEAD-parse handoff seam: bytes that arrived
    in `pre_body_bytes` are decoded in the constructor, so the Data frame is
    produced with no wire read at all."""
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^,
        pre_body_bytes=_make_bytes(String("9\r\nfoo bar")),
        max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_true(detail.find(String(_CHUNKED_EOF)) >= 0, detail)
    assert_true(_bytes_eq(got, String("foo bar")))


# =============================================================================
# Case 8 — a transport I/O error is NOT reclassified as truncation.
# =============================================================================


def test_io_error_mid_chunk_is_not_reclassified_as_truncation() raises:
    """⛔ TWO DIFFERENT SYSTEMS TO GO LOOK AT. "the peer closed cleanly
    mid-body" and "the socket returned ECONNRESET" have different causes,
    different retry semantics and different owners, and a decoder that folds
    the second into the first sends the reader to the wrong one — which is
    the generic failure these tests exist to stop. Go asserts the
    sentinel error by VALUE in TestChunkEndReadError for the same reason.

    The armed error fires on the first `try_read`, so the partial body is
    seeded through `pre_body_bytes`: `poll_frame` emits the accumulated Data
    frame, then takes the STREAM_IO_ERROR arm on the following poll."""
    var stream = ScriptedStream.empty()
    stream.arm_error(Int64(104))  # ECONNRESET
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^,
        pre_body_bytes=_make_bytes(String("9\r\nfoo bar")),
        max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_true(
        detail.find(String("IO_ERROR")) >= 0,
        String("a transport error must surface as IO_ERROR, got detail=<")
        + detail
        + String(">"),
    )
    assert_true(
        detail.find(String("104")) >= 0,
        String("the IO_ERROR detail must name the errno, got detail=<")
        + detail
        + String(">"),
    )
    assert_true(
        detail.find(String(_CHUNKED_EOF)) < 0,
        String("a transport error must NOT be reported as truncation, got: ")
        + detail,
    )
    assert_true(
        _bytes_eq(got, String("foo bar")),
        String("bytes decoded before the I/O error must still be delivered"),
    )


# =============================================================================
# Case 11 — the truncation error must name the DECODE POSITION.
# =============================================================================


def test_truncation_error_names_the_decode_position() raises:
    """★ PROPOSAL (no reference suite states this; it is what a reader of
    the logs needs and otherwise does not get).

    The observed line was, in its entirety:

        HttpError[EOF_MID_RESPONSE: chunked body unterminated]

    That sentence is true of a wire cut at byte 0 and of one cut one byte
    before the final CRLF, and those are completely different incidents: the
    first is "the peer never answered", the second is "the peer answered and
    the connection died at the very end". Without the position, a hundred
    occurrences cannot be told apart.

    A truncation error must therefore carry the decoder's POSITION — how
    much it decoded, what token it was mid-way through, and how many bytes it
    was holding undecodable — so one log line distinguishes them.

    The numbers are pinned, not just the field names: a message that prints
    `decoded=0` for a body that delivered 7 bytes is worse than no message."""
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String("9\r\nfoo bar"))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_true(
        detail.find(String("decoded=7")) >= 0,
        String("truncation detail must name bytes decoded (decoded=7), got: ")
        + detail,
    )
    assert_true(
        detail.find(String("state=")) >= 0,
        String("truncation detail must name the decoder state, got: ")
        + detail,
    )
    assert_true(
        detail.find(String("chunk_remaining=2")) >= 0,
        String(
            "truncation detail must name how much of the current chunk was"
            " still owed (chunk_remaining=2), got: "
        )
        + detail,
    )


def test_truncation_error_position_distinguishes_byte_zero_from_the_end() raises:
    """The whole point of the position: two truncations of the SAME wire, at
    the extremes, must not produce the same sentence. Byte 0 is "the peer
    said nothing"; one byte short of the end is "the peer said everything and
    then died"."""
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var s_empty = ScriptedStream.from_read_script(List[UInt8]())
    var b_empty = RecvRingBody[ScriptedStream].new_chunked(
        s_empty^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var got_a = List[UInt8]()
    var detail_a = _drain(b_empty, reactor, tok, got_a)

    var full = String(_WIRE_TWO)
    var s_near = ScriptedStream.from_read_script(
        _prefix_bytes(full, _make_bytes(full).__len__() - 1)
    )
    var b_near = RecvRingBody[ScriptedStream].new_chunked(
        s_near^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var got_b = List[UInt8]()
    var detail_b = _drain(b_near, reactor, tok, got_b)

    assert_true(detail_a.find(String(_CHUNKED_EOF)) >= 0, detail_a)
    assert_true(detail_b.find(String(_CHUNKED_EOF)) >= 0, detail_b)
    assert_true(
        detail_a != detail_b,
        String(
            "a wire cut at byte 0 and one cut one byte from the end must not"
            " produce the same error sentence; both were: "
        )
        + detail_a,
    )


def main() raises:
    test_incomplete_chunk_every_prefix_go_48861()
    test_complete_go_48861_wire_yields_payload_then_end()
    test_incomplete_chunk_every_prefix_two_chunks()
    test_complete_two_chunk_wire_yields_payload_then_end()
    test_incomplete_chunk_every_prefix_with_trailers()
    test_complete_trailer_wire_yields_payload_then_end()
    test_eof_after_last_chunk_line_before_final_crlf_is_incomplete()
    test_end_is_idempotent_after_complete_body()
    test_end_is_idempotent_after_empty_chunked_body()
    test_partial_chunk_data_is_delivered_before_the_error()
    test_partial_chunk_data_from_pre_body_is_delivered_before_the_error()
    test_io_error_mid_chunk_is_not_reclassified_as_truncation()
    test_truncation_error_names_the_decode_position()
    test_truncation_error_position_distinguishes_byte_zero_from_the_end()
    print("PASS recv-ring chunked truncation tests")
