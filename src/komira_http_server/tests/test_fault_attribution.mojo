# =============================================================================
# tests/test_fault_attribution.mojo
# =============================================================================
#
# THE FALSIFIER for "a 500 names its own cause".
#
# ⚠ IT FAILS IN BOTH DIRECTIONS, AND THAT IS THE POINT. A one-direction test
# here could not distinguish *made faults attributable* from *rewrote every 5xx
# into a generic fault envelope*, which would silently erase the deliberate
# fail-closed refusals a `503` carries: a WORKING-AS-DESIGNED 503 then reads
# as a defect because a refusal and a fault are byte-indistinguishable.
#
#   DIRECTION 1 — A FAULT MUST BE ATTRIBUTABLE.
#     A raise that reaches the boundary must answer a response carrying a
#     NON-EMPTY cause code AND a NON-EMPTY incident id, correlated between the
#     body and the `x-incident-id` header.
#     RED when: the boundary answers `HttpResponse.internal_error()` (the
#     older behaviour — 500 with `content-length: 0`), or drops the
#     code, or drops the incident id, or lets the two halves disagree.
#
#   DIRECTION 2 — A REFUSAL MUST NOT BE LAUNDERED INTO A FAULT.
#     A deliberate refusal the dispatcher RETURNS (its own status, its own
#     code, its own operator-actionable text) must reach the wire UNCHANGED, on
#     the IDENTICAL chain configuration that renders a fault as
#     `internal.unattributed`.
#     RED when: the boundary stamps or rewrites responses it did not create —
#     e.g. the tempting "map every 5xx into the fault envelope" implementation,
#     which would guarantee direction 1 and destroy the refusal's meaning.
#
# `test_fault_and_refusal_on_the_identical_chain` asserts BOTH on ONE chain
# instance so the pair cannot drift apart into two tests that are each edited
# to match a different implementation.
#
# WHY THE BOUNDARY AND NOT A ROUTE: the mechanism under test lives at the
# middleware/transport fault boundary, so that is the layer the assertions
# name. A route-level test would pass a mutation of the boundary as long as
# some other layer happened to answer: a mutation proof must target the layer
# the assertions name.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.middleware import (
    FAULT_CODE_TRANSPORT,
    FAULT_CODE_UNATTRIBUTED,
    FAULT_SOURCE_RAISE,
    FAULT_SOURCE_RESPONSE,
    error_response_log_line,
    observe_error_response,
    ErrorMappingMiddleware,
    Middleware,
    MiddlewareChain,
    RequestContext,
    fault_envelope,
    fault_log_line,
    new_incident_id,
    report_fault,
)


# -----------------------------------------------------------------------------
# The two middlewares: one FAULTS (raises), one REFUSES (returns).
# The distinction is the whole subject of this file.
# -----------------------------------------------------------------------------

# The operator-actionable sentence a real refusal carries.
comptime _REFUSAL_CODE: String = "secrets_unwired"
comptime _REFUSAL_TEXT: String = (
    "settings: durable secret-read backend not configured (wire"
    " the secret-read seam + the compute-env assume-role seam in the binary)"
)

# The raise text a FAULT carries. Contains an injection payload so the
# no-echo invariant is tested against something that would be visible if it
# leaked.
comptime _FAULT_TEXT: String = (
    "firestore: index missing for collection account_secrets"
    " <script>pwn</script>"
)


@fieldwise_init
struct FaultingMiddleware(Middleware, Movable, Deinitable):
    """RAISES — an unexpected fault reaching the boundary."""

    var calls: Int

    @staticmethod
    def new() -> FaultingMiddleware:
        return FaultingMiddleware(calls=0)

    def before(
        mut self, mut req: HttpRequest, mut ctx: RequestContext
    ) raises -> Optional[HttpResponse]:
        self.calls = self.calls + 1
        raise Error(_FAULT_TEXT)
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


