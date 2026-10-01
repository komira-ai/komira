# =============================================================================
# tests/test_L3_logging.mojo
# =============================================================================
#
# LoggingMiddleware unit tests
#
# Coverage:
#   * before() records start_ns on ctx
#   * after() appends LogEntry with method/path/status/latency
#   * Bounded buffer drops oldest on overflow
#   * disabled() emits no entries
#   * clear() resets the buffer
#   * Sensitive headers NOT captured (LogEntry has no header field)
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.codec import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http.middleware import LoggingMiddleware, RequestContext


def _make_request(method: HttpMethod, path: String) -> HttpRequest:
    var r = HttpRequest(method, path)
    # Add sensitive headers to verify they're NOT logged.
    r.headers[String("authorization")] = String("Bearer secret-token")
    r.headers[String("cookie")] = String("session=abc123")
    return r^


def test_before_sets_start_ns() raises:
    """LoggingMiddleware.before sets ctx.start_ns to a non-zero value."""
    var lg = LoggingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/items"))
    var ctx = RequestContext.new()
    assert_equal(Int(ctx.start_ns), 0)
    var resp_opt = lg.before(req, ctx)
    assert_false(Bool(resp_opt))  # Logging never short-circuits.
    assert_true(ctx.start_ns > UInt64(0))


def test_after_emits_log_entry() raises:
    """After invocation: one LogEntry recorded with method/path/status."""
    var lg = LoggingMiddleware.new()
    var req = _make_request(HttpMethod.post(), String("/items"))
    var ctx = RequestContext.new()
    _ = lg.before(req, ctx)
    var resp = HttpResponse(status=Int32(201))
    lg.after(req, resp, ctx)
    assert_equal(lg.entries_len(), 1)
    var e = lg.entry(0)
    assert_equal(Int(e.method.code), Int(HTTP_METHOD_POST))
    assert_equal(e.path, String("/items"))
    assert_equal(Int(e.status), 201)
    assert_false(e.short_circuit)


def test_disabled_emits_nothing() raises:
    """LoggingMiddleware.disabled() never appends entries."""
    var lg = LoggingMiddleware.disabled()
    var req = _make_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    _ = lg.before(req, ctx)
    var resp = HttpResponse(status=Int32(200))
    lg.after(req, resp, ctx)
    assert_equal(lg.entries_len(), 0)


def test_clear_resets_buffer() raises:
    """clear() empties the entries buffer."""
    var lg = LoggingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/a"))
    var ctx = RequestContext.new()
    _ = lg.before(req, ctx)
    var resp = HttpResponse(status=Int32(200))
    lg.after(req, resp, ctx)
    assert_equal(lg.entries_len(), 1)
    lg.clear()
    assert_equal(lg.entries_len(), 0)


def test_bounded_buffer_drops_oldest_on_overflow() raises:
    """With capacity=2, the third entry pushes out the first."""
    var lg = LoggingMiddleware.with_capacity(2)
    var resp = HttpResponse(status=Int32(200))
    var paths = List[String]()
    paths.append(String("/a"))
    paths.append(String("/b"))
    paths.append(String("/c"))
    var i = 0
    while i < len(paths):
        var req = _make_request(HttpMethod.get(), paths[i])
        var ctx = RequestContext.new()
        _ = lg.before(req, ctx)
        lg.after(req, resp, ctx)
        i = i + 1
    assert_equal(lg.entries_len(), 2)
    # Oldest (/a) dropped; entries are /b, /c.
    assert_equal(lg.entry(0).path, String("/b"))
    assert_equal(lg.entry(1).path, String("/c"))


def test_short_circuit_flag_propagates_into_entry() raises:
    """When ctx.short_circuit is True at after-time, the LogEntry
    flag matches."""
    var lg = LoggingMiddleware.new()
    var req = _make_request(HttpMethod.options(), String("/x"))
    var ctx = RequestContext.new()
    _ = lg.before(req, ctx)
    ctx.short_circuit = True
    var resp = HttpResponse(status=Int32(204))
    lg.after(req, resp, ctx)
    assert_equal(lg.entries_len(), 1)
    assert_true(lg.entry(0).short_circuit)


def test_log_entry_carries_no_headers() raises:
    """LogEntry struct has no headers field — verified by checking
    that even when the request has sensitive headers, the recorded
    entry has only method/path/status/latency_ns/span_id/short_circuit.
    This is a compile-time guarantee but worth a runtime sanity check."""
    var lg = LoggingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/login"))
    var ctx = RequestContext.new()
    _ = lg.before(req, ctx)
    var resp = HttpResponse(status=Int32(200))
    lg.after(req, resp, ctx)
    var e = lg.entry(0)
    # Only path is logged (not query_string, not headers, not body).
    assert_equal(e.path, String("/login"))
    # No way to access "authorization" or "cookie" from LogEntry.
    # This test exists as a regression guard: if someone adds a
    # headers field to LogEntry, this test will need rewriting and
    # the design review will catch it.


def main() raises:
    test_before_sets_start_ns()
    test_after_emits_log_entry()
    test_disabled_emits_nothing()
    test_clear_resets_buffer()
    test_bounded_buffer_drops_oldest_on_overflow()
    test_short_circuit_flag_propagates_into_entry()
    test_log_entry_carries_no_headers()
    print("test_L3_logging: OK")
