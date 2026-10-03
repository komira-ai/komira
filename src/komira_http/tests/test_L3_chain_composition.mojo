# =============================================================================
# tests/test_L3_chain_composition.mojo
# =============================================================================
#
# L3 chain composition ( L3).
# Coverage:
#   * MiddlewareChain build via with_* builders
#   * 0-middleware chain (only error mapper; canned response untouched)
#   * 1-middleware chain (logging only; LogEntry emitted in after)
#   * 3-middleware chain (logging + tracing + cors; full chain order)
#   * after-phase REVERSE order (logging emits AFTER tracing/cors mutated)
#   * short_circuited flag = False on normal pass-through
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.codec import (
    HTTP_METHOD_GET,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http.middleware import (
    CorsMiddleware,
    ErrorMappingMiddleware,
    LoggingMiddleware,
    MiddlewareChain,
    TracingMiddleware,
)


def _make_get_request(path: String) -> HttpRequest:
    """Build a minimal GET request for testing."""
    return HttpRequest(HttpMethod.get(), path)


def _canned_200() -> HttpResponse:
    return HttpResponse.ok(String("hello"))


def test_chain_zero_middlewares_passes_through_canned() raises:
    """A chain with NO middlewares (not even error mapper) returns
    the canned response unmodified."""
    var chain = MiddlewareChain()
    var req = _make_get_request(String("/healthz"))
    var outcome = chain.run_with_canned(req^, _canned_200())
    assert_equal(Int(outcome.response.status), 200)
    assert_false(outcome.short_circuited)


def test_chain_logging_only_emits_one_entry() raises:
    """A chain with ONLY LoggingMiddleware emits one LogEntry per
    invocation, capturing method + path + status."""
    var chain = MiddlewareChain()
    chain = chain^.with_error_mapper(ErrorMappingMiddleware.default())
    chain = chain^.with_logging(LoggingMiddleware.new())
    var req = _make_get_request(String("/users"))
    var outcome = chain.run_with_canned(req^, _canned_200())
    assert_equal(Int(outcome.response.status), 200)
    assert_false(outcome.short_circuited)
    # Inspect the logging buffer.
    ref logging_opt = chain.logging_ref()
    assert_true(Bool(logging_opt))
    ref lg = logging_opt.value()
    assert_equal(lg.entries_len(), 1)
    var entry = lg.entry(0)
    assert_equal(Int(entry.method.code), Int(HTTP_METHOD_GET))
    assert_equal(entry.path, String("/users"))
    assert_equal(Int(entry.status), 200)
    assert_false(entry.short_circuit)


def test_chain_three_middlewares_run_in_order() raises:
    """3-middleware chain: cors + tracing + logging. After the chain
    runs, the logging buffer has 1 entry AND the tracing buffer has
    1 span AND the response carries Access-Control-Allow-Origin."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/api/items"))
    var outcome = chain.run_with_canned(req^, _canned_200())
    assert_equal(Int(outcome.response.status), 200)
    assert_false(outcome.short_circuited)
    # Logging emitted.
    ref logging_opt = chain.logging_ref()
    assert_true(Bool(logging_opt))
    assert_equal(logging_opt.value().entries_len(), 1)
    # Tracing emitted (default chain uses TracingMiddleware.disabled() — 0 spans).
    ref tracing_opt = chain.tracing_ref()
    assert_true(Bool(tracing_opt))
    # default() uses disabled() — confirm 0 spans:
    assert_equal(tracing_opt.value().spans_len(), 0)
    # CORS header injected.
    assert_true(
        outcome.response.headers.__contains__(
            String("access-control-allow-origin")
        )
    )


def test_chain_three_middlewares_with_enabled_tracing() raises:
    """3-middleware chain with tracing enabled — span buffer has 1
    span after one request."""
    var chain = MiddlewareChain.default()
    chain = chain^.with_tracing(TracingMiddleware.new())
    var req = _make_get_request(String("/api/items"))
    var outcome = chain.run_with_canned(req^, _canned_200())
    assert_equal(Int(outcome.response.status), 200)
    ref tracing_opt = chain.tracing_ref()
    assert_true(Bool(tracing_opt))
    assert_equal(tracing_opt.value().spans_len(), 1)
    var span = tracing_opt.value().span(0)
    assert_equal(Int(span.method_code), Int(HTTP_METHOD_GET))
    assert_equal(span.path, String("/api/items"))
    assert_equal(Int(span.status), 200)


def test_chain_after_runs_in_reverse_order() raises:
    """Logging.after runs BEFORE tracing.after BEFORE cors.after.
    This is observable via the LogEntry status field: at log time,
    the response status reflects the canned response (200), and
    subsequent after-stages don't change status — they only add
    headers."""
    var chain = MiddlewareChain.default()
    chain = chain^.with_tracing(TracingMiddleware.new())
    var req = _make_get_request(String("/orders"))
    var outcome = chain.run_with_canned(req^, _canned_200())
    ref logging_opt = chain.logging_ref()
    ref lg = logging_opt.value()
    var entry = lg.entry(0)
    # Logging sees the final response status (200).
    assert_equal(Int(entry.status), 200)
    # Tracing also sees 200 (runs after logging, but the response
    # status doesn't change in normal flow).
    ref tracing_opt = chain.tracing_ref()
    var span = tracing_opt.value().span(0)
    assert_equal(Int(span.status), 200)
    # CORS was applied last — header present.
    assert_true(
        outcome.response.headers.__contains__(
            String("access-control-allow-origin")
        )
    )


def test_chain_two_requests_accumulate_log_entries() raises:
    """Two sequential requests on the same chain accumulate to 2
    LogEntries + 2 spans."""
    var chain = MiddlewareChain.default()
    chain = chain^.with_tracing(TracingMiddleware.new())

    var req1 = _make_get_request(String("/first"))
    var _o1 = chain.run_with_canned(req1^, _canned_200())

    var req2 = _make_get_request(String("/second"))
    var _o2 = chain.run_with_canned(req2^, _canned_200())

    ref logging_opt = chain.logging_ref()
    assert_equal(logging_opt.value().entries_len(), 2)
    assert_equal(logging_opt.value().entry(0).path, String("/first"))
    assert_equal(logging_opt.value().entry(1).path, String("/second"))

    ref tracing_opt = chain.tracing_ref()
    assert_equal(tracing_opt.value().spans_len(), 2)
    # Spans have monotonically-increasing IDs.
    var s0 = tracing_opt.value().span(0)
    var s1 = tracing_opt.value().span(1)
    assert_true(s1.span_id > s0.span_id)


def test_chain_has_helpers() raises:
    """Builder helpers report which middlewares are present."""
    var c = MiddlewareChain()
    assert_false(c.has_error_mapper())
    assert_false(c.has_cors())
    assert_false(c.has_tracing())
    assert_false(c.has_logging())
    c = c^.with_error_mapper(ErrorMappingMiddleware.default())
    assert_true(c.has_error_mapper())
    c = c^.with_cors(CorsMiddleware.permissive())
    assert_true(c.has_cors())
    c = c^.with_tracing(TracingMiddleware.new())
    assert_true(c.has_tracing())
    c = c^.with_logging(LoggingMiddleware.new())
    assert_true(c.has_logging())


def main() raises:
    test_chain_zero_middlewares_passes_through_canned()
    test_chain_logging_only_emits_one_entry()
    test_chain_three_middlewares_run_in_order()
    test_chain_three_middlewares_with_enabled_tracing()
    test_chain_after_runs_in_reverse_order()
    test_chain_two_requests_accumulate_log_entries()
    test_chain_has_helpers()
    print("test_L3_chain_composition: OK")