@fieldwise_init
struct RefusingMiddleware(Middleware, Movable, Deinitable):
    """RETURNS a deliberate fail-closed refusal — a 503 it chose, with its own
    code and its own operator-actionable text. It does NOT raise, so it never
    reaches the fault boundary, and the boundary must leave it alone."""

    var calls: Int

    @staticmethod
    def new() -> RefusingMiddleware:
        return RefusingMiddleware(calls=0)

    def before(
        mut self, mut req: HttpRequest, mut ctx: RequestContext
    ) raises -> Optional[HttpResponse]:
        self.calls = self.calls + 1
        var body = String('{"error":{"code":"')
        body += _REFUSAL_CODE
        body += String('","message":"')
        body += _REFUSAL_TEXT
        body += String('"}}')
        var r = HttpResponse(status=Int32(503))
        r.headers[String("content-type")] = String("application/json")
        var b = body.as_bytes()
        var n = len(b)
        var i = 0
        while i < n:
            r.body.append(b[i])
            i = i + 1
        r.headers[String("content-length")] = String(n)
        return Optional[HttpResponse](r^)

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


# =============================================================================
# §1 — THE PAIRED GATE. Both directions, one chain configuration.
# =============================================================================


def test_fault_and_refusal_on_the_identical_chain() raises:
    """⭐ THE HEADLINE GATE. On ONE `MiddlewareChain.default()` configuration:

      (1) a RAISE answers an ATTRIBUTED 500 — non-empty code, non-empty
          incident id, header/body correlation; and
      (2) a deliberate 503 REFUSAL reaches the wire UNCHANGED — same status,
          same code, same operator text, and NOT stamped by the boundary.

    Asserting (1) alone would be satisfied by an implementation that rewrites
    every 5xx; asserting (2) alone would be satisfied by doing nothing at all.
    Only the pair is evidence."""

    # ---- (1) THE FAULT DIRECTION -------------------------------------------
    var chain = MiddlewareChain.default()
    var faulting = FaultingMiddleware.new()
    var fault_outcome = chain.run_with_user_mw[FaultingMiddleware](
        HttpRequest(HttpMethod.get(), String("/orgs/o-1/settings")),
        HttpResponse.ok(String("unreached")),
        faulting,
    )
    var fbody = _body_str(fault_outcome.response)

    assert_equal(Int(fault_outcome.response.status), 500)

    # A cause code is PRESENT and NON-EMPTY. The non-emptiness is the
    # invariant; the literal is the current vocabulary. Both are asserted so a
    # rename is a deliberate edit and an ERASURE is a failure.
    var fcode = _json_field(fbody, String("code"))
    assert_true(
        fcode.byte_length() > 0,
        String("a 500 was issued with NO cause code — body: ") + fbody,
    )
    assert_equal(fcode, FAULT_CODE_UNATTRIBUTED)

    # An incident id is PRESENT and NON-EMPTY, in the body AND the header, and
    # the two AGREE. Correlation that disagrees is worse than none: it sends an
    # operator to the wrong log line.
    var fincident = _json_field(fbody, String("incidentId"))
    assert_true(
        fincident.byte_length() > 0,
        String("a 500 was issued with NO incident id — body: ") + fbody,
    )
    assert_true(
        fault_outcome.response.headers.__contains__(String("x-incident-id")),
        String("a 500 was issued with no x-incident-id header"),
    )
    assert_equal(
        fault_outcome.response.headers[String("x-incident-id")], fincident
    )

    # The disclosure invariant SURVIVES the change: the raise text is still
    # not on the wire. Making faults diagnosable must not have made them
    # chatty.
    assert_false(
        _contains(fbody, String("account_secrets")),
        String("the raise text leaked into the response body"),
    )
    assert_false(_contains(fbody, String("<script>")))

    # ---- (2) THE REFUSAL DIRECTION, SAME CHAIN -----------------------------
    var refusing = RefusingMiddleware.new()
    var refusal_outcome = chain.run_with_user_mw[RefusingMiddleware](
        HttpRequest(HttpMethod.get(), String("/orgs/o-1/settings")),
        HttpResponse.ok(String("unreached")),
        refusing,
    )
    var rbody = _body_str(refusal_outcome.response)

    # STATUS preserved — a refusal is not a fault.
    assert_equal(
        Int(refusal_outcome.response.status),
        503,
        String("a deliberate 503 refusal was rewritten to another status"),
    )
    # CODE preserved — verbatim, not replaced by the fault vocabulary.
    assert_equal(_json_field(rbody, String("code")), _REFUSAL_CODE)
    assert_false(
        _contains(rbody, FAULT_CODE_UNATTRIBUTED),
        String("a deliberate refusal was laundered into a fault envelope"),
    )
    assert_false(_contains(rbody, FAULT_CODE_TRANSPORT))
    # OPERATOR TEXT preserved verbatim — the actionable half. A refusal whose
    # remediation sentence is replaced by "Internal Server Error" is a refusal
    # nobody can act on.
    assert_true(
        _contains(rbody, _REFUSAL_TEXT),
        String("the refusal lost its operator-actionable text: ") + rbody,
    )
    # NOT STAMPED. The boundary did not create this response and must not
    # decorate it. This is the assertion that a "stamp every 5xx"
    # implementation fails.
    assert_false(
        refusal_outcome.response.headers.__contains__(String("x-incident-id")),
        String("the boundary stamped a response it did not create"),
    )


