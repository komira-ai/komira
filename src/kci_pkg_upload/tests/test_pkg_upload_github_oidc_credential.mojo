# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_github_oidc_credential.mojo —
#   trusted publishing: the ID-token request, both exchanges, and every
#   refusal, over a scripted transport.
# =============================================================================
#
# ROWS
#   (1) PREFIX_DEV: the ID-token request goes to the runner's URL with
#       `&audience=prefix.dev` appended and the request token as a Bearer; the
#       exchange POSTs `{"token": "<jwt>"}` to `/api/oidc/mint_token` on the
#       server's host; the RAW 2xx body is the token, presented as
#       `Bearer <token>`; a second call mints nothing;
#   (2) PYPI_UPLOAD: the index's audience is read from `/_/oidc/audience`,
#       the ID token is requested for it, `/_/oidc/mint-token` answers JSON
#       `{"token": ...}`, presented as Basic `__token__:<token>`;
#   (3) the audience: `prefix.dev` for prefix.dev and *.prefix.dev, the host
#       otherwise; a URL with no query gets `?audience=`;
#   (4) a malformed exchange answer is REFUSED, not guessed at: an empty raw
#       body, one holding whitespace or quotes (a JSON string), a warehouse
#       answer with no `token`;
#   (5) nothing secret reaches an error: an ID-token 403 that echoes the
#       request token, a mint 401 that echoes the JWT, a refused raw body;
#   (6) the claims are decoded (not verified), and a required environment
#       that the ID token does not carry is refused BEFORE any exchange;
#   (7) a surface the credential was not given a server for is refused with
#       zero requests; construction refuses an empty request token, a
#       non-https or port-carrying request URL, and no surface at all;
#   (8) `from_actions_env` refuses, naming both variables, when the runner
#       did not set them.
#
# Hermetic: ScriptedPkgTransport; no network. The test sets the two
# handshake variables EMPTY for row (8) and never to a value.
# =============================================================================

from std.os import setenv
from std.testing import assert_equal, assert_raises, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_http.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST
from komira_secret_store import SecretValue

from kci_pkg_upload.credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    pypi_upload_authorization,
)
from kci_pkg_upload.github_oidc_credential import (
    ACTIONS_ID_TOKEN_REQUEST_TOKEN,
    ACTIONS_ID_TOKEN_REQUEST_URL,
    GithubOidcCredential,
    decode_jwt_claims,
    prefix_dev_audience,
)
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _URL: String = "https://token.actions.example.invalid/_apis/idtoken?api-version=2.0"
comptime _REQ_TOKEN: String = "request-token-0123456789abcdef"
comptime _MINTED: String = "pfx_minted_0123456789abcdef"


def _jwt(environment: String) -> String:
    var header = base64_url_encode_nopad(String('{"alg":"RS256","typ":"JWT"}').as_bytes())
    var payload = (
        String('{"repository":"example-org/example-repo",')
        + String('"job_workflow_ref":"example-org/example-repo/.github/workflows/publish.yml@refs/heads/main",')
        + String('"ref":"refs/heads/main"')
    )
    if environment.byte_length() > 0:
        payload += String(',"environment":"') + environment + String('"')
    payload += String("}")
    return (
        header
        + String(".")
        + base64_url_encode_nopad(payload.as_bytes())
        + String(".c2lnbmF0dXJlLW5vdC1jaGVja2Vk")
    )


def _id_token_answer(jwt: String) -> PkgResponse:
    var r = PkgResponse(200)
    r.with_body(bytes_of(String('{"count":1,"value":"') + jwt + String('"}')))
    return r^


def _raw(status: Int, body: String) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(bytes_of(body))
    return r^


def _cred(
    var t: ScriptedPkgTransport,
    prefix_host: String = String("prefix.dev"),
    pypi_index: String = String(""),
    url: String = String(_URL),
) raises -> GithubOidcCredential[ScriptedPkgTransport]:
    return GithubOidcCredential[ScriptedPkgTransport](
        t^, url, SecretValue.from_string(String(_REQ_TOKEN)), prefix_host.copy(), pypi_index.copy()
    )


def test_the_prefix_dev_exchange() raises:
    var jwt = _jwt(String("release"))
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(jwt))
    t.queue(_raw(200, String(_MINTED)))
    var cred = _cred(t^)
    assert_equal(cred.authorization(SURFACE_PREFIX_DEV), String("Bearer ") + String(_MINTED))
    assert_equal(cred.authorization(SURFACE_PREFIX_DEV), String("Bearer ") + String(_MINTED))
    assert_equal(cred.transport().call_count(), 2, "minted once, reused")
    var idreq = cred.transport().call(0)
    assert_equal(idreq.method, HTTP_METHOD_GET)
    assert_equal(idreq.host, String("token.actions.example.invalid"))
    assert_equal(idreq.path, String("/_apis/idtoken?api-version=2.0&audience=prefix.dev"))
    assert_equal(idreq.header_value(String("Authorization")), String("Bearer ") + String(_REQ_TOKEN))
    var mint = cred.transport().call(1)
    assert_equal(mint.method, HTTP_METHOD_POST)
    assert_equal(mint.host, String("prefix.dev"))
    assert_equal(mint.path, String("/api/oidc/mint_token"))
    assert_equal(mint.header_value(String("Content-Type")), String("application/json"))
    assert_equal(mint.header_value(String("Authorization")), String(""))
    assert_equal(String(unsafe_from_utf8=Span(mint.body)), String('{"token":"') + jwt + String('"}'))
    print("  test_the_prefix_dev_exchange: PASS")


