# =============================================================================
# src/komira_http_client/tests/test_recv_ring_stops_at_message_boundary.mojo
# =============================================================================
# ⛔ A BODY READER MUST NOT CONSUME PAST ITS OWN MESSAGE BOUNDARY.
#
# This is the invariant h11 asserts on EVERY body-reader case
# (`t_body_reader`: after the terminal event, whatever followed the body is
# still there to be handed to the next reader) and that hyper's
# `Decoder::decode` holds by returning the unconsumed tail to the connection
# rather than swallowing it. It exists because of what `take_stream` on this
# very struct is FOR:
#
#     "The caller takes ownership of the stream and may close it (drop) OR
#      cache it for keepalive reuse."   — response_body.mojo
#
# A reader that over-consumes on a connection that is then CACHED does not
# fail at the point of the bug. It fails on the NEXT request over that
# connection, as an unexplained framing error against a response the peer
# sent correctly — which is why such a defect takes days to attribute.
#
# ⚠ WHY THIS IS A DELIVERY-SHAPE PROPERTY, NOT A PIPELINING CURIOSITY.
# `RecvRingBody.poll_frame` issues `try_read` into a `_scratch_size` buffer
# (64 KiB by default) and hands `scratch[:n]` to the decoder. Whether the
# read stops at the message boundary is decided by the KERNEL/TLS layer, not
# by this code: one `try_read` returns whatever bytes have arrived. So the
# same code is correct or incorrect depending only on how the peer's bytes
# happened to be delivered — the same class as the split-inside-a-framing-
# token defect, measured from the other end of the message.
#
# The sweep over `set_max_read_per_call(k)` IS the instrument: it walks the
# final read boundary across every offset, so the case where one read spans
# the terminator is reached at every k that does not divide the message
# length, instead of at one hand-picked arithmetic accident.
#
# No UnsafePointer crosses a boundary here; no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.response_body import RecvRingBody
from komira_http_client.state_machine import (
    OUTBOUND_STEP_HEAD_DONE,
    OUTBOUND_STEP_NOT_READY,
    OutboundDriver,
)
from komira_http_core.transport.scripted import ScriptedStream


# A complete chunked message: two chunks (one carrying a chunk-extension),
# the 0-length last chunk, and a non-empty trailer. 37 bytes.
comptime _MSG = "4\r\nAAAA\r\n6;e=v\r\nBBBBBB\r\n0\r\nX-T: v\r\n\r\n"
comptime _PAYLOAD = "AAAABBBBBB"

# What a KEPT-ALIVE connection carries next. Deliberately a response head:
# if the body reader eats it, the next `read_head` on the cached stream sees
# a truncated status line, and the failure is attributed to the peer.
comptime _NEXT = "HTTP/1.1 204 No Content\r\n\r\n"

# Test 4's message: a response that is ALL HEAD and no body. 27 bytes.
comptime _EMPTY_MSG = "HTTP/1.1 204 No Content\r\n\r\n"
comptime _EMPTY_FOLLOW = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
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
    Returns "" on a clean End, else the Error frame's detail."""
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


# =============================================================================
# Test 1 — CHUNKED. The bytes after the terminator belong to the connection.
# =============================================================================


def test_chunked_body_leaves_following_bytes_on_the_stream() raises:
    """After a chunked body reaches End, the stream's read cursor must sit
    exactly at the end of THAT message — the following response's bytes are
    not this body's to consume.

    Swept over every read size so the final read boundary lands both on and
    across the terminator. `read_cursor()` is the direct observation: it is
    the count of bytes the stream has handed out, so `cursor > len(_MSG)`
    means those bytes left the connection and, since `RecvRingBody` has no
    accessor for a decoded-past tail, are unrecoverable."""
    var msg_len = _make_bytes(String(_MSG)).__len__()
    var wire_len = msg_len + _make_bytes(String(_NEXT)).__len__()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var k = 1
    while k <= wire_len:
        var stream = ScriptedStream.from_read_script(
            _make_bytes(String(_MSG) + String(_NEXT))
        )
        stream.set_max_read_per_call(k)
        var body = RecvRingBody[ScriptedStream].new_chunked(
            stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
        )
        var got = List[UInt8]()
        var detail = _drain(body, reactor, tok, got)
        # Anti-vacuity, in-line: the cursor assertion below is only
        # meaningful over a drain that actually produced the right body.
        assert_equal(
            detail,
            String(""),
            String("read size k=") + String(k) + String(" drained with error"),
        )
        assert_true(
            _bytes_eq(got, String(_PAYLOAD)),
            String("read size k=") + String(k) + String(" wrong payload"),
        )
        var reclaimed = body.take_stream()
        assert_equal(
            reclaimed.read_cursor(),
            msg_len,
            String("read size k=")
            + String(k)
            + String(" consumed past the chunked message boundary"),
        )
        k = k + 1


# =============================================================================
# Test 2 — CONTENT-LENGTH. The same invariant on the other framing.
# =============================================================================