# =============================================================================
# §2 — the unit-level invariants of the attribution primitives.
# =============================================================================


def test_fault_log_line_carries_the_raw_cause() raises:
    """THE OTHER HALF OF DIRECTION 1. The response deliberately does NOT carry
    the raise text, so the mechanism is only honest if the log line DOES —
    otherwise the cause is still nowhere, just with nicer packaging."""
    var line = fault_log_line(
        String("abc123"),
        FAULT_CODE_UNATTRIBUTED,
        Int32(500),
        String("GET"),
        String("/orgs/o-1/settings"),
        String(_FAULT_TEXT),
        3,
        String("TRACEID123/9;o=1"),
        String(""),
    )
    # STRUCTURED, not key=value free text. Free text lands in `textPayload` at
    # severity DEFAULT — invisible to `severity>=ERROR` and unjoinable to the
    # request entry. This is the measured requirement, not a style choice.
    assert_true(_contains(line, String('"severity":"ERROR"')))
    assert_true(_contains(line, String('"incident_id":"abc123"')))
    assert_true(_contains(line, String('"cause_code":"') + FAULT_CODE_UNATTRIBUTED))
    assert_true(_contains(line, String('"status":500')))
    assert_true(_contains(line, String('"method":"GET"')))
    assert_true(_contains(line, String('"route":"/orgs/o-1/settings"')))
    # The trace join — the field that turns two log streams into one.
    assert_true(_contains(line, String('"trace_id":"TRACEID123"')))
    # THE CAUSE ITSELF. If this assertion is the one that breaks, the 500 is
    # undiagnosable again no matter what the envelope says.
    assert_true(
        _contains(line, String("account_secrets")),
        String("the raw cause is not in the log line: ") + line,
    )
    # The boot-time wiring verdict rides the line — the join between "the boot
    # log said UNWIRED -> secrets" and "this request 500ed", which
    # otherwise have no meeting point.
    assert_true(_contains(line, String('"wiring_unwired":3')))


def test_fault_log_line_cannot_be_used_to_forge_a_second_line() raises:
    """Log injection: the detail is the one field carrying client-influenced
    bytes. A raw newline there would let a raise fabricate an additional log
    record, so CR/LF/TAB fold to a space."""
    var line = fault_log_line(
        String("i1"),
        FAULT_CODE_UNATTRIBUTED,
        Int32(500),
        String("GET"),
        String("/x"),
        String("real cause\nkomira-http: FAULT incident=forged code=ok"),
        0,
        String(""),
        String(""),
    )
    assert_false(
        _contains(line, String("\n")),
        String("a newline in the raise text survived into the log line"),
    )
    assert_true(_contains(line, String("real cause")))


