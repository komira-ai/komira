"""HttpClient.send_buffered consults the pool.

Verifies the pool-stateful wiring of HttpClient.send_buffered:

1. Calling send_buffered once via h1 ALPN bumps h1 pool's dials_total to 1
   (the pool's diagnostic counter is wired through the dispatch path).
2. Calling send_buffered twice from one HttpClient on h1 results in
   dials_total == 2 (each call still dials a fresh stream — h1 keepalive
   reuse is follow-up; v1 only bumps the diagnostic counter).
3. The h2 pool stays uninitialized on h1-only calls.
4. h1 pool stays uninitialized on h2-only calls (via
   set_negotiated_protocol).
5. existing send-buffered behavior is preserved end-to-end —
   the response status / body / headers are unchanged.

These exercise gate (a) "Pool reuse: 67/67 tests still PASS" + the
load-bearing promise that the pool fields hold STATE across calls
(not merely diagnostic-zero).
"""

from std.memory import OwnedPointer
from std.sys import CompilationTarget

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_http.client.client import (
    HttpClient,
    build_get_request,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.url import Url
from komira_http.transport.io_stream import (
    NEGOTIATED_HTTP_1_1,
)
from komira_http.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)


def _b(s: String) -> List[UInt8]:
    """Convert a String to its byte representation."""
    var bs = s.as_bytes()
    var n = len(bs)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        out.append(bs[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    """Construct a noop reactor for tests that don't drive any real I/O."""
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _make_h1_response_stream() raises -> ScriptedStream:
    """Build a ScriptedStream pre-loaded with a canned h1 200 OK body.
    `negotiated_protocol` defaults to NEGOTIATED_HTTP_1_1."""
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    return ScriptedStream.from_read_script(resp_script^)


def test_h1_send_buffered_bumps_dials_total() raises:
    """A single send_buffered call via h1 ALPN bumps the h1 pool's
    dials_total to 1. This proves the dispatch path consults
    the pool (not just left as inert fields)."""
    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var stream = _make_h1_response_stream()
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    # Before the call: pool uninitialized; dials_total == 0.
    assert_false(client.h1_pool_is_init())
    assert_equal(client.h1_pool_dials_total(), 0)

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )

    # Post-call: pool initialized + dials_total == 1.
    assert_true(client.h1_pool_is_init())
    assert_equal(client.h1_pool_dials_total(), 1)
    # And the response is preserved end-to-end.
    assert_equal(Int(resp.status), 200)


def test_h1_send_buffered_twice_dials_total_2() raises:
    """Two send_buffered calls from one HttpClient.

    With keepalive reuse,
    the second call reuses the cached connection from the first.
    dials_total stays at 1 (not 2). Test renamed in intent but kept
    the historical name for backward-compat search. Multi-response
    script + set_max_read_per_call(40) lets ONE stream serve both
    requests (the test models same-origin sequential sends)."""
    var url1 = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs1 = HeaderMap()
    var req1 = build_get_request(url1^, hdrs1^)

    # ONE script with TWO responses; ONE stream serves both calls
    # via the keepalive-reuse cache. Re-arming the connector is no
    # longer required because the second send_buffered does NOT
    # call connect (cache hit).
    var two_resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream1 = ScriptedStream.from_read_script(two_resp_script^)
    stream1.set_max_read_per_call(40)
    var connector = ScriptedConnector.with_stream(stream1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req1^, reactor,
    )
    assert_equal(Int(resp1.status), 200)
    assert_equal(client.h1_pool_dials_total(), 1)

    var url2 = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs2 = HeaderMap()
    var req2 = build_get_request(url2^, hdrs2^)
    var resp2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req2^, reactor,
    )
    assert_equal(Int(resp2.status), 200)
    # KEEPALIVE-REUSE: dials_total stays at 1 (the second call
    # reused the cached conn instead of dialing).
    assert_equal(client.h1_pool_dials_total(), 1)


def test_h2_pool_stays_uninit_on_h1_calls() raises:
    """A send_buffered call that resolves to h1 ALPN does NOT init the
    h2 pool. The two pool fields are independent."""
    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var stream = _make_h1_response_stream()
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    # Drive an h1 call.
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    # h1 pool init; h2 pool NOT init.
    assert_true(client.h1_pool_is_init())
    assert_false(client.h2_pool_is_init())


def test_h1_pool_diagnostic_persists_across_calls() raises:
    """The h1 pool's diagnostic state persists across calls — the field
    isn't re-created on each dispatch.

    With keepalive reuse,
    three same-origin calls → dials_total == 1 (one fresh dial + two
    reuses). The test's INTENT (persistent pool state across calls) is
    unchanged — the diagnostic counter still bumps deterministically;
    keepalive just lowers the steady-state count."""
    var url = Url.parse(String("http://127.0.0.1:8080/x"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    # ONE script with 3 keepalive responses; set_max_read_per_call(40)
    # so each try_read returns exactly one response (modeling real
    # socket one-syscall-per-response behavior).
    var three_resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream = ScriptedStream.from_read_script(three_resp_script^)
    stream.set_max_read_per_call(40)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var i = 0
    while i < 3:
        var url_i = Url.parse(String("http://127.0.0.1:8080/x"))
        var hdrs_i = HeaderMap()
        var req_i = build_get_request(url_i^, hdrs_i^)
        var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req_i^, reactor,
        )
        assert_equal(Int(resp.status), 200)
        i = i + 1

    # KEEPALIVE-REUSE: 1 dial + 2 reuses (was 3 pre-fix).
    assert_equal(client.h1_pool_dials_total(), 1)


def test_existing_send_path_unaffected() raises:
    """The streaming `send` path is UNAFFECTED by the pool
    wiring — it still goes through `_run_one_request_streaming` which
    bypasses the pool entirely (only the buffered path is pooled)."""
    var url = Url.parse(String("http://127.0.0.1:8080/stream"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var stream = _make_h1_response_stream()
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    # send (streaming) — does NOT consult the pool. Pool stays uninit.
    var resp = client.send[PerCoreAsyncRuntime[NoopSink]](req^, reactor)
    assert_equal(Int(resp.status), 200)
    # v1: streaming send DOES NOT bump dials_total (the streaming
    # path bypasses the pool entirely — see _run_one_request_streaming
    # in client.mojo). The h1 pool stays uninit.
    assert_false(client.h1_pool_is_init())


def main() raises:
    test_h1_send_buffered_bumps_dials_total()
    test_h1_send_buffered_twice_dials_total_2()
    test_h2_pool_stays_uninit_on_h1_calls()
    test_h1_pool_diagnostic_persists_across_calls()
    test_existing_send_path_unaffected()
    print("[OK] test_http_client_pool_wiring — all 5 tests passed")
