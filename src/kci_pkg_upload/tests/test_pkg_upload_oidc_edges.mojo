# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_oidc_edges.mojo — trusted
#   publishing's remaining refusals and shapes, over a scripted transport.
# =============================================================================
#
# ROWS
#   (1) `from_actions_env` with both handshake variables SET builds a
#       credential whose ID-token request goes to the variable's URL and
#       carries the variable's token as a Bearer;
#   (2) a request URL with no path (`https://host.test`) or no host
#       (`https:///path`) is refused at construction;
#   (3) the audience is percent-encoded into the ID-token query: RFC 3986
#       unreserved bytes as is, every other byte (space, `/`, `:`, each byte
#       of a non-ASCII character) as `%XX`, upper-case hex;
#   (4) a JWT whose payload is not base64url, not a JSON object, or carries
#       a claim that is not a string, is refused naming which;
#   (5) a Retry-After that is not delta-seconds (a word, digits then a
#       letter) is absent (-1): the backoff applies, nothing is parsed out
#       of it; surrounding spaces are ignored;
#   (6) the warehouse arm's every refusal: the audience request faults or
#       answers non-200 or names no audience; the token exchange faults or
#       answers non-200 (quoting the body, never the JWT); the ID-token
#       answer is not JSON, its `value` is not a string or absent; the mint
#       answer is not JSON or its `token` is not a string.
#
# Hermetic: ScriptedPkgTransport and komira_retry's RecordingSleeper; no
# network. Row (1) sets the two handshake variables in this test's own
# process, and sets them back to EMPTY before it returns.
# =============================================================================

from std.os import setenv
from std.testing import assert_equal, assert_raises, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_retry import RecordingSleeper
from komira_secret_store import SecretValue

from kci_pkg_upload.credential import SURFACE_PREFIX_DEV, SURFACE_PYPI_UPLOAD
from kci_pkg_upload.github_oidc_credential import (
    ACTIONS_ID_TOKEN_REQUEST_TOKEN,
    ACTIONS_ID_TOKEN_REQUEST_URL,
    GithubOidcCredential,
    decode_jwt_claims,
    id_token_verdict,
)
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _URL: String = "https://token.actions.example.invalid/_apis/idtoken?api-version=2.0"
comptime _REQ_TOKEN: String = "request-token-0123456789abcdef"
comptime _Cred = GithubOidcCredential[ScriptedPkgTransport, RecordingSleeper]


def _jwt_of(payload: String) -> String:
    var header = base64_url_encode_nopad(String('{"alg":"RS256","typ":"JWT"}').as_bytes())
    return (
        header
        + String(".")
        + base64_url_encode_nopad(payload.as_bytes())
        + String(".c2lnbmF0dXJlLW5vdC1jaGVja2Vk")
    )


def _jwt() -> String:
    return _jwt_of(String('{"repository":"example-org/example-repo","ref":"refs/heads/main"}'))


def _raw(status: Int, body: String) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(bytes_of(body))
    return r^


def _id_token_answer(jwt: String) -> PkgResponse:
    return _raw(200, String('{"count":1,"value":"') + jwt + String('"}'))


def _cred(var t: ScriptedPkgTransport, prefix_host: String, pypi_index: String, url: String = String(_URL)) raises -> _Cred:
    return _Cred(
        t^, RecordingSleeper(), url, SecretValue.from_string(String(_REQ_TOKEN)), prefix_host.copy(), pypi_index.copy()
    )


def test_from_actions_env_with_both_variables_set() raises:
    _ = setenv(String(ACTIONS_ID_TOKEN_REQUEST_URL), String("https://env.example.invalid/idtoken?v=1"), True)
    _ = setenv(String(ACTIONS_ID_TOKEN_REQUEST_TOKEN), String("env-request-token-0123456789"), True)
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt()))
    t.queue(_raw(200, String("pfx_minted_from_env_0123456789")))
    var cred = _Cred.from_actions_env(t^, RecordingSleeper(), String("prefix.dev"), String(""))
    _ = setenv(String(ACTIONS_ID_TOKEN_REQUEST_URL), String(""), True)
    _ = setenv(String(ACTIONS_ID_TOKEN_REQUEST_TOKEN), String(""), True)
    assert_equal(
        cred.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")),
        String("Bearer pfx_minted_from_env_0123456789"),
    )
    var idreq = cred.transport().call(0)
    assert_equal(idreq.host, String("env.example.invalid"))
    assert_equal(idreq.path, String("/idtoken?v=1&audience=prefix.dev"))
    assert_equal(idreq.header_value(String("Authorization")), String("Bearer env-request-token-0123456789"))
    print("  test_from_actions_env_with_both_variables_set: PASS")


def test_a_request_url_needs_a_host_and_a_path() raises:
    with assert_raises(contains="the ID-token request URL has no host or no path"):
        _ = _cred(ScriptedPkgTransport(), String("prefix.dev"), String(""), String("https://token.example.invalid"))
    with assert_raises(contains="the ID-token request URL has no host or no path"):
        _ = _cred(ScriptedPkgTransport(), String("prefix.dev"), String(""), String("https:///idtoken"))
    print("  test_a_request_url_needs_a_host_and_a_path: PASS")


def test_the_audience_is_percent_encoded() raises:
    var t = ScriptedPkgTransport()
    t.queue(_raw(200, String('{"audience": "a b/c:é~-._Z9"}')))
    t.queue(_id_token_answer(_jwt()))
    t.queue(_raw(200, String('{"token": "pypi-minted-0123456789"}')))
    var cred = _cred(t^, String(""), String("test.pypi.org"))
    _ = cred.authorization(SURFACE_PYPI_UPLOAD, String("test.pypi.org"))
    assert_equal(
        cred.transport().call(1).path,
        String("/_apis/idtoken?api-version=2.0&audience=a%20b%2Fc%3A%C3%A9~-._Z9"),
    )
    print("  test_the_audience_is_percent_encoded: PASS")


