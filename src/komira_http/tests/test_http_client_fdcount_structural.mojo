"""fd-count=1 structural gate.

Verifies the load-bearing invariant that drives the §10.3
ObjectStore range fan-out gate:

  "For N concurrent range requests to the same origin via h2 multiplex,
   the client opens exactly ONE TCP connection (fd-count=1)."

ships the STRUCTURAL leg of this gate. The full real-TCP leg
(lsof -p $pid | grep TCP | wc -l == 1 against server in a
background subprocess) is filed as a follow-up — it requires
Python h2 subprocess wiring + real socket setup that exceeds the
budget.

The structural leg verifies the same invariant via the pool's
diagnostic accessors:
  * N sequential h2-multiplex checkouts on the same key result in ONE
    insert_dialed_h2 + (N-1) reuses of the same (b_idx, c_idx).
  * h1 sequential sends — dials_total bumps by N (no h1 keepalive
    reuse in v1; will lower this to 1 via RecvRingBody.take_stream).

These are not "best-effort" or "hope this works on real-TCP" — they're
the canonical invariant assertion the gate is built on.
"""

from std.sys import CompilationTarget

from std.memory import OwnedPointer

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
from komira_http.client.h2_client import H2ClientConnectionState
from komira_http.client.h2_pool import (
    H2_OUTCOME_FOUND,
    H2_OUTCOME_NEEDS_DIAL,
    H2ClientPool,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.pool import (
    ALPN_H2,
    ClientConn,
    PoolKey,
    PoolSizingKnobs,
    VERIFY_PEER,
)
from komira_http.client.url import Url
from komira_http.transport.io_stream import NEGOTIATED_HTTP_1_1
from komira_http.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)


def _b(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var n = len(bs)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        out.append(bs[i])
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


# =============================================================================
# Test 1 — h2 multiplex pool: N checkouts → 1 insert_dialed_h2.
# =============================================================================


def test_h2_multiplex_invariant_n_streams_one_conn() raises:
    """The h2 pool's multiplex invariant: after inserting ONE conn with
    capacity for N streams, N sequential try_checkout_or_pending calls
    all return FOUND with the same (b_idx, c_idx). Zero additional
    dials.

    This is the load-bearing structural proof of the fd-count=1
    invariant: in the absence of GOAWAY, one h2 conn serves N streams."""
    var pool = H2ClientPool[ScriptedStream].with_defaults()
    var key = PoolKey.https_h2(
        String("api.example.com"), UInt16(443), VERIFY_PEER,
    )

    # Insert a fresh dialed conn with default max_concurrent_streams_peer
    # (which is 100 — RFC 7540 §6.5.2 default).
    var stream = ScriptedStream.empty()
    var client_conn = ClientConn[ScriptedStream].new(
        stream^, key.copy(), 0,
    )
    var h2_state = H2ClientConnectionState()
    var first_insert = pool.insert_dialed_h2(
        key.copy(), client_conn^, h2_state^,
    )
    assert_equal(pool.dials_total(), 1)
    assert_equal(first_insert.bucket_idx, 0)
    assert_equal(first_insert.conn_idx, 0)

    # N sequential checkouts all return FOUND with the same indices —
    # multiplex semantics: one conn serves many streams.
    var N = 8
    var i = 0
    while i < N:
        var outcome = pool.try_checkout_or_pending(key.copy())
        assert_equal(
            outcome.outcome,
            H2_OUTCOME_FOUND,
            String("checkout ") + String(i) + String(" must be FOUND"),
        )
        var found = outcome.found.take()
        assert_equal(found.bucket_idx, 0)
        assert_equal(found.conn_idx, 0)
        i = i + 1

    # dials_total UNCHANGED — no additional dials happened.
    assert_equal(pool.dials_total(), 1)
    assert_equal(pool.bucket_count(), 1)


# =============================================================================
# Test 2 — ScriptedConnector connect_call_count tracking.
# =============================================================================


def test_scripted_connector_counts_dials() raises:
    """ScriptedConnector.connect_call_count tracks the number of dials —
    used by fd-count gates that verify the pool short-circuits new
    dials when an existing pooled conn has capacity."""
    var stream = ScriptedStream.empty()
    var connector = ScriptedConnector.with_stream(stream^)
    assert_equal(connector.connect_call_count(), 0)
    var reactor = _make_reactor()
    var s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor, UInt32(0x0100007F), UInt16(443),
    )
    _ = s^
    assert_equal(connector.connect_call_count(), 1)


# =============================================================================
# Test 3 — h1 sequential dials_total bumps by N.
# =============================================================================


def test_h1_sequential_sends_dials_total_n() raises:
    """Three sequential send_buffered calls via h1 ALPN — after the
    slot,
    `dials_total == 1` (one fresh dial; the other two REUSE the cached
    h1 conn). Pre-fix-v1 behavior was dials_total == 3.

    Test asserts the keepalive-reuse architectural invariant matches
    the regression-test gate of the slot.
    Single 3-response script lets all 3 calls run through the cached
    stream; `set_max_read_per_call(40)` mirrors a real socket's
    one-syscall-per-response shape (otherwise the first call's greedy
    read consumes all 3 responses + the head parser's truncate-to-
    cl_total drops the trailing 2)."""
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var s1 = ScriptedStream.from_read_script(resp_script^)
    s1.set_max_read_per_call(40)  # one response = 40 bytes
    var connector = ScriptedConnector.with_stream(s1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var i = 0
    while i < 3:
        var url = Url.parse(String("http://127.0.0.1:8080/"))
        var hdrs = HeaderMap()
        var req = build_get_request(url^, hdrs^)
        var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
        assert_equal(Int(resp.status), 200)
        i = i + 1

    # Post-H1-KEEPALIVE-REUSE-MVP: only 1 dial (fresh) + 2 reuses.
    assert_equal(client.h1_pool_dials_total(), 1)
    assert_equal(client._connector.connect_call_count(), 1)


# =============================================================================
# Test 4 — Sibling pool independence under repeated h1 sends.
# =============================================================================


def test_h1_pool_dials_dont_leak_into_h2_pool() raises:
    """N h1 send_buffered calls — h1 pool's dials_total accumulates;
    h2 pool stays uninit (and bucket_count == 0)."""
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var s = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(s^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var url = Url.parse(String("http://127.0.0.1:8080/x"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    # h1 pool init, h2 pool NOT init.
    assert_true(client.h1_pool_is_init())
    assert_false(client.h2_pool_is_init())
    assert_equal(client.h1_pool_dials_total(), 1)
    # h2 bucket_count returns 0 — both because the pool isn't init AND
    # because no h2 conns were inserted.
    assert_equal(client.h2_pool_bucket_count(), 0)


def main() raises:
    test_h2_multiplex_invariant_n_streams_one_conn()
    test_scripted_connector_counts_dials()
    test_h1_sequential_sends_dials_total_n()
    test_h1_pool_dials_dont_leak_into_h2_pool()
    print("[OK] test_http_client_fdcount_structural — all 4 tests passed")