def test_log_line_redacts_credentials_and_user_email() raises:
    """THE LOG IS NOT A FREE PASS. The disclosure split sends the RAW cause to
    stdout, and it would be easy to read that as "logs are operator-only, so
    anything goes". They are not: a log line is retained, replicated and read
    by a wider audience than a response body, so "the client already saw it" is
    not on its own a licence to log it.

    Both shapes below are REACHABLE on this service, not speculative hardening:
    a transport that echoes the request it failed to make carries the bearer
    token, and a uniqueness violation from a store quotes the offending value."""
    var line = fault_log_line(
        String("i1"),
        FAULT_CODE_UNATTRIBUTED,
        Int32(500),
        String("POST"),
        String("/orgs/o-1/settings"),
        String(
            "upstream rejected: Authorization: Bearer eyJhbGciOiJIUzI1NiJ9"
            " while inserting Key (email)=(alice@users.example)"
        ),
        0,
        String(""),
        String(""),
    )
    assert_false(
        _contains(line, String("eyJhbGciOiJIUzI1NiJ9")),
        String("a bearer token reached the log line: ") + line,
    )
    assert_false(
        _contains(line, String("alice@users.example")),
        String("a user email address reached the log line: ") + line,
    )
    # The line is still USEFUL — redaction that erases the diagnosis is just a
    # slower way of having no log.
    assert_true(_contains(line, String("upstream rejected")))


def test_returned_5xx_is_observed_but_never_rewritten() raises:
    """ARM 2. A deliberate refusal must be
    VISIBLE in logs and UNCHANGED on the wire — those are two claims and this
    asserts both, because each alone permits the wrong fix.

    A 503 that names the configuration an operator must set is correct. It
    RETURNS rather than raises, so a diagnostic hung off the `except` arm
    misses it, and the silence reads as a defect. Logging it is the answer. REWRITING
    it — "give it an incident id too" — would destroy the operator text that
    makes it actionable, which is why `observe_error_response` returns nothing
    and takes the response by `ref`."""
    var refusal = HttpResponse(status=Int32(503))
    refusal.headers[String("content-type")] = String("application/json")
    var body = String('{"error":{"code":"') + _REFUSAL_CODE
    body += String('","message":"') + _REFUSAL_TEXT + String('"}}')
    var b = body.as_bytes()
    for i in range(len(b)):
        refusal.body.append(b[i])
    refusal.headers[String("content-length")] = String(len(b))

    var status_before = Int(refusal.status)
    var len_before = len(refusal.body)

    observe_error_response(
        refusal,
        String("POST"),
        String("/projects/p-1/items"),
        String(""),
        String(""),
    )

    # UNCHANGED — observing is not rewriting.
    assert_equal(Int(refusal.status), status_before)
    assert_equal(len(refusal.body), len_before)
    assert_false(
        refusal.headers.__contains__(String("x-incident-id")),
        String("observing a returned 5xx stamped it"),
    )

    # OBSERVED — and the line says WHICH arm it came from.
    var line = error_response_log_line(
        Int32(503),
        String("POST"),
        String("/projects/p-1/items"),
        body,
        String(""),
        String(""),
    )
    assert_true(_contains(line, String('"severity":"ERROR"')))
    assert_true(_contains(line, String('"status":503')))
    assert_true(_contains(line, String('"source":"') + FAULT_SOURCE_RESPONSE))
    assert_true(
        _contains(line, _REFUSAL_CODE),
        String("the refusal's own code is missing from its log line: ") + line,
    )