def test_content_length_body_leaves_following_bytes_on_the_stream() raises:
    """`_consume_scratch`'s CL arm copies at most `cl_total - cl_received`
    bytes out of the scratch and returns — the rest of that same read is not
    copied anywhere. The invariant is identical to Test 1's and is asserted
    separately because the two arms are separate code with separate
    clamping."""
    var payload = String("ABCDEFGHIJ")
    var cl = _make_bytes(payload).__len__()
    var wire_len = cl + _make_bytes(String(_NEXT)).__len__()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var k = 1
    while k <= wire_len:
        var stream = ScriptedStream.from_read_script(
            _make_bytes(payload + String(_NEXT))
        )
        stream.set_max_read_per_call(k)
        var body = RecvRingBody[ScriptedStream].new_content_length(
            stream^, cl_total=cl, pre_body_bytes=List[UInt8](),
            max_body_bytes=100 * 1024 * 1024,
        )
        var got = List[UInt8]()
        var detail = _drain(body, reactor, tok, got)
        assert_equal(
            detail,
            String(""),
            String("CL read size k=") + String(k) + String(" errored"),
        )
        assert_true(
            _bytes_eq(got, payload),
            String("CL read size k=") + String(k) + String(" wrong payload"),
        )
        var reclaimed = body.take_stream()
        assert_equal(
            reclaimed.read_cursor(),
            cl,
            String("CL read size k=")
            + String(k)
            + String(" consumed past the Content-Length boundary"),
        )
        k = k + 1


# =============================================================================
# Test 3 — the control: nothing follows, so nothing may be left over.
# =============================================================================


def test_exact_message_consumes_exactly_the_message() raises:
    """⚠ THE OTHER DIRECTION, and the reason Tests 1-2 cannot be satisfied by
    a reader that simply stops early. With NOTHING after the terminator, the
    cursor must reach the END of the wire: a reader that under-consumes
    (leaving the terminator's own bytes unread) would strand the connection
    just as surely as one that over-consumes, and would otherwise sail
    through the assertions above."""
    var msg_len = _make_bytes(String(_MSG)).__len__()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var k = 1
    while k <= msg_len:
        var stream = ScriptedStream.from_read_script(_make_bytes(String(_MSG)))
        stream.set_max_read_per_call(k)
        var body = RecvRingBody[ScriptedStream].new_chunked(
            stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
        )
        var got = List[UInt8]()
        var detail = _drain(body, reactor, tok, got)
        assert_equal(detail, String(""))
        assert_true(_bytes_eq(got, String(_PAYLOAD)))
        var reclaimed = body.take_stream()
        assert_equal(
            reclaimed.read_cursor(),
            msg_len,
            String("exact-message k=")
            + String(k)
            + String(" did not consume the whole message"),
        )
        k = k + 1


# =============================================================================
# Test 4 — THE EMPTY-BODY SEAM, and the one that is live for a client that
# never pipelines.
# =============================================================================


def _stepper_scratch() -> List[UInt8]:
    var out = List[UInt8]()
    var i = 0
    while i < 4096:
        out.append(UInt8(0))
        i = i + 1
    return out^


def test_empty_body_response_leaves_following_bytes_on_the_stream() raises:
    """⛔ A 204 / 304 / HEAD / CL=0 RESPONSE HAS NO BODY READ AT ALL, SO THE
    OVER-READ IS ENTIRELY THE **HEAD** PARSER'S — and it is the case most
    likely to happen, not the least. The head read is one 4 KiB+ `try_read`;
    a response that is 25 bytes of status line and header terminator cannot
    fill it, so whatever the peer put on the wire next arrives in the SAME
    read. `_extract_pre_body_bytes` hands those bytes to the body
    constructor, and the empty-body arm is the one arm that took no
    `pre_body_bytes` parameter to hand them to.

    ⚠ THIS ONE IS NOT LATENT BEHIND PIPELINING. Tests 1-2 need a peer that
    put a second response on the wire ahead of our drain. This needs only a
    peer that wrote the 204 and the next response into the same segment —
    and the h1 keepalive cache reclaims the connection between them, so the
    loss lands on the very next request the client itself makes.

    Driven through `OutboundDriver` rather than by constructing a
    `RecvRingBody` directly, on purpose: the defect is in the SEAM (which
    constructor the driver picks and what it passes), so a test that called
    the constructor itself would assert the fix and cover none of the
    wiring. The three `finish_into_response` / `run` / `run_with_body`
    sites all share this branch."""
    var msg_len = _make_bytes(String(_EMPTY_MSG)).__len__()
    var req_bytes = _make_bytes(
        String("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
    )
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String(_EMPTY_MSG) + String(_EMPTY_FOLLOW))
    )
    var driver = OutboundDriver.new(req_bytes^)
    driver.begin_send_head_nonblocking()

    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var scratch = _stepper_scratch()
    var step: UInt8 = OUTBOUND_STEP_NOT_READY
    var iters = 0
    while iters < 1000:
        iters = iters + 1
        step = driver.step_send_head_nonblocking[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](stream, reactor, Span[UInt8](scratch))
        if step != OUTBOUND_STEP_NOT_READY:
            break
    assert_equal(Int(step), Int(OUTBOUND_STEP_HEAD_DONE))

    var resp = driver.finish_into_response[ScriptedStream](stream^)
    assert_equal(Int(resp.status), 204)

    # Anti-vacuity: a 204 body is EMPTY, and the cursor assertion below is
    # only meaningful over a drain that produced no bytes and no error.
    var got = List[UInt8]()
    var detail = _drain(resp.body, reactor, tok, got)
    assert_equal(detail, String(""))
    assert_equal(got.__len__(), 0)

    var reclaimed = resp.body.take_stream()
    assert_equal(
        reclaimed.read_cursor(),
        msg_len,
        String(
            "the empty-body arm consumed past the 204's boundary — the next"
            " response was read off the connection and dropped"
        ),
    )


def main() raises:
    test_chunked_body_leaves_following_bytes_on_the_stream()
    test_content_length_body_leaves_following_bytes_on_the_stream()
    test_exact_message_consumes_exactly_the_message()
    test_empty_body_response_leaves_following_bytes_on_the_stream()
    print("PASS recv-ring message-boundary tests")
