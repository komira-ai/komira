# =============================================================================
# src/komira_http_client/tests/test_L2_special_status_framing.mojo
# =============================================================================
# RFC 9112 §6.3(1) — the rung of the message-body-length ladder that is
# decided by the STATUS CODE and the REQUEST METHOD, before any header is
# consulted:
#
#   "Any response to a HEAD request and any response with a 1xx, 204, or
#    304 status code is always terminated by the first empty line after
#    the header fields, regardless of the header fields present in the
#    message, and thus cannot contain a message body or trailer section."
#
# Package coverage before this file: `test_no_body_204_no_content` (a 204
# with NO framing headers at all — the case that needs no rule) and
# `test_head_response_no_body.mojo` (the HEAD half). Nothing covered 304,
# 101, any 1xx-before-the-final-response, or a special status carrying a
# framing header that has to be IGNORED — which is the whole point of the
# rung.
#
# ⭐ WHY THESE ARE THE HIGH-VALUE CASES, AND NOT PEDANTRY. Getting this
# rung wrong does not fail the request in front of you. It leaves bytes on
# a POOLED connection that the NEXT exchange reads as its own status line
# — a corruption that surfaces minutes later, on an unrelated request, as
# a parse error or a body that never terminates (`EOF_MID_RESPONSE:
# chunked body unterminated`). Go carries a named regression test for exactly one of
# these (TestNoBodyOnChunked304Response) for exactly that reason.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.header_map import HeaderMap
from komira_http_client.request_writer import (
    method_get,
    serialize_request_head,
)
from komira_http_client.response_body import RecvRingBody, collect_body
from komira_http_client.state_machine import (
    ClientResponse,
    OUTBOUND_STATE_DONE,
    OutboundDriver,
)
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedStream


# `RecvRingBody._framing` discriminators, restated so an assertion can name
# the framing the driver CHOSE rather than only its observable output. Kept
# in lockstep with `client/response_body.mojo` §_BODY_FRAMING_*; a silent
# renumbering there fails these tests, which is the intent.
comptime FRAMING_CHUNKED: UInt8 = 0
comptime FRAMING_CONTENT_LENGTH: UInt8 = 1
comptime FRAMING_EMPTY: UInt8 = 2
comptime FRAMING_READ_UNTIL_EOF: UInt8 = 3


# -----------------------------------------------------------------------------
# helpers — same shape as test_state_machine.mojo's
# -----------------------------------------------------------------------------


def _make_scratch() -> List[UInt8]:
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _bytes_to_str(buf: List[UInt8]) -> String:
    var out = String()
    var i = 0
    while i < buf.__len__():
        out = out + chr(Int(buf[i]))
        i = i + 1
    return out^


def _make_get_request_bytes() raises -> List[UInt8]:
    var url = Url.parse(String("http://example.com/health"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    return out^


def _take_body_bytes(
    mut resp: ClientResponse[RecvRingBody[ScriptedStream]],
) raises -> List[UInt8]:
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    return collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        resp.body, reactor, tok,
    )


def _drive(
    var stream: ScriptedStream, is_head: Bool,
) raises -> ClientResponse[RecvRingBody[ScriptedStream]]:
    """Run one full request/response over `stream` and return the
    response with its body UNDRAINED (the caller decides)."""
    var req_bytes = _make_get_request_bytes()
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_is_head_request(is_head)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)
    return resp^


def _drive_script(
    script: String, is_head: Bool = False,
) raises -> ClientResponse[RecvRingBody[ScriptedStream]]:
    var stream = ScriptedStream.from_read_script(_b(script))
    return _drive(stream^, is_head)


# =============================================================================
# §1 — 304 Not Modified. The rung's headline case.
# =============================================================================


def test_304_with_content_length_has_no_body() raises:
    """`304` + `Content-Length: 880`. The CL describes the entity the
    client already has cached; there are ZERO body bytes on the wire.

    A client that honours the CL blocks waiting for 880 bytes that will
    never arrive — on a real socket, until the idle timeout.
    """
    var resp = _drive_script(String(
        "HTTP/1.1 304 Not Modified\r\n"
        "ETag: \"abc\"\r\n"
        "Content-Length: 880\r\n"
        "\r\n"
    ))
    assert_equal(Int(resp.status), 304)
    assert_equal(
        resp.body.framing(), FRAMING_EMPTY,
        "304 must select empty framing regardless of Content-Length",
    )
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)
    # The CL header itself stays readable — it is metadata about the
    # cached entity, not a claim about this message's body.
    var cl = resp.headers.get(String("content-length"))
    assert_true(cl.__bool__())
    assert_equal(cl.value(), String("880"))