def test_the_pypi_exchange() raises:
    var jwt = _jwt(String("release"))
    var t = ScriptedPkgTransport()
    t.queue(_raw(200, String('{"audience": "testpypi"}')))
    t.queue(_id_token_answer(jwt))
    t.queue(_raw(200, String('{"success": true, "token": "pypi-minted-0123456789"}')))
    var cred = _cred(t^, String(""), String("test.pypi.org"))
    assert_equal(
        cred.authorization(SURFACE_PYPI_UPLOAD),
        pypi_upload_authorization(String("pypi-minted-0123456789")),
    )
    var aud = cred.transport().call(0)
    assert_equal(aud.host, String("test.pypi.org"))
    assert_equal(aud.path, String("/_/oidc/audience"))
    assert_equal(cred.transport().call(1).path, String("/_apis/idtoken?api-version=2.0&audience=testpypi"))
    var mint = cred.transport().call(2)
    assert_equal(mint.method, HTTP_METHOD_POST)
    assert_equal(mint.host, String("test.pypi.org"))
    assert_equal(mint.path, String("/_/oidc/mint-token"))
    assert_equal(String(unsafe_from_utf8=Span(mint.body)), String('{"token":"') + jwt + String('"}'))
    print("  test_the_pypi_exchange: PASS")


def test_the_audience() raises:
    assert_equal(prefix_dev_audience(String("prefix.dev")), String("prefix.dev"))
    assert_equal(prefix_dev_audience(String("repo.prefix.dev")), String("prefix.dev"))
    assert_equal(prefix_dev_audience(String("conda.example.org")), String("conda.example.org"))
    assert_equal(prefix_dev_audience(String("notprefix.dev")), String("notprefix.dev"))
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt(String(""))))
    t.queue(_raw(200, String(_MINTED)))
    var cred = _cred(t^, String("conda.example.org"), String(""), String("https://t.example.invalid/idtoken"))
    _ = cred.authorization(SURFACE_PREFIX_DEV)
    assert_equal(cred.transport().call(0).path, String("/idtoken?audience=conda.example.org"))
    assert_equal(cred.transport().call(1).host, String("conda.example.org"))
    print("  test_the_audience: PASS")


def _mint_refused(var answer: PkgResponse, want: String) raises:
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt(String(""))))
    t.queue(answer^)
    var cred = _cred(t^)
    var raised = False
    try:
        _ = cred.authorization(SURFACE_PREFIX_DEV)
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e))
    assert_true(raised, String("expected a refusal containing: ") + want)


def test_a_malformed_exchange_answer_is_refused() raises:
    _mint_refused(_raw(200, String("")), String("answered an EMPTY token"))
    _mint_refused(_raw(200, String("tok en")), String("is not a bare token"))
    _mint_refused(_raw(200, String(_MINTED) + String("\n")), String("is not a bare token"))
    _mint_refused(_raw(200, String('"') + String(_MINTED) + String('"')), String("is not a bare token"))
    _mint_refused(_raw(401, String("Failed to validate token")), String("answered HTTP 401"))
    var t = ScriptedPkgTransport()
    t.queue(_raw(200, String('{"audience": "pypi"}')))
    t.queue(_id_token_answer(_jwt(String(""))))
    t.queue(_raw(200, String('{"success": true}')))
    var cred = _cred(t^, String(""), String("pypi.org"))
    with assert_raises(contains="answered no token"):
        _ = cred.authorization(SURFACE_PYPI_UPLOAD)
    print("  test_a_malformed_exchange_answer_is_refused: PASS")


def test_nothing_secret_reaches_an_error() raises:
    # (a) the ID-token endpoint echoes the request token.
    var t = ScriptedPkgTransport()
    t.queue(_raw(403, String("bad bearer ") + String(_REQ_TOKEN)))
    var cred = _cred(t^)
    try:
        _ = cred.authorization(SURFACE_PREFIX_DEV)
        assert_true(False, "a 403 must be refused")
    except e:
        assert_true(String(e).find(String(_REQ_TOKEN)) < 0, String(e))
        assert_true(String(e).find(String("withheld")) >= 0, String(e))
    # (b) the exchange echoes the JWT.
    var jwt = _jwt(String("release"))
    var t2 = ScriptedPkgTransport()
    t2.queue(_id_token_answer(jwt))
    t2.queue(_raw(401, String("rejected token ") + jwt))
    var cred2 = _cred(t2^)
    try:
        _ = cred2.authorization(SURFACE_PREFIX_DEV)
        assert_true(False, "a 401 must be refused")
    except e:
        assert_true(String(e).find(jwt) < 0, String(e))
        assert_true(String(e).find(String(jwt[byte=0:20])) < 0, String(e))
    # (c) a refused raw body is not quoted.
    var t3 = ScriptedPkgTransport()
    t3.queue(_id_token_answer(jwt))
    t3.queue(_raw(200, String(_MINTED) + String(" trailing")))
    var cred3 = _cred(t3^)
    try:
        _ = cred3.authorization(SURFACE_PREFIX_DEV)
        assert_true(False, "a malformed body must be refused")
    except e:
        assert_true(String(e).find(String(_MINTED)) < 0, String(e))
    print("  test_nothing_secret_reaches_an_error: PASS")


