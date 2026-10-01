# =============================================================================
# src/komira_http/tests/test_http_client_read_head_scratch.mojo
#   combined-slot regression.
# =============================================================================
#
# These are the regression tests for the combined slot (paired with
#). They verify the
# architectural invariant of the fix:
#
#   * HttpClient[C] owns a long-lived `_read_head_scratch` field of type
#     `Optional[OwnedPointer[InlineArray[UInt8, 4096]]]`. This field is
#     allocated LAZILY on the first send-buffered call and is REUSED
#     across all subsequent send-buffered calls (no per-request alloc).
#
# Pre-fix shape: the previous implementation allocated a 4 KB
# `List[UInt8]` inside `OutboundDriver._drive_read_head` per request,
# zero-initialized via 4096 append calls. The architectural invariant
# was NOT enforceable via field-existence; instead it was a per-call
# alloc.
#
# Post-fix shape: the scratch field on HttpClient + a `ref` accessor
# threaded through `_dispatch_pooled_buffered` →
# `_run_one_request_buffered_h1_with_scratch` →
# `OutboundDriver._drive_read_head_with_scratch`. Strictly one alloc
# per HttpClient lifetime; ZERO per-request alloc on the hot path.
#
# Test 1: fresh HttpClient → `read_head_scratch_is_init() == False`.
# Test 2: after one `send_buffered` → `read_head_scratch_is_init() == True`.
# Test 3: after N=8 `send_buffered` cycles → still True (no re-allocate).
# Test 4: response head + body parse correctly through the new code path
#         (semantic equivalence to pre-fix).
#
# The fix MUST land all 4 tests GREEN. Pre-fix code FAILS to compile
# because the `read_head_scratch_is_init()` method does not exist on
# HttpClient.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.response_body import BufferedResponseBody
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


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


# =============================================================================
# Test 1 — fresh HttpClient: scratch NOT init.
# =============================================================================


def test_fresh_client_has_no_scratch_init() raises:
    """A freshly-constructed HttpClient must have `_read_head_scratch`
    in the `None` state. Lazy-init defers the 4 KB allocation to the
    first send-buffered call."""
    var stream = ScriptedStream.empty()
    var conn = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(conn^)
    assert_false(
        client.read_head_scratch_is_init(),
        "fresh HttpClient must NOT have read-head scratch init",
    )


# =============================================================================
# Test 2 — one send_buffered: scratch is init.
# =============================================================================


def test_send_buffered_inits_scratch() raises:
    """The first send-buffered call must lazy-init the scratch field.
    After the call returns, `read_head_scratch_is_init()` must be True.
    """
    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    # Pre-call: scratch must NOT be init.
    assert_false(
        client.read_head_scratch_is_init(),
        "pre-call: scratch must not be init",
    )

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)

    # Post-call: scratch MUST be init.
    assert_true(
        client.read_head_scratch_is_init(),
        "post-call: scratch must be init (lazy-allocated)",
    )


# =============================================================================
# Test 3 — N=8 send_buffered cycles: scratch stays init (reused).
# =============================================================================


def test_n_send_buffered_reuses_scratch() raises:
    """Across N=8 send_buffered cycles on the same HttpClient, the
    scratch field must remain init (one allocation, reused). This is
    the architectural invariant — `read_head_scratch_is_init()` stays
    True from the first call onward.

    The fact that we re-arm the ScriptedConnector with a new stream
    between calls (since ScriptedConnector.with_stream is one-shot)
    does NOT affect the HttpClient's scratch state — HttpClient owns
    its own scratch independently of the connector.
    """
    # With keepalive reuse:
    # The HttpClient's h1 idle-conn cache reuses ONE stream across
    # all 8 calls. Script all 8 responses back-to-back into one
    # stream + set_max_read_per_call(40) so each try_read returns
    # exactly one response (modeling real socket behavior).
    var n_cycles = 8
    var bytes_per_resp = 40
    var multi_script_str = String()
    var ki = 0
    while ki < n_cycles:
        multi_script_str = multi_script_str + String(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
        )
        ki = ki + 1
    var multi_script = _b(multi_script_str^)

    var stream0 = ScriptedStream.from_read_script(multi_script^)
    stream0.set_max_read_per_call(bytes_per_resp)
    var connector = ScriptedConnector.with_stream(stream0^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var i = 0
    while i < n_cycles:
        # Build a fresh request for each cycle (Url and HeaderMap don't
        # have public copy()). Same shape, parsed independently.
        var url_i = Url.parse(String("http://127.0.0.1:8080/health"))
        var req_hdrs = HeaderMap()
        var req = build_get_request(url_i^, req_hdrs^)
        var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
        assert_equal(Int(resp.status), 200, "iteration " + String(i))
        # After every iteration, scratch must STILL be init (reused).
        assert_true(
            client.read_head_scratch_is_init(),
            "iteration " + String(i) + ": scratch must remain init",
        )
        i = i + 1


# =============================================================================
# Test 4 — semantic equivalence: response parses correctly through
# the scratch-threaded code path.
# =============================================================================


def test_response_parses_correctly_via_scratch_path() raises:
    """A multi-header response with a body must parse correctly through
    the new scratch-threaded `_drive_read_head_with_scratch` path. This
    is the semantic-equivalence gate — the refactor MUST NOT regress
    parsing correctness."""
    var url = Url.parse(String("http://127.0.0.1:8080/data"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 13\r\n"
        "X-Custom: test-value\r\n"
        "\r\n"
        "Hello, World!"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(resp.reason, String("OK"))
    # Body length must match Content-Length: 13 ("Hello, World!").
    assert_equal(resp.body.bytes_remaining(), 13)


def main() raises:
    test_fresh_client_has_no_scratch_init()
    test_send_buffered_inits_scratch()
    test_n_send_buffered_reuses_scratch()
    test_response_parses_correctly_via_scratch_path()
    print(
        "[OK] test_http_client_read_head_scratch — all 4 tests passed"
    )