def test_304_with_transfer_encoding_chunked_has_no_body() raises:
    """★ Go's TestNoBodyOnChunked304Response, ported.

    A 304 carrying `Transfer-Encoding: chunked` is a server bug, and it is
    a server bug that occurs. The rung says the message ends at the blank
    line, so the `0\\r\\n\\r\\n` that follows is NOT this message's body —
    it is the first bytes of whatever comes next on that connection.

    Running the chunked decoder over it is how the terminator gets eaten
    and the connection looks clean when it is not; Go's named test exists
    because this left a pooled connection poisoned.
    """
    var resp = _drive_script(String(
        "HTTP/1.1 304 Not Modified\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "0\r\n\r\n"
    ))
    assert_equal(Int(resp.status), 304)
    assert_false(
        resp.body.framing() == FRAMING_CHUNKED,
        "304 must not select chunked framing (Go TestNoBodyOnChunked304Response)",
    )
    assert_equal(resp.body.framing(), FRAMING_EMPTY)
    var body = _take_body_bytes(resp)
    assert_equal(
        body.__len__(), 0, "a 304 cannot contain a message body",
    )


# =============================================================================
# §2 — 204 No Content, with framing headers that must be ignored.
# =============================================================================


def test_204_with_content_length_five_has_no_body() raises:
    """The existing `test_no_body_204_no_content` uses a 204 with NO
    framing headers — the case the rung does not have to decide. This is
    the one it does."""
    var resp = _drive_script(String(
        "HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n"
    ))
    assert_equal(Int(resp.status), 204)
    assert_equal(resp.body.framing(), FRAMING_EMPTY)
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)


def test_204_with_chunked_has_no_body() raises:
    var resp = _drive_script(String(
        "HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    ))
    assert_equal(Int(resp.status), 204)
    assert_equal(resp.body.framing(), FRAMING_EMPTY)
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)


# =============================================================================
# §3 — 101 Switching Protocols. A 1xx, and the one that ends H/1.1 framing.
# =============================================================================


def test_101_with_content_length_has_no_body() raises:
    """After a 101 the connection stops being an HTTP/1.1 message stream —
    the bytes that follow belong to the upgraded protocol. Reading them as
    a body (or later, as a pooled connection's next response) is a
    protocol confusion."""
    var resp = _drive_script(String(
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
    ))
    assert_equal(Int(resp.status), 101)
    assert_equal(resp.body.framing(), FRAMING_EMPTY)
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)


def test_101_with_transfer_encoding_has_no_body() raises:
    var resp = _drive_script(String(
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: h2c\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
    ))
    assert_equal(Int(resp.status), 101)
    assert_equal(resp.body.framing(), FRAMING_EMPTY)
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)


# =============================================================================
# §4 — ★ 1xx BEFORE the final response. The highest-value case in the file.
# =============================================================================
# RFC 9110 §15.2, verbatim: "A client MUST be able to parse one or more 1xx
# responses received prior to a final response, even if the client does not
# expect one." An interim response does not TERMINATE the exchange; the
# next message on the connection is the real one.
#
# This is not hypothetical traffic. `103 Early Hints` (RFC 8297) is emitted
# by Google's GFE and by Cloud Run, unsolicited, on ordinary GETs. An
# unsolicited `100 Continue` is emitted by several origin servers
# that do not wait for an `Expect: 100-continue` at all (RFC 9110 §10.1.1
# explicitly permits it).


def test_unsolicited_100_continue_is_not_the_final_response() raises:
    """★ The exchange must complete with the 200, not the 100.

    ⚠ FAILS ON CURRENT CODE. `OutboundDriver` skips a 1xx in exactly ONE
    place — the `OUTBOUND_STATE_WAITING_FOR_CONTINUE` arm of
    `run_with_body`, reached only when the caller passed
    `expect_continue=True`, and even there only for status EXACTLY 100.
    The `OUTBOUND_STATE_READING_RESPONSE_HEAD` arm that every ordinary
    GET/POST goes through has no 1xx handling at all, so the first head it
    parses is returned as THE response.

    Two consequences, and the second is the dangerous one:
      1. the caller gets status 100 and an empty body where it expected
         200 and a payload;
      2. the real response's bytes are in the driver's recv_buf past
         `_headers_end_off`, and the 1xx path routes to
         `RecvRingBody.new_empty(stream)` — which takes no pre-body bytes —
         so they are DROPPED. The connection then looks idle and clean,
         is returned to the pool, and the next request on it reads the
         TAIL of a response nobody consumed.
    """
    var resp = _drive_script(String(
        "HTTP/1.1 100 Continue\r\n"
        "\r\n"
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 2\r\n"
        "\r\n"
        "hi"
    ))
    assert_equal(
        Int(resp.status), 200,
        "RFC 9110 15.2: a 1xx does not terminate the exchange",
    )
    var body = _take_body_bytes(resp)
    assert_equal(_bytes_to_str(body), String("hi"))


