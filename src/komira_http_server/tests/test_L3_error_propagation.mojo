# =============================================================================
# tests/test_L3_error_propagation.mojo
# =============================================================================
#
# error propagation contract
# (L3: "middleware MAY raise; the error
# propagates UP the chain, gets handled by ErrorMappingMiddleware").
#
# Coverage:
#   * User middleware raises from before() — chain catches → 500 sanitized
#   * Response body is STATIC (no Error message echo)
#   * outcome.short_circuited == True on error path
#   * LoggingMiddleware after-chain STILL records the 500 entry
#   * ErrorMappingMiddleware.diagnostic_log captures the error for ops
#   * Chain without ErrorMappingMiddleware falls back to HttpResponse.internal_error()
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.middleware import (
    ErrorMappingMiddleware,
    LoggingMiddleware,
    Middleware,
    MiddlewareChain,
    RequestContext,
    TracingMiddleware,
)


# -----------------------------------------------------------------------------
# Sample user middleware that always raises from before().
# -----------------------------------------------------------------------------


@fieldwise_init
struct RaisingMiddleware(Middleware, Movable, Deinitable):
    """User middleware that always raises from before().

    Proves the chain's error-propagation contract: an uncaught raise
    from any layer propagates up; ErrorMappingMiddleware catches it
    and emits a 500 with sanitized body.
    """

    var calls_before: Int

    @staticmethod
    def new() -> RaisingMiddleware:
        return RaisingMiddleware(calls_before=0)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        self.calls_before = self.calls_before + 1
        raise Error("simulated handler error: <script>pwn</script>")
        # Unreachable, but the type system needs a return.
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


def _make_get_request(path: String) -> HttpRequest:
    return HttpRequest(HttpMethod.get(), path)


def _canned_200() -> HttpResponse:
    return HttpResponse.ok(String("hello"))


def test_error_from_user_mw_maps_to_500() raises:
    """User middleware raise → chain catches → 500 response."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/handler"))
    var raising = RaisingMiddleware.new()
    var outcome = chain.run_with_user_mw[RaisingMiddleware](
        req^, _canned_200(), raising
    )
    assert_equal(Int(outcome.response.status), 500)
    assert_true(outcome.short_circuited)


def test_error_response_body_is_static() raises:
    """The 500 body's human text is STATIC — it NEVER echoes the Error
    message.

    the body is now the attributed
    envelope `{"error":{"code","message","incidentId"}}` instead of bare
    `text/plain`. THE INVARIANT THIS TEST EXISTS FOR IS UNCHANGED and is
    asserted below — no part of the raise text reaches the wire. The exact
    literal equality was dropped because the envelope carries a per-request
    incident id, which differs on every run by construction; the static
    `message` is asserted by containment instead."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/handler"))
    var raising = RaisingMiddleware.new()
    var outcome = chain.run_with_user_mw[RaisingMiddleware](
        req^, _canned_200(), raising
    )
    var body = String("")
    var i = 0
    while i < len(outcome.response.body):
        body = body + chr(Int(outcome.response.body[i]))
        i = i + 1
    assert_true(
        _contains_substr(body, String('"message":"Internal Server Error"'))
    )
    # XSS payload from the Error message MUST NOT appear in the body.
    assert_false(_contains_substr(body, String("<script>")))
    assert_false(_contains_substr(body, String("pwn")))


def test_after_chain_still_runs_on_error() raises:
    """LoggingMiddleware.after STILL emits a LogEntry on the 500 path
    (best-effort after-chain execution from the error branch)."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/handler"))
    var raising = RaisingMiddleware.new()
    var _outcome = chain.run_with_user_mw[RaisingMiddleware](
        req^, _canned_200(), raising
    )
    ref logging_opt = chain.logging_ref()
    assert_true(Bool(logging_opt))
    ref lg = logging_opt.value()
    assert_equal(lg.entries_len(), 1)
    var entry = lg.entry(0)
    assert_equal(Int(entry.status), 500)
    assert_true(entry.short_circuit)


def test_error_mapper_captures_diagnostic_log() raises:
    """ErrorMappingMiddleware.diagnostic_log records the Error
    for server-side observability — NEVER surfaced to client."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/handler"))
    var raising = RaisingMiddleware.new()
    var _outcome = chain.run_with_user_mw[RaisingMiddleware](
        req^, _canned_200(), raising
    )
    ref em_opt = chain.error_mapper_ref()
    assert_true(Bool(em_opt))
    ref em = em_opt.value()
    assert_equal(em.diagnostic_log_len(), 1)
    var entry = em.diagnostic_log_entry(0)
    # Diagnostic log contains the Error text (for operator triage).
    assert_true(_contains_substr(entry, String("simulated handler error")))


def test_chain_without_error_mapper_still_attributes() raises:
    """A chain WITHOUT ErrorMappingMiddleware still produces a 500 on raise —
    and ATTRIBUTED one.

    ⚠ THIS ARM MUST NOT ANSWER `HttpResponse.internal_error()`: a 500 with
    `content-length: 0` and the cause discarded. That is the WORST branch to
    leave undiagnosable, because it fires exactly when a server was assembled
    without its error plumbing — the operator has no mapper to inspect either.
    It reports through the same `report_fault` path."""
    var chain = MiddlewareChain()
    # No error_mapper, no other middlewares.
    var req = _make_get_request(String("/x"))
    var raising = RaisingMiddleware.new()
    var outcome = chain.run_with_user_mw[RaisingMiddleware](
        req^, _canned_200(), raising
    )
    assert_equal(Int(outcome.response.status), 500)
    assert_true(outcome.short_circuited)
    assert_true(len(outcome.response.body) > 0)
    assert_true(
        outcome.response.headers.__contains__(String("x-incident-id")),
        String("the mapper-less fallback issued a 500 with no incident id"),
    )


# -----------------------------------------------------------------------------


def _contains_substr(haystack: String, needle: String) -> Bool:
    var hbytes = haystack.as_bytes()
    var nbytes = needle.as_bytes()
    var hn = len(hbytes)
    var nn = len(nbytes)
    if nn == 0:
        return True
    if nn > hn:
        return False
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if hbytes[i + j] != nbytes[j]:
                matched = False
                break
            j = j + 1
        if matched:
            return True
        i = i + 1
    return False


def main() raises:
    test_error_from_user_mw_maps_to_500()
    test_error_response_body_is_static()
    test_after_chain_still_runs_on_error()
    test_error_mapper_captures_diagnostic_log()
    test_chain_without_error_mapper_still_attributes()
    print("test_L3_error_propagation: OK")