def test_claims_and_the_required_environment() raises:
    var c = decode_jwt_claims(_jwt(String("release")))
    assert_equal(c.repository, String("example-org/example-repo"))
    assert_equal(c.environment, String("release"))
    assert_equal(c.git_ref, String("refs/heads/main"))
    assert_true(c.job_workflow_ref.find(String("publish.yml@refs/heads/main")) > 0)
    with assert_raises(contains="not a compact JWT"):
        _ = decode_jwt_claims(String("only.two"))
    # CONTROL: the required environment is the token's.
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt(String("release"))))
    t.queue(_raw(200, String(_MINTED)))
    var ok = _cred(t^)
    ok.with_required_environment(String("release"))
    assert_equal(ok.authorization(SURFACE_PREFIX_DEV), String("Bearer ") + String(_MINTED))
    assert_true(ok.has_claims())
    assert_equal(ok.claims().environment, String("release"))
    # Another environment: refused after the ID token, before the exchange.
    var t2 = ScriptedPkgTransport()
    t2.queue(_id_token_answer(_jwt(String("staging"))))
    var bad = _cred(t2^)
    bad.with_required_environment(String("release"))
    with assert_raises(contains="not the required 'release'"):
        _ = bad.authorization(SURFACE_PREFIX_DEV)
    assert_equal(bad.transport().call_count(), 1)
    # No environment claim at all: refused the same way.
    var t3 = ScriptedPkgTransport()
    t3.queue(_id_token_answer(_jwt(String(""))))
    var none = _cred(t3^)
    none.with_required_environment(String("release"))
    with assert_raises(contains="not the required 'release'"):
        _ = none.authorization(SURFACE_PREFIX_DEV)
    assert_equal(none.transport().call_count(), 1)
    print("  test_claims_and_the_required_environment: PASS")


def test_unserved_surfaces_and_construction_refusals() raises:
    var t = ScriptedPkgTransport()
    var only_prefix = _cred(t^)
    with assert_raises(contains="cannot serve the PYPI_UPLOAD surface"):
        _ = only_prefix.authorization(SURFACE_PYPI_UPLOAD)
    assert_equal(only_prefix.transport().call_count(), 0)
    with assert_raises(contains="request token is EMPTY"):
        _ = GithubOidcCredential[ScriptedPkgTransport](
            ScriptedPkgTransport(), String(_URL), SecretValue.from_string(String("")),
            String("prefix.dev"), String(""),
        )
    with assert_raises(contains="is not an https:// URL"):
        _ = _cred(ScriptedPkgTransport(), url=String("http://t.example.invalid/idtoken"))
    with assert_raises(contains="names a port or userinfo"):
        _ = _cred(ScriptedPkgTransport(), url=String("https://t.example.invalid:8443/idtoken"))
    with assert_raises(contains="serves no surface"):
        _ = _cred(ScriptedPkgTransport(), String(""), String(""))
    with assert_raises(contains="must be a bare host"):
        _ = _cred(ScriptedPkgTransport(), String("prefix.dev/channel"))
    print("  test_unserved_surfaces_and_construction_refusals: PASS")


def test_from_actions_env_names_the_missing_variables() raises:
    _ = setenv(String(ACTIONS_ID_TOKEN_REQUEST_URL), String(""), True)
    _ = setenv(String(ACTIONS_ID_TOKEN_REQUEST_TOKEN), String(""), True)
    try:
        _ = GithubOidcCredential[ScriptedPkgTransport].from_actions_env(
            ScriptedPkgTransport(), String("prefix.dev"), String("")
        )
        assert_true(False, "absent handshake variables must be refused")
    except e:
        var msg = String(e)
        assert_true(msg.find(String(ACTIONS_ID_TOKEN_REQUEST_URL)) >= 0, msg)
        assert_true(msg.find(String(ACTIONS_ID_TOKEN_REQUEST_TOKEN)) >= 0, msg)
        assert_true(msg.find(String("id-token: write")) >= 0, msg)
    print("  test_from_actions_env_names_the_missing_variables: PASS")


def main() raises:
    test_the_prefix_dev_exchange()
    test_the_pypi_exchange()
    test_the_audience()
    test_a_malformed_exchange_answer_is_refused()
    test_nothing_secret_reaches_an_error()
    test_claims_and_the_required_environment()
    test_unserved_surfaces_and_construction_refusals()
    test_from_actions_env_names_the_missing_variables()
    print("test_pkg_upload_github_oidc_credential: ALL PASS")