def test_103_early_hints_is_not_the_final_response() raises:
    """★ Same rule, with the interim status that real infrastructure
    actually sends. Google's GFE and Cloud Run emit `103 Early Hints`
    unsolicited on ordinary GETs.

    ⚠ FAILS ON CURRENT CODE — same root cause as the 100 case, and note
    that the `expect_continue` arm would not save this one either: it
    special-cases `status == 100` and treats anything else as final.
    """
    var resp = _drive_script(String(
        "HTTP/1.1 103 Early Hints\r\n"
        "Link: </style.css>; rel=preload; as=style\r\n"
        "\r\n"
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 4\r\n"
        "\r\n"
        "done"
    ))
    assert_equal(
        Int(resp.status), 200,
        "RFC 8297 / RFC 9110 15.2: 103 is interim, not the final response",
    )
    var body = _take_body_bytes(resp)
    assert_equal(_bytes_to_str(body), String("done"))


def test_two_consecutive_1xx_then_the_final_response() raises:
    """★ 'one or MORE 1xx responses' — a client that skips exactly one
    interim response is still wrong. GFE emits 103 more than once when it
    learns of additional preloads.

    ⚠ FAILS ON CURRENT CODE.
    """
    var resp = _drive_script(String(
        "HTTP/1.1 103 Early Hints\r\n"
        "Link: </a.css>; rel=preload\r\n"
        "\r\n"
        "HTTP/1.1 103 Early Hints\r\n"
        "Link: </b.js>; rel=preload\r\n"
        "\r\n"
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 3\r\n"
        "\r\n"
        "end"
    ))
    assert_equal(Int(resp.status), 200)
    var body = _take_body_bytes(resp)
    assert_equal(_bytes_to_str(body), String("end"))


# =============================================================================
# §5 — HEAD framing.
# =============================================================================


def test_head_with_chunked_reads_zero_body() raises:
    """A HEAD response may carry `Transfer-Encoding: chunked` for the same
    reason it may carry a Content-Length: it describes the GET. No chunk
    decoding may be attempted."""
    var resp = _drive_script(
        String(
            "HTTP/1.1 200 OK\r\n"
            "Transfer-Encoding: chunked\r\n"
            "Connection: keep-alive\r\n"
            "\r\n"
        ),
        True,
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(
        resp.body.framing(), FRAMING_EMPTY,
        "HEAD must not select chunked framing",
    )
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)


def test_head_with_content_length_selects_empty_framing() raises:
    """The framing DECISION, not only its observable output. The existing
    `test_head_response_no_body.mojo` asserts `bytes_remaining() == 0`,
    which a CL-framed body that happens to be drained also satisfies."""
    var resp = _drive_script(
        String("HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n"), True,
    )
    assert_equal(resp.body.framing(), FRAMING_EMPTY)
    var body = _take_body_bytes(resp)
    assert_equal(body.__len__(), 0)


def test_head_without_the_flag_is_the_silent_hang_shape() raises:
    """PINNED FAILURE MODE, not a bug report. `set_is_head_request` is a
    CALLER obligation the type system does not enforce: the driver is
    handed pre-serialized request bytes and cannot see the method.

    Forgetting it on a HEAD whose response says `Content-Length: 5` makes
    the driver wait for 5 bytes that the server will never send. Against a
    ScriptedStream that surfaces as EOF_MID_RESPONSE; against a real
    socket it is a hang until the request deadline — which is why it is
    worth a test that says so out loud.
    """
    var stream = ScriptedStream.from_read_script(
        _b(String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"))
    )
    var caught = False
    try:
        var resp = _drive(stream^, False)  # the flag deliberately NOT set
        assert_equal(resp.body.framing(), FRAMING_CONTENT_LENGTH)
        var _body = _take_body_bytes(resp)
    except _e:
        caught = True
    assert_true(
        caught,
        "an unflagged HEAD with CL>0 waits for bytes that never arrive",
    )


# =============================================================================
# §6 — ★ Residue: bytes of the NEXT response that arrive with this one.
# =============================================================================
# RFC 9112 §6.3, final paragraph, is about the close-delimited case; the
# keep-alive case is the sharper one. Bytes of response N+1 routinely
# arrive in the same read() as response N's body — one TCP segment, two
# messages — and a client that reuses the connection MUST still be able to
# parse N+1 afterwards.
#
# This package DOES reuse h1 connections (see
# `test_http_client_h1_keepalive_reuse.mojo`), so this is a live path.


def test_pipelined_residue_survives_a_content_length_body() raises:
    """★ Response N is CL-framed; response N+1's bytes arrive in the same
    read. After draining N, N+1 must still be parseable.

    ⚠ FAILS ON CURRENT CODE. `OutboundDriver._extract_pre_body_bytes`
    hands EVERYTHING past `headers_end_off` to the body conformer, and
    `RecvRingBody.new_content_length` then seeds only the first
    `cl_total` of them:

        var to_take = n_pre
        if to_take > cl_total: to_take = cl_total

    The remainder — response N+1 — is silently discarded. It is not left
    on the socket either: it was already read off the wire. So the
    connection is handed back to the pool looking clean, and the next
    exchange on it reads whatever came AFTER the response nobody
    consumed.
    """
    var stream = ScriptedStream.from_read_script(_b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
        "hello"
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 6\r\n"
        "\r\n"
        "second"
    )))
    var resp1 = _drive(stream^, False)
    assert_equal(Int(resp1.status), 200)
    var body1 = _take_body_bytes(resp1)
    assert_equal(_bytes_to_str(body1), String("hello"))

    # Reuse the connection, exactly as the h1 keepalive path does.
    var reused = resp1.body.take_stream()
    var resp2 = _drive(reused^, False)
    assert_equal(
        Int(resp2.status), 200,
        "response N+1 must survive arriving in the same read as N's body",
    )
    var body2 = _take_body_bytes(resp2)
    assert_equal(_bytes_to_str(body2), String("second"))


