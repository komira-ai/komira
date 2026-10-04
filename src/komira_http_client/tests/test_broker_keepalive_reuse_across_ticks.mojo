# =============================================================================
# tests/objectstore/test_broker_keepalive_reuse_across_ticks.mojo
#
# =============================================================================
#
# THE FIX UNDER TEST. The m6 consumer-group e2e's PHASE-3 "coordinator stall"
# was NOT a serve-loop stall — it was host EPHEMERAL-PORT EXHAUSTION (a
# TIME_WAIT storm: ~16K short-lived sockets to MinIO, EADDRNOTAVAIL on the next
# connect). The root cause was the broker DEFEATING the per-HttpClient h1
# keepalive cache (client.mojo:_h1_idle_conn) by building a FRESH HttpClient per
# operation:
#   * the consume path built a FRESH ConsumeCore per Fetch (each `.clone()`s the
#     store -> a fresh-empty transport Arc -> a fresh HttpClient -> a fresh dial);
#   * the broker heartbeat built a FRESH `HttpClient.with_defaults` per tick.
#
# Both reuse the SAME underlying mechanism: the HttpClient's `_h1_idle_conn`
# cache stashes a keepalive-safe connection after a response and the NEXT
# same-origin `send_buffered` REUSES it (skips the dial). Holding ONE long-lived
# HttpClient across N operations collapses N dials -> 1.
#
# THIS TEST proves that architectural contract directly, using the Scripted
# connector's `connect_call_count()` dial counter (the same seam
# test_http_client_h1_keepalive_reuse.mojo uses):
#   * RED-before / pre-fix model — `_n_posts_each_on_a_fresh_client`: the broker
#     used to build a fresh client per tick. N POSTs on N fresh clients => N
#     dials. This is the exhaustion-driving pattern.
#   * GREEN-after / post-fix model — `_n_posts_over_one_held_client`: the broker
#     serve loop now holds ONE client across ticks (broker_main.mojo:
#     _serve_and_heartbeat_forever) and routes the heartbeat through
#     send_broker_heartbeat_over. N POSTs over ONE client => 1 dial.
#
# The headline assertion (`held_client_dials == 1` while `fresh_client_dials
# == N`) IS the churn collapse — the same delta that drops the e2e TIME_WAIT
# count from ~16K to a handful. It is deterministic + MinIO-free: the
# ScriptedConnector models a keepalive server with no socket churn confound.
#
# Encapsulation / stale-pointer: value-typed surface throughout; no UnsafePointer crosses
# any boundary; no wildcard origin; the held client is a stack value mutated
# single-threaded (the broker serve loop's discipline).
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _N_TICKS: Int = 10
"""How many heartbeat ticks / fetch round-trips to model. The exhaustion in the
e2e was ~16K; 10 is enough to prove the N-vs-1 contract deterministically."""

# One canned HTTP/1.1 200 OK / CL=2 / "OK" keepalive response (NO Connection:
# close -> HTTP/1.1 default keepalive). 40 bytes, matching
# test_http_client_h1_keepalive_reuse.mojo's _SINGLE_RESPONSE_BYTES.
comptime _SINGLE_RESPONSE_BYTES: Int = 40


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
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _one_keepalive_response() -> List[UInt8]:
    return _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))


