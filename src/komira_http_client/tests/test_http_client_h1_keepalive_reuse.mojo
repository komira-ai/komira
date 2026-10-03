# =============================================================================
# src/komira_http_client/tests/test_http_client_h1_keepalive_reuse.mojo
#   regression tests.
# =============================================================================
#
# Verifies the architectural invariant of the keepalive-reuse fix:
#
#   * HttpClient[C] owns a long-lived `_h1_idle_conn` field of type
#     `Optional[OwnedPointer[ClientConn[Self.C.Stream]]]`. After a
#     response completes with `connection_close=False` (the HTTP/1.1
#     default), the underlying stream is stashed back into the field.
#     The NEXT same-origin `send_buffered` extracts the cached stream
#     and skips the `connector.connect()` dial.
#
# The no-reuse shape: every `send_buffered` calls
# `connector.connect[RT](...)`, materializing a fresh stream. For N
# sequential requests to the same origin, `connect_call_count == N`.
#
# Post-fix shape: after the first dial, the stream is cached on
# HttpClient. N-1 subsequent calls REUSE; `connect_call_count == 1`.
#
# Acceptance gate (this slot): all 4 tests below must FAIL pre-fix and
# PASS post-fix. The pre-fix failure modes are documented per-test.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
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
"""Length of one canned HTTP/1.1 200 OK / CL=2 / "OK" response:
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK" = 40 bytes.

Status line (15) + CRLF (2) + "Content-Length: 2" (17) + CRLF (2)
+ CRLF (2) + body (2) = 40."""


def _script_n_keepalive_responses(n: Int) -> List[UInt8]:
    """Build a byte script containing N back-to-back HTTP/1.1 200 OK
    responses, each with `Content-Length: 2\r\n\r\nOK`. NO Connection
    header — HTTP/1.1 default is keepalive (connection_close=False).
    The ScriptedStream serves these serially on successive try_read
    calls; each request_response cycle consumes one response.

    NOTE: callers MUST cap `set_max_read_per_call(_SINGLE_RESPONSE_BYTES)`
    on the ScriptedStream so each try_read returns at most one response.
    Otherwise the first request's greedy read consumes the entire N×38
    byte script in one syscall; the head parser's `_extract_pre_body_bytes`
    + `new_content_length`'s truncate-to-cl_total path DISCARDS responses
    2..N as pre-body-overrun (a pre-existing limitation in
    state_machine.mojo + response_body.mojo, unrelated to this slot).
    Real sockets return one kernel-buffer's worth at a time; setting
    max-per-call models that accurately for the ScriptedStream test
    seam."""
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
# Test 1 — N=10 sequential send_buffered calls REUSE one conn.
# =============================================================================
#
# THE HEADLINE GATE. Before the fix: N=10 sends → 10 connects. After
# the fix: N=10 sends → 1 connect (the rest reuse the cached stream).
#
# Pre-fix failure: `assert_equal(connect_call_count, 1)` FAILS with
# observed=10 / expected=1.


def test_n_sequential_sends_reuse_one_conn() raises:
    """N=10 sequential send_buffered calls to the same origin issue
    exactly ONE connect (the fresh dial); the remaining 9 reuse the
    cached connection.

    HEADLINE ASSERTION: connector.connect_call_count() == 1.

    This is the load-bearing structural proof that h1 keepalive-reuse
    is working — vs the v1 "dials_total bumps by N" behavior."""
    # Script 10 HTTP/1.1 keepalive responses back-to-back. Cap per-call
    # read to one response's worth so the head parser does NOT overrun
    # into subsequent responses (a pre-existing limitation of
    # state_machine.mojo:_extract_pre_body_bytes — see helper docstring).
    var script = _script_n_keepalive_responses(10)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var i = 0
    while i < 10:
        var url = Url.parse(String("http://127.0.0.1:8080/health"))
        var hdrs = HeaderMap()
        var req = build_get_request(url^, hdrs^)
        var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
        assert_equal(Int(resp.status), 200, "request " + String(i))
        i = i + 1

    # THE HEADLINE ASSERTION — must be 1, not 10.
    assert_equal(
        client._connector.connect_call_count(),
        1,
        "h1 keepalive-reuse: N=10 sends must use 1 connect, not N",
    )
    # h1 pool's dials_total tracks the same — 1 fresh dial.
    assert_equal(
        client.h1_pool_dials_total(),
        1,
        "h1_pool_dials_total: 1 fresh dial, not N",
    )


# =============================================================================
# Test 2 — Connection: close response DROPS the cache + next dial fresh.
# =============================================================================
#
# Pre-fix failure: `assert_equal(connect_call_count, 2)` PASSES (every
# send dials anyway) BUT the new diagnostic accessor
# `h1_idle_conn_is_cached()` doesn't exist → COMPILE FAILS.
#
# Post-fix: after the Connection: close response, the cache is dropped.
# The second send dials fresh. connect_call_count == 2 (1 + 1).


