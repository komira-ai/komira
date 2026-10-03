# =============================================================================
# tests/test_L3_tracing.mojo
# =============================================================================
#
# TracingMiddleware unit tests
#
# Coverage:
#   * before() assigns ctx.span_id (monotonically increasing per request)
#   * after() emits TracingSpan with method/path/status/start_ns/end_ns
#   * disabled() emits no spans + leaves ctx.span_id at 0
#   * clear() resets the span buffer and the next-span counter
#   * Multiple requests get distinct span_ids (1, 2, 3, ...)
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.middleware import RequestContext, TracingMiddleware


def _make_request(method: HttpMethod, path: String) -> HttpRequest:
    return HttpRequest(method, path)


def test_before_assigns_span_id() raises:
    """TracingMiddleware.before() assigns a non-zero span_id to ctx."""
    var tr = TracingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    assert_equal(Int(ctx.span_id), 0)
    var resp_opt = tr.before(req, ctx)
    assert_false(Bool(resp_opt))  # Tracing never short-circuits.
    assert_true(ctx.span_id > UInt64(0))


def test_after_emits_span() raises:
    """After invocation: one TracingSpan recorded with status + method."""
    var tr = TracingMiddleware.new()
    var req = _make_request(HttpMethod.post(), String("/orders"))
    var ctx = RequestContext.new()
    _ = tr.before(req, ctx)
    var resp = HttpResponse(status=Int32(201))
    tr.after(req, resp, ctx)
    assert_equal(tr.spans_len(), 1)
    var s = tr.span(0)
    assert_equal(Int(s.method_code), Int(HTTP_METHOD_POST))
    assert_equal(s.path, String("/orders"))
    assert_equal(Int(s.status), 201)
    assert_equal(Int(s.span_id), Int(ctx.span_id))


def test_disabled_emits_nothing() raises:
    """TracingMiddleware.disabled() leaves ctx unchanged and emits no spans."""
    var tr = TracingMiddleware.disabled()
    var req = _make_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    _ = tr.before(req, ctx)
    assert_equal(Int(ctx.span_id), 0)  # span_id not assigned.
    var resp = HttpResponse(status=Int32(200))
    tr.after(req, resp, ctx)
    assert_equal(tr.spans_len(), 0)


def test_multiple_requests_monotonic_ids() raises:
    """Sequential requests produce span_ids 1, 2, 3."""
    var tr = TracingMiddleware.new()
    var resp = HttpResponse(status=Int32(200))
    var i = 0
    while i < 3:
        var req = _make_request(HttpMethod.get(), String("/p"))
        var ctx = RequestContext.new()
        _ = tr.before(req, ctx)
        tr.after(req, resp, ctx)
        i = i + 1
    assert_equal(tr.spans_len(), 3)
    assert_equal(Int(tr.span(0).span_id), 1)
    assert_equal(Int(tr.span(1).span_id), 2)
    assert_equal(Int(tr.span(2).span_id), 3)


def test_clear_resets_buffer_and_counter() raises:
    """clear() empties spans AND resets _next_span_id to 1."""
    var tr = TracingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    _ = tr.before(req, ctx)
    var resp = HttpResponse(status=Int32(200))
    tr.after(req, resp, ctx)
    assert_equal(tr.spans_len(), 1)
    tr.clear()
    assert_equal(tr.spans_len(), 0)
    # Next span_id is 1 again.
    var req2 = _make_request(HttpMethod.get(), String("/y"))
    var ctx2 = RequestContext.new()
    _ = tr.before(req2, ctx2)
    assert_equal(Int(ctx2.span_id), 1)


def test_after_without_before_no_span() raises:
    """Defensive: if after() is called without before() (ctx.span_id
    still 0), no span is recorded."""
    var tr = TracingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    # Skip before().
    var resp = HttpResponse(status=Int32(200))
    tr.after(req, resp, ctx)
    assert_equal(tr.spans_len(), 0)


def test_span_records_start_and_end() raises:
    """The TracingSpan carries non-zero start_ns and end_ns."""
    var tr = TracingMiddleware.new()
    var req = _make_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    _ = tr.before(req, ctx)
    var resp = HttpResponse(status=Int32(200))
    tr.after(req, resp, ctx)
    var s = tr.span(0)
    assert_true(s.start_ns > UInt64(0))
    assert_true(s.end_ns >= s.start_ns)


def main() raises:
    test_before_assigns_span_id()
    test_after_emits_span()
    test_disabled_emits_nothing()
    test_multiple_requests_monotonic_ids()
    test_clear_resets_buffer_and_counter()
    test_after_without_before_no_span()
    test_span_records_start_and_end()
    print("test_L3_tracing: OK")