def test_the_two_arms_are_distinguishable_in_the_log() raises:
    """⭐ THE SEPARATION, ASSERTED ON THE LOG SIDE. Both arms emit at severity
    ERROR under one schema so a single query finds both — which is only safe if
    `source` tells them apart. If the two arms ever render identically, an
    operator is back to guessing whether a 5xx was a decision or an accident,
    which is the whole defect class."""
    var raise_line = fault_log_line(
        String("i1"),
        FAULT_CODE_UNATTRIBUTED,
        Int32(500),
        String("GET"),
        String("/orgs/o-1/settings"),
        String("boom"),
        0,
        String(""),
        String(""),
    )
    var returned_line = error_response_log_line(
        Int32(503),
        String("POST"),
        String("/projects/p-1/items"),
        String("deliberate refusal"),
        String(""),
        String(""),
    )
    assert_true(_contains(raise_line, String('"source":"') + FAULT_SOURCE_RAISE))
    assert_true(
        _contains(returned_line, String('"source":"') + FAULT_SOURCE_RESPONSE)
    )
    # And they are NOT the same string in the field that matters.
    assert_false(_contains(raise_line, String('"source":"') + FAULT_SOURCE_RESPONSE))
    assert_false(_contains(returned_line, String('"source":"') + FAULT_SOURCE_RAISE))
    # A raise carries an incident id; a returned refusal does not need one —
    # it already has its own code and text.
    assert_true(_contains(raise_line, String('"incident_id"')))


def test_incident_ids_are_opaque_and_nonempty() raises:
    """An id that is empty, or that discloses request content, is not usable
    as a correlation token."""
    var a = new_incident_id()
    assert_equal(a.byte_length(), 16)
    # Hex only — nothing structured, nothing account-derived.
    var b = a.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        var is_digit = c >= UInt8(48) and c <= UInt8(57)
        var is_hex_alpha = c >= UInt8(97) and c <= UInt8(102)
        assert_true(is_digit or is_hex_alpha)
        i = i + 1


def test_envelope_parses_like_a_refusal_envelope() raises:
    """A fault and a refusal must PARSE THE SAME WAY and be told apart by
    `code`, not by body shape. A client that special-cases the fault path is a
    client that breaks the next time the fault path changes."""
    var r = fault_envelope(
        Int32(500),
        FAULT_CODE_UNATTRIBUTED,
        String("deadbeefdeadbeef"),
        String("Internal Server Error"),
    )
    assert_equal(r.headers[String("content-type")], String("application/json"))
    var body = _body_str(r)
    assert_true(_contains(body, String('{"error":{')))
    assert_equal(_json_field(body, String("code")), FAULT_CODE_UNATTRIBUTED)
    assert_equal(
        _json_field(body, String("message")), String("Internal Server Error")
    )
    assert_equal(
        _json_field(body, String("incidentId")), String("deadbeefdeadbeef")
    )
    # content-length agrees with the body actually emitted.
    assert_equal(r.headers[String("content-length")], String(len(r.body)))


def test_report_fault_correlates_header_and_body() raises:
    """`report_fault` is the ONE composite entry point every boundary uses; its
    contract is that the id it logs is the id it returns."""
    var r = report_fault(
        Error("store unavailable"),
        Int32(500),
        FAULT_CODE_TRANSPORT,
        String("POST"),
        String("/orgs/o-1/settings"),
        String("Internal Server Error"),
        0,
        String(""),
        String(""),
    )
    var body = _body_str(r)
    var incident = _json_field(body, String("incidentId"))
    assert_true(incident.byte_length() > 0)
    assert_equal(r.headers[String("x-incident-id")], incident)
    assert_equal(_json_field(body, String("code")), FAULT_CODE_TRANSPORT)
    assert_false(_contains(body, String("store unavailable")))