def test_connection_close_drops_cache() raises:
    """A response with `Connection: close` must NOT be cached for
    reuse — the next send dials fresh. The diagnostic accessor
    `h1_idle_conn_is_cached()` returns False after a Connection: close
    response.

    Pre-fix: this test FAILS to build because `h1_idle_conn_is_cached`
    is not a method on HttpClient.

    Post-fix: GREEN."""
    # Script: response #1 has Connection: close; response #2 is normal
    # keepalive. Even when the stream's read_script is consumed
    # serially, the cache-drop after #1 means the client must call
    # connector.connect() again before #2 — so we need to arm a SECOND
    # stream that ALSO holds response #2.
    var script_1 = _b(String(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream_1 = ScriptedStream.from_read_script(script_1^)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    # Send #1 — Connection: close response.
    var url_1 = Url.parse(String("http://127.0.0.1:8080/x"))
    var hdrs_1 = HeaderMap()
    var req_1 = build_get_request(url_1^, hdrs_1^)
    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req_1^, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(
        resp_1.connection_close,
        "response 1 must have connection_close=True",
    )
    # Cache must be EMPTY after Connection: close.
    assert_false(
        client.h1_idle_conn_is_cached(),
        "h1 idle conn cache must be DROPPED after Connection: close",
    )

    # Arm a SECOND stream for send #2 (Connection: close already
    # forced the cache-drop; the next send WILL dial fresh).
    var script_2 = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream_2 = ScriptedStream.from_read_script(script_2^)
    client._connector.arm(stream_2^)

    var url_2 = Url.parse(String("http://127.0.0.1:8080/y"))
    var hdrs_2 = HeaderMap()
    var req_2 = build_get_request(url_2^, hdrs_2^)
    var resp_2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req_2^, reactor,
    )
    assert_equal(Int(resp_2.status), 200)
    # Second send required a fresh dial → connect_call_count == 2.
    assert_equal(
        client._connector.connect_call_count(),
        2,
        "Connection: close on #1 forces fresh dial on #2",
    )


# =============================================================================
# Test 3 — Cross-host send drops the cache + dials fresh.
# =============================================================================
#
# Pre-fix: passes trivially (every send dials, so 2 sends → 2 connects).
# But h1_idle_conn_is_cached() doesn't exist → COMPILE FAILS.
#
# Post-fix: after send #1 to host A, cache holds A's conn. Send #2 to
# host B sees key mismatch → drops A's conn → dials fresh for B.


def test_mismatch_host_drops_cache_and_dials_fresh() raises:
    """A send to a DIFFERENT (host, port) than the cached conn must
    drop the cache + dial fresh. Verifies the key-equality check
    inside `_take_h1_idle_conn_for`."""
    # Both responses are HTTP/1.1 default keepalive.
    var script_1 = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream_1 = ScriptedStream.from_read_script(script_1^)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    # Send #1 to host A.
    var url_a = Url.parse(String("http://127.0.0.1:8080/"))
    var hdrs_a = HeaderMap()
    var req_a = build_get_request(url_a^, hdrs_a^)
    var resp_a = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req_a^, reactor,
    )
    assert_equal(Int(resp_a.status), 200)
    assert_false(
        resp_a.connection_close, "response A must be keepalive",
    )
    assert_true(
        client.h1_idle_conn_is_cached(),
        "after A: cache must be populated",
    )

    # Arm a second stream for host B.
    var script_2 = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream_2 = ScriptedStream.from_read_script(script_2^)
    client._connector.arm(stream_2^)

    # Send #2 to a DIFFERENT host. Cache mismatch → drop + dial fresh.
    var url_b = Url.parse(String("http://10.0.0.1:9090/"))
    var hdrs_b = HeaderMap()
    var req_b = build_get_request(url_b^, hdrs_b^)
    var resp_b = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req_b^, reactor,
    )
    assert_equal(Int(resp_b.status), 200)
    # 2 connects total: 1 for A (fresh), 1 for B (after cache-mismatch
    # drop).
    assert_equal(
        client._connector.connect_call_count(),
        2,
        "host mismatch forces fresh dial",
    )


# =============================================================================
# Test 4 — Fresh client has no cached idle conn.
# =============================================================================
#
# Pre-fix: COMPILE FAILS (h1_idle_conn_is_cached doesn't exist).
# Post-fix: GREEN.


def test_fresh_client_has_no_idle_conn_cache() raises:
    """A freshly-constructed HttpClient that has never sent must report
    `h1_idle_conn_is_cached() == False`. Lazy-init: cache field starts
    in None."""
    var stream = ScriptedStream.empty()
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    assert_false(
        client.h1_idle_conn_is_cached(),
        "fresh HttpClient must NOT have h1 idle-conn cached",
    )


def main() raises:
    test_n_sequential_sends_reuse_one_conn()
    test_connection_close_drops_cache()
    test_mismatch_host_drops_cache_and_dials_fresh()
    test_fresh_client_has_no_idle_conn_cache()
    print("[OK] test_http_client_h1_keepalive_reuse — all 4 tests passed")