def test_residue_survives_an_empty_status_response() raises:
    """★ The same defect through the OTHER branch, and the one that fires
    on CONFORMANT traffic.

    A 304 (or any 1xx / 204) routes to `RecvRingBody.new_empty(stream)`,
    which takes no `pre_body_bytes` argument at all — so the computed
    pre-body list is simply dropped on the floor. Any byte of the next
    response that arrived with this head is destroyed.

    ⚠ FAILS ON CURRENT CODE.
    """
    var stream = ScriptedStream.from_read_script(_b(String(
        "HTTP/1.1 304 Not Modified\r\n"
        "ETag: \"v1\"\r\n"
        "\r\n"
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
        "after"
    )))
    var resp1 = _drive(stream^, False)
    assert_equal(Int(resp1.status), 304)
    var body1 = _take_body_bytes(resp1)
    assert_equal(body1.__len__(), 0)

    var reused = resp1.body.take_stream()
    var resp2 = _drive(reused^, False)
    assert_equal(
        Int(resp2.status), 200,
        "a 304's empty body must not consume the next response's bytes",
    )
    var body2 = _take_body_bytes(resp2)
    assert_equal(_bytes_to_str(body2), String("after"))


def test_keepalive_reuse_works_when_responses_arrive_separately() raises:
    """CONTROL for the two tests above. Same two responses, but the
    second is not yet on the wire when the first head is read — the
    ScriptedStream clamp forces the split.

    If this control also fails, the two residue tests above are measuring
    the harness rather than the defect.
    """
    var stream = ScriptedStream.from_read_script(_b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
        "hello"
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 6\r\n"
        "\r\n"
        "second"
    )))
    # Serve at most one byte per read: the head parse can never pull a
    # byte that belongs to the next response.
    stream.set_max_read_per_call(1)
    var resp1 = _drive(stream^, False)
    var body1 = _take_body_bytes(resp1)
    assert_equal(_bytes_to_str(body1), String("hello"))
    var reused = resp1.body.take_stream()
    var resp2 = _drive(reused^, False)
    assert_equal(Int(resp2.status), 200)
    var body2 = _take_body_bytes(resp2)
    assert_equal(_bytes_to_str(body2), String("second"))


def main() raises:
    test_304_with_content_length_has_no_body()
    test_304_with_transfer_encoding_chunked_has_no_body()
    test_204_with_content_length_five_has_no_body()
    test_204_with_chunked_has_no_body()
    test_101_with_content_length_has_no_body()
    test_101_with_transfer_encoding_has_no_body()
    test_head_with_chunked_reads_zero_body()
    test_head_with_content_length_selects_empty_framing()
    test_head_without_the_flag_is_the_silent_hang_shape()
    test_keepalive_reuse_works_when_responses_arrive_separately()
    # -------------------------------------------------------------------
    # ⚠ KNOWN-RED CONFORMANCE BLOCK — deliberately LAST.
    # -------------------------------------------------------------------
    # Two defects, five cases. Each docstring carries the repro and names
    # the code responsible. They sit at the END because `main` is
    # sequential (this package's idiom) and the first raise ends the
    # process — an unfixed red near the top would hide the ten passing
    # cases above it, including the CONTROL that proves the last two are
    # measuring the defect and not the harness.
    # ⛔ Do not weaken or delete them; the repair is in the driver.
    # -------------------------------------------------------------------
    test_unsolicited_100_continue_is_not_the_final_response()
    test_103_early_hints_is_not_the_final_response()
    test_two_consecutive_1xx_then_the_final_response()
    test_pipelined_residue_survives_a_content_length_body()
    test_residue_survives_an_empty_status_response()
    print("OK: test_L2_special_status_framing")