def _n_keepalive_responses(n: Int) -> List[UInt8]:
    """N back-to-back keepalive responses on one stream (for the held-client
    case: one connection serves all N round-trips serially)."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var part = _one_keepalive_response()
        var j = 0
        var m = part.__len__()
        while j < m:
            out.append(part[j])
            j = j + 1
        i = i + 1
    return out^


def _post_heartbeat_shaped(
    mut client: HttpClient[ScriptedConnector],
    mut reactor: Reactor[NoopSink],
    tick: Int,
) raises:
    """One heartbeat-shaped POST (the wire shape of
    send_broker_heartbeat_over: a POST with a small body to a fixed origin)
    over the given client. The keepalive cache reuse is driven by
    `send_buffered` regardless of method."""
    var url = Url.parse(String("http://127.0.0.1:9099/internal/heartbeat"))
    var headers = HeaderMap()
    headers.append(String("Content-Type"), String("application/protobuf"))
    var body = _b(String("hb-") + String(tick))
    var req = build_request_with_body[BytesBody](
        HttpMethod(code=HTTP_METHOD_POST),
        url^,
        headers^,
        BytesBody.from_bytes(body^),
    )
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink], BytesBody](
        req^, reactor
    )
    assert_equal(Int(resp.status), 200, "heartbeat tick " + String(tick))


def _n_posts_over_one_held_client(n: Int) raises -> Int:
    """POST-FIX MODEL: the broker serve loop holds ONE HttpClient across N
    ticks. Returns the number of fresh dials (must be 1)."""
    var script = _n_keepalive_responses(n)
    var stream = ScriptedStream.from_read_script(script^)
    # Cap per-call read so the head parser does not overrun into the next
    # response (the same ScriptedStream discipline the keepalive-reuse test
    # documents).
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var i = 0
    while i < n:
        _post_heartbeat_shaped(client, reactor, i)
        i = i + 1
    return client._connector.connect_call_count()


def _n_posts_each_on_a_fresh_client(n: Int) raises -> Int:
    """PRE-FIX MODEL (the exhaustion driver): a FRESH HttpClient per tick (the
    old `send_broker_heartbeat_blocking` / fresh-ConsumeCore-per-fetch shape).
    Each fresh client dials once -> N dials -> N TIME_WAIT sockets. Returns the
    cumulative dial count across the N fresh clients (must be N)."""
    var reactor = _make_reactor()
    var total_dials = 0
    var i = 0
    while i < n:
        var stream = ScriptedStream.from_read_script(_one_keepalive_response())
        stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
        var connector = ScriptedConnector.with_stream(stream^)
        var client = HttpClient[ScriptedConnector].with_defaults(connector^)
        _post_heartbeat_shaped(client, reactor, i)
        # Each fresh client did exactly one dial; sum them.
        total_dials = total_dials + client._connector.connect_call_count()
        i = i + 1
    return total_dials


# =============================================================================
# THE HEADLINE GATE — held-client reuse collapses N dials to 1.
# =============================================================================
def test_held_client_reuses_one_conn_across_ticks() raises:
    """The broker serve loop's held-client pattern issues exactly ONE dial for
    N heartbeat ticks (N round-trips reuse the keepalive connection). This is
    the churn collapse that drops the e2e TIME_WAIT count from ~16K to a
    handful."""
    var held_dials = _n_posts_over_one_held_client(_N_TICKS)
    assert_equal(
        held_dials,
        1,
        "held-client: N=" + String(_N_TICKS)
        + " heartbeat ticks must reuse ONE connection (1 dial), not N",
    )


# =============================================================================
# The negative control — the pre-fix fresh-per-tick pattern DID churn N dials.
# =============================================================================
def test_fresh_client_per_tick_churns_n_dials() raises:
    """The pre-fix pattern (a fresh HttpClient per tick — what
    send_broker_heartbeat_blocking and the old fresh-ConsumeCore-per-fetch path
    did) dials N times for N ticks. This is the exact behavior that exhausted
    the host's ephemeral ports. Documents WHY the held-client fix matters."""
    var fresh_dials = _n_posts_each_on_a_fresh_client(_N_TICKS)
    assert_equal(
        fresh_dials,
        _N_TICKS,
        "fresh-per-tick: N=" + String(_N_TICKS)
        + " ticks dial N times (the exhaustion driver the fix eliminates)",
    )


# =============================================================================
# The contract delta — held reuse is strictly fewer dials than fresh-per-tick.
# =============================================================================
def test_reuse_strictly_collapses_churn() raises:
    """The held-client reuse (1 dial) is strictly less than the fresh-per-tick
    churn (N dials). The ratio IS the ephemeral-port relief: N:1."""
    var held = _n_posts_over_one_held_client(_N_TICKS)
    var fresh = _n_posts_each_on_a_fresh_client(_N_TICKS)
    assert_equal(held, 1, "held reuse = 1 dial")
    assert_equal(fresh, _N_TICKS, "fresh per tick = N dials")
    # The collapse: held must be far below fresh (1 vs N).
    if not (held < fresh):
        raise Error(
            "BROKER-KEEPALIVE-REUSE: held-client dials ("
            + String(held)
            + ") must be < fresh-per-tick dials ("
            + String(fresh)
            + ")"
        )


def main() raises:
    test_held_client_reuses_one_conn_across_ticks()
    test_fresh_client_per_tick_churns_n_dials()
    test_reuse_strictly_collapses_churn()
    print(
        "[OK] test_broker_keepalive_reuse_across_ticks — held-client reuse"
        " collapses N dials to 1 (host ephemeral-port exhaustion fix)"
    )