def test_trace_is_qualified_only_with_a_configured_project() raises:
    """The canonical trace field is `projects/<project>/traces/<trace>`, and
    the project comes from the caller. With one, both lines carry it; without
    one, the field is absent and the plain `trace_id` is still written."""
    var with_project = fault_log_line(
        String("i1"),
        FAULT_CODE_UNATTRIBUTED,
        Int32(500),
        String("GET"),
        String("/x"),
        String("boom"),
        0,
        String("TRACEID123/9;o=1"),
        String("p-1"),
    )
    assert_true(
        _contains(
            with_project,
            String('"logging.googleapis.com/trace":"projects/p-1/traces/TRACEID123"'),
        ),
        String("a configured project did not qualify the trace: ") + with_project,
    )
    var returned = error_response_log_line(
        Int32(503),
        String("GET"),
        String("/x"),
        String("refused"),
        String("TRACEID123/9;o=1"),
        String("p-1"),
    )
    assert_true(
        _contains(returned, String("projects/p-1/traces/TRACEID123")),
        String("the returned-5xx line did not qualify the trace: ") + returned,
    )
    var without = fault_log_line(
        String("i1"),
        FAULT_CODE_UNATTRIBUTED,
        Int32(500),
        String("GET"),
        String("/x"),
        String("boom"),
        0,
        String("TRACEID123/9;o=1"),
        String(""),
    )
    assert_false(
        _contains(without, String("logging.googleapis.com/trace")),
        String("an empty project still produced the canonical field: ") + without,
    )
    assert_true(_contains(without, String('"trace_id":"TRACEID123"')))


def test_error_mapper_reports_the_wiring_count() raises:
    """`with_wiring_report` is the join: a binary that knows it booted with
    unwired capabilities must say so on every fault line. A mapper that
    accepted the count and dropped it would be the accept-and-ignore defect
    class, so the count must be observable in the line the mapper builds."""
    var em2 = ErrorMappingMiddleware.default().with_wiring_report(7)
    assert_equal(em2.wiring_unwired, 7)
    # And the default is 0 — a server that never calls it is unchanged.
    var em3 = ErrorMappingMiddleware.default()
    assert_equal(em3.wiring_unwired, 0)
    _ = em2^
    _ = em3^


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _body_str(ref resp: HttpResponse) -> String:
    var s = String("")
    var i = 0
    while i < len(resp.body):
        s += chr(Int(resp.body[i]))
        i = i + 1
    return s^


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    var hn = len(h)
    var nn = len(n)
    if nn == 0:
        return True
    if nn > hn:
        return False
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if h[i + j] != n[j]:
                matched = False
                break
            j = j + 1
        if matched:
            return True
        i = i + 1
    return False


def _json_field(body: String, key: String) -> String:
    """Extract `"<key>":"<value>"` from a flat JSON error envelope. Deliberately
    tiny — this asserts on the wire bytes, so it must not share code with the
    emitter (a shared serializer would make the test agree with a broken
    emitter by construction). Returns "" when absent, which is what the
    non-emptiness assertions key on."""
    var pat = String('"') + key + String('":"')
    var h = body.as_bytes()
    var p = pat.as_bytes()
    var hn = len(h)
    var pn = len(p)
    var i = 0
    while i + pn <= hn:
        var matched = True
        var j = 0
        while j < pn:
            if h[i + j] != p[j]:
                matched = False
                break
            j = j + 1
        if matched:
            var out = String("")
            var k = i + pn
            while k < hn:
                if h[k] == UInt8(34):
                    return out^
                out += chr(Int(h[k]))
                k = k + 1
            return out^
        i = i + 1
    return String("")


def main() raises:
    test_fault_and_refusal_on_the_identical_chain()
    test_fault_log_line_carries_the_raw_cause()
    test_fault_log_line_cannot_be_used_to_forge_a_second_line()
    test_log_line_redacts_credentials_and_user_email()
    test_returned_5xx_is_observed_but_never_rewritten()
    test_the_two_arms_are_distinguishable_in_the_log()
    test_incident_ids_are_opaque_and_nonempty()
    test_envelope_parses_like_a_refusal_envelope()
    test_report_fault_correlates_header_and_body()
    test_trace_is_qualified_only_with_a_configured_project()
    test_error_mapper_reports_the_wiring_count()
    print("test_fault_attribution: OK")
