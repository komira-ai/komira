# =============================================================================
# src/komira_http_client/tests/test_content_length_body_cap.mojo
#   HttpClientConfig.max_response_body_bytes reaches a Content-Length body.
# =============================================================================
#
# THE DEFECT. `RecvRingBody.new_content_length` took no cap, so the three
# `state_machine.mojo` sites that build a Content-Length body left it at the
# 100 MiB default, while the chunked and read-to-EOF constructors received the
# configured value. A caller that set `max_response_body_bytes` to bound its
# memory was bounded for chunked answers only; a Content-Length answer (what
# most servers send) was not.
#
# A SECOND HOLE behind the first. Even with the cap passed, the per-read guard
# in `poll_frame` never sees a body that arrived whole with the head: those
# bytes are seeded into `_accum` and emitted before any read. So the body is
# also refused by its DECLARED length, before any byte is delivered.
#
# WHAT EACH CASE CATCHES (the real HttpClient, driven by `send` through a
# ScriptedConnector; no socket):
#   (c1) cap 16, Content-Length 17, body inside the head read: the drain
#        raises BODY_TOO_LARGE. RED if the cap does not reach the body (it
#        keeps 100 MiB) or if only the per-read guard checks it (the body is
#        seeded and emitted without a read).
#   (c2) cap 16, Content-Length 16: all 16 bytes delivered. The other side of
#        the boundary; RED for an off-by-one or a cap applied as "< cap".
#   (c3) cap 1000, Content-Length 20000 (past the head read, so it also
#        needs wire reads): the FIRST frame is the error and zero bytes reach
#        the caller. RED if any prefix of an over-cap body is handed over.
#   (c4) the default config still delivers the same 20000-byte body: the
#        refusal comes from the configured cap, not from Content-Length
#        framing itself.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_get_request,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import collect_body
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime RT = PerCoreAsyncRuntime[NoopSink]


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _wire(body_len: Int) -> List[UInt8]:
    """`HTTP/1.1 200` with `Content-Length: body_len` and that many 'x'."""
    var head = String("HTTP/1.1 200 OK\r\nContent-Length: ") + String(
        body_len
    ) + "\r\n\r\n"
    var out = List[UInt8]()
    var hb = head.as_bytes()
    for i in range(len(hb)):
        out.append(hb[i])
    for _ in range(body_len):
        out.append(UInt8(ord("x")))
    return out^


def _client(
    max_body: Int, body_len: Int
) raises -> HttpClient[ScriptedConnector]:
    """A client whose config caps response bodies at `max_body` (0 = the
    defaults), scripted to answer with a `body_len`-byte Content-Length
    body."""
    var cfg = HttpClientConfig.defaults()
    if max_body > 0:
        cfg.max_response_body_bytes = max_body
    var stream = ScriptedStream.from_read_script(_wire(body_len))
    var connector = ScriptedConnector.with_stream(stream^)
    return HttpClient[ScriptedConnector](config=cfg, connector=connector^)


def _get_and_collect(
    max_body: Int, body_len: Int
) raises -> Tuple[Bool, Int, String]:
    """`send` a GET and `collect_body` the answer.
    Returns (raised, bytes delivered, error text)."""
    var client = _client(max_body, body_len)
    var reactor = _make_reactor()
    var hdrs = HeaderMap()
    var req = build_get_request(
        Url.parse(String("http://127.0.0.1:8080/object")), hdrs^
    )
    var resp = client.send[RT](req^, reactor)
    assert_equal(Int(resp.status), 200)
    var tok = CancellationToken.never()
    try:
        var bytes = collect_body[RT, ScriptedStream](resp.body, reactor, tok)
        return (False, len(bytes), String(""))
    except e:
        return (True, 0, String(e))


def test_c1_over_cap_body_inside_the_head_read_is_refused() raises:
    var out = _get_and_collect(16, 17)
    if not out[0]:
        raise Error(
            String("a 17-byte Content-Length body was delivered under a")
            + " 16-byte max_response_body_bytes ("
            + String(out[1])
            + " bytes): the configured cap was not applied to it"
        )
    assert_true(
        String("BODY_TOO_LARGE") in out[2],
        String("the refusal must name BODY_TOO_LARGE. got: ") + out[2],
    )


def test_c2_body_at_the_cap_is_delivered() raises:
    var out = _get_and_collect(16, 16)
    if out[0]:
        raise Error(
            String("a 16-byte body under a 16-byte cap was refused: ") + out[2]
        )
    assert_equal(out[1], 16, "all 16 bytes delivered")


def test_c3_over_cap_body_past_the_head_read_delivers_nothing() raises:
    var client = _client(1000, 20000)
    var reactor = _make_reactor()
    var hdrs = HeaderMap()
    var req = build_get_request(
        Url.parse(String("http://127.0.0.1:8080/object")), hdrs^
    )
    var resp = client.send[RT](req^, reactor)
    assert_equal(Int(resp.status), 200)
    var tok = CancellationToken.never()
    var delivered = 0
    var iters = 0
    while iters < 100_000:
        iters = iters + 1
        var f = resp.body.poll_frame[RT](reactor, tok)
        if f.is_error():
            assert_equal(
                f.error_detail(), String("BODY_TOO_LARGE"), "error detail"
            )
            assert_equal(delivered, 0, "no byte of an over-cap body delivered")
            return
        if f.is_end():
            break
        if f.is_data():
            delivered = delivered + len(f.take_data_chunk())
    raise Error(
        String("a 20000-byte Content-Length body under a 1000-byte cap")
        + " ended without BODY_TOO_LARGE after "
        + String(delivered)
        + " bytes"
    )


def test_c4_default_config_delivers_the_same_body() raises:
    var out = _get_and_collect(0, 20000)
    if out[0]:
        raise Error(
            String("the default 100 MiB cap refused a 20000-byte body: ")
            + out[2]
        )
    assert_equal(out[1], 20000, "all 20000 bytes delivered")


def main() raises:
    print("test_content_length_body_cap: the configured cap, Content-Length")
    var failures = List[String]()

    try:
        test_c1_over_cap_body_inside_the_head_read_is_refused()
        print("  PASS  (c1) over-cap body inside the head read is refused")
    except e:
        failures.append(String("c1: ") + String(e))
        print("  FAIL  (c1) over-cap body inside the head read is refused")

    try:
        test_c2_body_at_the_cap_is_delivered()
        print("  PASS  (c2) body at the cap is delivered")
    except e:
        failures.append(String("c2: ") + String(e))
        print("  FAIL  (c2) body at the cap is delivered")

    try:
        test_c3_over_cap_body_past_the_head_read_delivers_nothing()
        print("  PASS  (c3) over-cap body past the head read delivers nothing")
    except e:
        failures.append(String("c3: ") + String(e))
        print("  FAIL  (c3) over-cap body past the head read delivers nothing")

    try:
        test_c4_default_config_delivers_the_same_body()
        print("  PASS  (c4) default config delivers the same body")
    except e:
        failures.append(String("c4: ") + String(e))
        print("  FAIL  (c4) default config delivers the same body")

    if len(failures) > 0:
        var report = String("test_content_length_body_cap: ")
        report += String(len(failures)) + " case(s) FAILED\n"
        for i in range(len(failures)):
            report += String("\n---- ") + failures[i] + "\n"
        raise Error(report)
    print("test_content_length_body_cap: ALL PASS")
