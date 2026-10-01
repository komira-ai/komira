# =============================================================================
# tests/test_L3_error_mapper.mojo
# =============================================================================
#
# ErrorMappingMiddleware unit tests
#
# Coverage:
#   * default() — 500 status + static body + sanitized response
#   * with_body() — user-replaced body still STATIC (no Error message echo)
#   * map_error() — diagnostic_log captures error for operator (NOT response)
#   * Response NEVER contains the Error message text
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.codec import HttpResponse, status_text
from komira_http.middleware import ErrorMappingMiddleware


def test_default_500_static_message() raises:
    """Default ErrorMappingMiddleware emits 500 with a static `message`.

    the body is the attributed JSON
    envelope, so the static text is one FIELD of it rather than the whole body.
    `connection: close` is asserted unchanged — the pre-attribution keep-alive
    behaviour had to survive."""
    var em = ErrorMappingMiddleware.default()
    var resp = em.map_error(Error("internal kaboom"))
    assert_equal(Int(resp.status), 500)
    var body = String("")
    var i = 0
    while i < len(resp.body):
        body = body + chr(Int(resp.body[i]))
        i = i + 1
    assert_true(
        _contains_substr(body, String('"message":"Internal Server Error"'))
    )
    # Connection: close on error.
    assert_true(resp.headers.__contains__(String("connection")))
    assert_equal(resp.headers[String("connection")], String("close"))


def test_default_no_client_input_echo() raises:
    """Critical: error response body does NOT echo the Error
    message — even when the Error contains attacker-controlled text
    that looks like an XSS / log-injection probe."""
    var em = ErrorMappingMiddleware.default()
    var attacker_message = Error(
        "<script>alert('pwn')</script> %0d%0aSet-Cookie: leak=evil"
    )
    var resp = em.map_error(attacker_message)
    # Body is STATIC — never contains the attacker bytes.
    var body = String("")
    var i = 0
    while i < len(resp.body):
        body = body + chr(Int(resp.body[i]))
        i = i + 1
    # Must not contain ANY part of the attacker payload.
    assert_false(_contains_substr(body, String("<script>")))
    assert_false(_contains_substr(body, String("alert")))
    assert_false(_contains_substr(body, String("Set-Cookie")))
    assert_false(_contains_substr(body, String("leak=evil")))


def test_with_body_user_override_still_static() raises:
    """User-provided text via with_body() is also static — and again does NOT
    include the Error message.

    `with_body` lost its `content_type` parameter. The
    envelope is always `application/json` now, so a content-type knob the
    emitter no longer honours would be an accepted-and-ignored parameter, a
    knob that silently does nothing. The parameter does not exist, and this
    test calls the constructor without it."""
    var em = ErrorMappingMiddleware.with_body(
        String("Service temporarily unavailable. Please try again."),
    )
    var resp = em.map_error(Error("attacker controlled"))
    var body = String("")
    var i = 0
    while i < len(resp.body):
        body = body + chr(Int(resp.body[i]))
        i = i + 1
    assert_true(
        _contains_substr(
            body,
            String(
                '"message":"Service temporarily unavailable. Please try'
                ' again."'
            ),
        )
    )
    assert_false(_contains_substr(body, String("attacker controlled")))
    assert_equal(
        resp.headers[String("content-type")],
        String("application/json"),
    )


def test_diagnostic_log_captures_error_for_operator() raises:
    """The diagnostic_log buffer is server-local — it DOES capture
    the Error message for operator observability. This is by design;
    the diagnostic_log is NEVER surfaced to the client."""
    var em = ErrorMappingMiddleware.default()
    _ = em.map_error(Error("boom-1"))
    _ = em.map_error(Error("boom-2"))
    assert_equal(em.diagnostic_log_len(), 2)
    var e0 = em.diagnostic_log_entry(0)
    var e1 = em.diagnostic_log_entry(1)
    # Each entry contains "status=500" and the message text.
    assert_true(_contains_substr(e0, String("status=500")))
    assert_true(_contains_substr(e0, String("boom-1")))
    assert_true(_contains_substr(e1, String("boom-2")))


def test_response_carries_content_length() raises:
    """500 response includes a Content-Length matching the body ACTUALLY
    emitted. Asserted against `len(resp.body)` rather than a hardcoded 21: the
    envelope carries a per-request incident id, so a constant would be a
    number this test would have to be re-edited to match — and a test edited
    to match the emitter cannot falsify the emitter."""
    var em = ErrorMappingMiddleware.default()
    var resp = em.map_error(Error("x"))
    assert_true(resp.headers.__contains__(String("content-length")))
    var cl = resp.headers[String("content-length")]
    assert_equal(cl, String(len(resp.body)))
    assert_true(len(resp.body) > 0)


# -----------------------------------------------------------------------------
# Small helper: substring containment.
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
    test_default_500_static_message()
    test_default_no_client_input_echo()
    test_with_body_user_override_still_static()
    test_diagnostic_log_captures_error_for_operator()
    test_response_carries_content_length()
    print("test_L3_error_mapper: OK")
