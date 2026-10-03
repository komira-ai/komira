# =============================================================================
# src/komira_http_client/tests/test_http_client_call_pooled_keepalive.mojo
#   call_pooled keepalive regression tests.
# =============================================================================
#
# Verifies the architectural invariant of the broker write-path keepalive fix:
#
#   * The BUFFERED `call_pooled[RT, C2, B]` path (the keepalive-aware analog of
#     `call`, threading an EXPLICIT per-call connector — the broker / S3
#     write-path shape) CHECKS OUT an idle keepalive stream from the
#     per-HttpClient `_h1_idle_conn` cache instead of fresh-dialing. After a
#     keepalive-safe response (connection_close=False — the HTTP/1.1 default),
#     the underlying stream is stashed back; the NEXT same-origin `call_pooled`
#     extracts the cached stream and SKIPS the `connector.connect()` dial.
#
# Pre-fix shape: every `.call` (the path the broker took via
# `SigV4SignedTransport.call` -> `HttpClient.call` -> the free-fn
# `_run_one_request_buffered_with_dispatch`) dials a FRESH stream and DROPS it.
# For N successive ops to the same origin, `connect_call_count == N`. This is
# the per-produce S3-op dial latency that serializes on the single broker
# worker thread.
#
# Post-fix shape: after the first dial, the stream is cached; N-1 subsequent
# `call_pooled` ops REUSE it; `connect_call_count == 1`.
#
# Acceptance gate: tests 1-3 must FAIL pre-fix (1 compile-fails because
# `call_pooled` doesn't exist; once it exists, the dial-count assert FAILs
# against the non-pooled baseline) and PASS post-fix. Test 4 is the
# dead-conn validity guard (a stashed conn the server half-closed is NOT reused
# dead — it re-dials cleanly).
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.client import (
    HttpClient,
    build_get_request,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


comptime _SINGLE_RESPONSE_BYTES: Int = 40
"""Length of one canned HTTP/1.1 200 OK / CL=2 / "OK" keepalive response:
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK" = 40 bytes.
Same layout as the send_buffered keepalive-reuse test."""


def _script_n_keepalive_responses(n: Int) -> List[UInt8]:
    """Build a byte script of N back-to-back HTTP/1.1 200 OK keepalive
    responses (no Connection header -> HTTP/1.1 default keepalive). Callers
    cap `set_max_read_per_call(_SINGLE_RESPONSE_BYTES)` so each try_read
    returns exactly one response (models a real socket's per-syscall return;
    avoids the head-parser pre-body overrun on the multi-response script)."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var part = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
        var j = 0
        var m = part.__len__()
        while j < m:
            out.append(part[j])
            j = j + 1
        i = i + 1
    return out^


# =============================================================================
# Test 1 — N=10 successive call_pooled PUTs REUSE one conn (the headline gate).
# =============================================================================
#
# The broker write-path shape: N successive buffered ops on ONE per-worker
# client + connector (a single `_append_inner` does get/head/conditional_put
# on one store). Pre-fix (the broker took `.call`): 10 ops -> 10 connects.
# Post-fix (`call_pooled`): 10 ops -> 1 connect (the rest reuse the cached
# stream).


def test_n_pooled_puts_reuse_one_conn() raises:
    """N=10 successive `call_pooled` PUTs to the same origin issue exactly ONE
    connect (the fresh dial); the remaining 9 reuse the cached connection.

    HEADLINE ASSERTION: connector.connect_call_count() == 1 (not 10).

    This is the structural proof that the broker write-path keepalive collapses
    the per-op dial latency."""
    var script = _script_n_keepalive_responses(10)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    # The HttpClient's OWN connector is unused on the call_pooled path (it
    # threads the per-call connector); a distinct ScriptedConnector models that.
    var own_conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own_conn^)
    var reactor = _make_reactor()

    # Fresh client: nothing cached yet.
    assert_false(
        client.h1_idle_conn_is_cached(),
        "fresh client must not have an idle conn cached",
    )

    var i = 0
    while i < 10:
        var url = Url.parse(String("http://127.0.0.1:9000/bucket/key"))
        var hdrs = HeaderMap()
        var body = BytesBody.from_bytes(_b(String("xy")))
        var req = build_request_with_body[BytesBody](
            HttpMethod.put(), url^, hdrs^, body^,
        )
        var resp = client.call_pooled[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
        ](req^, connector, reactor)
        assert_equal(Int(resp.status), 200, "op " + String(i))
        # After op 0 the keepalive conn must be stashed.
        assert_true(
            client.h1_idle_conn_is_cached(),
            "idle conn must be cached after op " + String(i),
        )
        i = i + 1

    # THE HEADLINE ASSERTION — 1 dial, not 10.
    assert_equal(
        connector.connect_call_count(),
        1,
        "call_pooled keepalive: N=10 ops must use 1 connect, not N",
    )


# =============================================================================
# Test 2 — Connection: close response DROPS the cache; next op dials fresh.
# =============================================================================


def test_pooled_connection_close_drops_cache() raises:
    """A `call_pooled` response with `Connection: close` must NOT be cached —
    the cache is empty afterward and the next op dials fresh."""
    var script_1 = _b(String(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream_1 = ScriptedStream.from_read_script(script_1^)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own_conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own_conn^)
    var reactor = _make_reactor()

    var url_1 = Url.parse(String("http://127.0.0.1:9000/bucket/k1"))
    var hdrs_1 = HeaderMap()
    var body_1 = BytesBody.from_bytes(_b(String("xy")))
    var req_1 = build_request_with_body[BytesBody](
        HttpMethod.put(), url_1^, hdrs_1^, body_1^,
    )
    var resp_1 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
    ](req_1^, connector, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(
        resp_1.connection_close,
        "response 1 must report connection_close=True",
    )
    assert_false(
        client.h1_idle_conn_is_cached(),
        "cache must be DROPPED after Connection: close",
    )

    # Next op must dial fresh (the cache is empty). Arm a second stream.
    var stream_2 = ScriptedStream.from_read_script(
        _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    )
    connector.arm(stream_2^)
    var url_2 = Url.parse(String("http://127.0.0.1:9000/bucket/k2"))
    var hdrs_2 = HeaderMap()
    var body_2 = BytesBody.from_bytes(_b(String("xy")))
    var req_2 = build_request_with_body[BytesBody](
        HttpMethod.put(), url_2^, hdrs_2^, body_2^,
    )
    var resp_2 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
    ](req_2^, connector, reactor)
    assert_equal(Int(resp_2.status), 200)
    assert_equal(
        connector.connect_call_count(),
        2,
        "Connection: close on op1 forces fresh dial on op2",
    )


# =============================================================================
# Test 3 — Mixed GET + PUT to the same origin reuse one conn (broker shape).
# =============================================================================


def test_pooled_mixed_get_put_reuse_one_conn() raises:
    """A broker `_append_inner` interleaves GET (read-head) and PUT (CAS) on
    ONE store. This drives GET then PUT then GET through `call_pooled` to the
    same origin and asserts a SINGLE dial across all three (keepalive reuse
    spans the read+write ops)."""
    var script = _script_n_keepalive_responses(3)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    var own_conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own_conn^)
    var reactor = _make_reactor()

    # Op 1 — GET.
    var url_g = Url.parse(String("http://127.0.0.1:9000/bucket/_HEAD"))
    var hdrs_g = HeaderMap()
    var req_g = build_get_request(url_g^, hdrs_g^)
    var resp_g = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req_g^, connector, reactor)
    assert_equal(Int(resp_g.status), 200)

    # Op 2 — PUT (CAS).
    var url_p = Url.parse(String("http://127.0.0.1:9000/bucket/_HEAD"))
    var hdrs_p = HeaderMap()
    var body_p = BytesBody.from_bytes(_b(String("xy")))
    var req_p = build_request_with_body[BytesBody](
        HttpMethod.put(), url_p^, hdrs_p^, body_p^,
    )
    var resp_p = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
    ](req_p^, connector, reactor)
    assert_equal(Int(resp_p.status), 200)

    # Op 3 — GET again.
    var url_g2 = Url.parse(String("http://127.0.0.1:9000/bucket/_HEAD"))
    var hdrs_g2 = HeaderMap()
    var req_g2 = build_get_request(url_g2^, hdrs_g2^)
    var resp_g2 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req_g2^, connector, reactor)
    assert_equal(Int(resp_g2.status), 200)

    assert_equal(
        connector.connect_call_count(),
        1,
        "GET+PUT+GET to one origin must reuse one conn (1 dial)",
    )


# =============================================================================
# Test 4 —: a stashed conn the server half-closed is NOT reused dead.
# =============================================================================


def test_pooled_dead_keepalive_redials_cleanly() raises:
    """The validity guard: after op 1 stashes a keepalive conn, the server
    silently half-closes it. Op 2 (same origin) finds the stashed conn, drives
    on it, the head-read FAILS (dead conn), and `call_pooled` transparently
    re-dials a FRESH conn + replays the request — returning a valid response
    rather than propagating the dead-conn error.

    Models the closed-keepalive race the broker would otherwise crash on.

    ⚠ OP 2 CARRIES AN `Idempotency-Key`, AND THAT IS A STRENGTHENING, NOT AN
    ACCOMMODATION. The subject here is the POOL, and this file's subject is the
    broker/S3 write path — a body-carrying PUT is the request that path
    actually issues, so the fixture keeps it. But a PUT whose bytes reached the
    wire is NOT replay-safe: `_h1_method_is_replay_safe` (client.mojo) is
    RFC 9110 §9.2.1's SAFE set, which is Go's shipped
    `Request.isReplayable` set, because "PUT is idempotent" (RFC 9110 §9.2.2)
    is a promise the ORIGIN SERVER makes and the client cannot verify. See
    `test_row1_not_replay_safe_with_bytes_written_is_not_retried`
    (`test_h1_pool_stale_conn_retry_safety.mojo`). The replay this guard
    requires therefore needs a LICENCE, and the licence is the caller stating
    it per-request — so the test now names the thing it was silently depending
    on. Only op 2 carries it: op 1 merely warms the pool and is never replayed,
    and the two are distinct operations, so they may not share one key.

    EVERY COUNT BELOW IS UNCHANGED — the header is an input to the RETRY
    DECISION, not to the dial accounting."""
    # Op 1: a normal keepalive response -> stashes the conn.
    var stream_1 = ScriptedStream.from_read_script(
        _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    )
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own_conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own_conn^)
    var reactor = _make_reactor()

    var url_1 = Url.parse(String("http://127.0.0.1:9000/bucket/k1"))
    var hdrs_1 = HeaderMap()
    var body_1 = BytesBody.from_bytes(_b(String("xy")))
    var req_1 = build_request_with_body[BytesBody](
        HttpMethod.put(), url_1^, hdrs_1^, body_1^,
    )
    var resp_1 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
    ](req_1^, connector, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(
        client.h1_idle_conn_is_cached(),
        "op1 must stash a keepalive conn",
    )

    # Now arm the connector's NEXT (fresh-dial) stream with a valid response,
    # and poison the CACHED stream so the reuse attempt's head-read errors.
    # The ScriptedConnector's `arm` replaces the stream `connect` will hand out
    # on the fresh-dial; we cannot reach into the cached stream directly, so
    # we make the cached stream error by re-arming the original connector's
    # next-dial with a healthy stream and forcing the reused conn to fail. The
    # ScriptedStream stashed on op1 is the `stream_1` whose read-script is now
    # exhausted (cursor at end) -> its next try_read returns EOF, which the
    # head parser surfaces as a transport error on the reused conn. So op2's
    # reuse attempt fails on the exhausted cached stream and triggers.
    var fresh = ScriptedStream.from_read_script(
        _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    )
    connector.arm(fresh^)

    var url_2 = Url.parse(String("http://127.0.0.1:9000/bucket/k1"))
    var hdrs_2 = HeaderMap()
    # THE REPLAY LICENCE. Without it a PUT whose bytes reached the wire is not
    # replayed (see this test's docstring), and the pool-validity property
    # below could not be observed at all on a body-carrying request.
    hdrs_2.insert(String("Idempotency-Key"), String("k1-op2"))
    var body_2 = BytesBody.from_bytes(_b(String("xy")))
    var req_2 = build_request_with_body[BytesBody](
        HttpMethod.put(), url_2^, hdrs_2^, body_2^,
    )
    var resp_2 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
    ](req_2^, connector, reactor)
    # the dead/exhausted cached conn surfaced an error; call_pooled
    # re-dialed fresh and replayed -> a valid 200.
    assert_equal(
        Int(resp_2.status),
        200,
        "dead keepalive conn must re-dial fresh + replay, not error",
    )
    # Dial accounting: op1 dialed the constructed stream (count=1); op2 found
    # the cached conn (NO dial on reuse), its head-read failed on the
    # exhausted stream, and re-dialed fresh (count=2).
    assert_equal(
        connector.connect_call_count(),
        2,
        "op1 dial (1) + op2 dead-conn fresh re-dial (1) = 2 connects",
    )
    # The re-dial stashed the (now-keepalive) fresh conn for the next op.
    assert_true(
        client.h1_idle_conn_is_cached(),
        "the re-dial's keepalive response must re-stash the fresh conn",
    )


def main() raises:
    test_n_pooled_puts_reuse_one_conn()
    test_pooled_connection_close_drops_cache()
    test_pooled_mixed_get_put_reuse_one_conn()
    test_pooled_dead_keepalive_redials_cleanly()
    print(
        "[OK] test_http_client_call_pooled_keepalive — all 4 tests passed"
    )