def test_malformed_jwt_payloads() raises:
    with assert_raises(contains="the ID token's payload is not base64url"):
        _ = decode_jwt_claims(String("aGVhZA.!!!.c2ln"))
    with assert_raises(contains="the ID token's payload is not an object"):
        _ = decode_jwt_claims(_jwt_of(String("[1]")))
    with assert_raises(contains="'repository' is not a string"):
        _ = decode_jwt_claims(_jwt_of(String('{"repository": 5}')))
    with assert_raises(contains="'environment' is not a string"):
        _ = decode_jwt_claims(_jwt_of(String('{"repository": "r", "environment": null}')))
    print("  test_malformed_jwt_payloads: PASS")


def _retry_after(v: String) -> Int64:
    var r = PkgResponse(429)
    r.with_header(String("Retry-After"), v.copy())
    return id_token_verdict(True, r, String("")).server_delay_ms


def test_a_retry_after_that_is_not_seconds_is_absent() raises:
    assert_equal(_retry_after(String("soon")), Int64(-1))
    assert_equal(_retry_after(String("1x")), Int64(-1))
    assert_equal(_retry_after(String("x1")), Int64(-1))
    assert_equal(_retry_after(String("1:")), Int64(-1), "':' is the byte after '9'")
    assert_equal(_retry_after(String("1/")), Int64(-1), "'/' is the byte before '0'")
    assert_equal(_retry_after(String(" 7 ")), Int64(7000))
    print("  test_a_retry_after_that_is_not_seconds_is_absent: PASS")


def _pypi_refused(var t: ScriptedPkgTransport, want: String, absent: String = String("")) raises:
    var cred = _cred(t^, String(""), String("test.pypi.org"))
    var raised = False
    try:
        _ = cred.authorization(SURFACE_PYPI_UPLOAD, String("test.pypi.org"))
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e))
        if absent.byte_length() > 0:
            assert_true(String(e).find(absent) < 0, String(e))
    assert_true(raised, String("expected a refusal containing: ") + want)
    assert_equal(cred.transport().unconsumed(), 0, want)


def test_every_warehouse_refusal() raises:
    var aud_ok = String('{"audience": "testpypi"}')
    var jwt = _jwt()
    # The audience request.
    var t1 = ScriptedPkgTransport()
    t1.queue_fault(String("connection reset"))
    _pypi_refused(t1^, String("the index's audience request faulted: connection reset"))
    var t2 = ScriptedPkgTransport()
    t2.queue(_raw(503, String("down for maintenance")))
    _pypi_refused(t2^, String("the index's audience request answered HTTP 503: down for maintenance"))
    var t3 = ScriptedPkgTransport()
    t3.queue(_raw(200, String('{"other": "x"}')))
    _pypi_refused(t3^, String("the index's audience answer names no audience"))
    # The ID-token answer.
    var t4 = ScriptedPkgTransport()
    t4.queue(_raw(200, aud_ok))
    t4.queue(_raw(200, String("not json")))
    _pypi_refused(t4^, String("the ID-token answer is not JSON"))
    var t5 = ScriptedPkgTransport()
    t5.queue(_raw(200, aud_ok))
    t5.queue(_raw(200, String('{"value": 3}')))
    _pypi_refused(t5^, String("the ID-token answer's 'value' is not a string"))
    var t6 = ScriptedPkgTransport()
    t6.queue(_raw(200, aud_ok))
    t6.queue(_raw(200, String('{"count": 0}')))
    _pypi_refused(t6^, String("the ID-token answer carries no 'value'"))
    # The token exchange.
    var t7 = ScriptedPkgTransport()
    t7.queue(_raw(200, aud_ok))
    t7.queue(_id_token_answer(jwt))
    t7.queue_fault(String("connection reset"))
    _pypi_refused(t7^, String("the index's token exchange faulted: connection reset"))
    var t8 = ScriptedPkgTransport()
    t8.queue(_raw(200, aud_ok))
    t8.queue(_id_token_answer(jwt))
    t8.queue(_raw(400, String("invalid-publisher")))
    _pypi_refused(t8^, String("the index's token exchange answered HTTP 400: invalid-publisher"))
    var t9 = ScriptedPkgTransport()
    t9.queue(_raw(200, aud_ok))
    t9.queue(_id_token_answer(jwt))
    t9.queue(_raw(400, String("bad token ") + jwt))
    _pypi_refused(t9^, String("withheld"), jwt)
    var t10 = ScriptedPkgTransport()
    t10.queue(_raw(200, aud_ok))
    t10.queue(_id_token_answer(jwt))
    t10.queue(_raw(200, String("<html>")))
    _pypi_refused(t10^, String("the index's token exchange answer is not JSON"))
    var t11 = ScriptedPkgTransport()
    t11.queue(_raw(200, aud_ok))
    t11.queue(_id_token_answer(jwt))
    t11.queue(_raw(200, String('{"token": 5}')))
    _pypi_refused(t11^, String("the index's token exchange answer's 'token' is not a string"))
    print("  test_every_warehouse_refusal: PASS")


def main() raises:
    test_from_actions_env_with_both_variables_set()
    test_a_request_url_needs_a_host_and_a_path()
    test_the_audience_is_percent_encoded()
    test_malformed_jwt_payloads()
    test_a_retry_after_that_is_not_seconds_is_absent()
    test_every_warehouse_refusal()
    print("test_pkg_upload_oidc_edges: ALL PASS")
