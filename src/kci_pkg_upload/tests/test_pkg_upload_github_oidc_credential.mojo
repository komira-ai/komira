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
#       did not set them;
#   (9) the minted token goes ONLY to the host it was minted at: a prefix.dev
#       or index upload whose coordinate names another server is refused with
#       ZERO requests on either transport (no ID token, no mint, no upload),
#       on both surfaces and on reads; host case does not matter;
#  (10) the ID-token request is RETRIED, bounded: a transport fault (the
#       connect timeout a release job met), a 5xx and a 429 are sent again
#       after a backoff wait through the injected sleeper, at most 4 sends,
#       the error naming the attempts and still withholding secrets (a fault
#       or a body that echoes the request token); the policy is pinned field
#       by field; a Retry-After of 10 s is waited out, one of 11 s (or 120 s,
#       or 7 digits, on a 429 or a 503) is final after ONE send, as are a 403
#       and a 404; a token exchange that faults is NOT retried.
#
# Hermetic: ScriptedPkgTransport and komira_retry's RecordingSleeper (a wait
# is recorded, never slept); no network. The test sets the two
# handshake variables EMPTY for row (8) and never to a value.
# =============================================================================

from std.os import setenv
from std.testing import assert_equal, assert_raises, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_retry import RecordingSleeper
from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST
from komira_secret_store import SecretValue

from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    pypi_upload_authorization,
)
from kci_pkg_upload.github_oidc_credential import (
    ACTIONS_ID_TOKEN_REQUEST_TOKEN,
    ACTIONS_ID_TOKEN_REQUEST_URL,
    ID_TOKEN_RETRY_DEADLINE_MS,
    ID_TOKEN_RETRY_INITIAL_MS,
    ID_TOKEN_RETRY_MAX_ATTEMPTS,
    ID_TOKEN_RETRY_MAX_MS,
    ID_TOKEN_RETRY_MAX_SERVER_DELAY_MS,
    GithubOidcCredential,
    decode_jwt_claims,
    id_token_retry_policy,
    prefix_dev_audience,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _URL: String = "https://token.actions.example.invalid/_apis/idtoken?api-version=2.0"
comptime _REQ_TOKEN: String = "request-token-0123456789abcdef"
comptime _MINTED: String = "pfx_minted_0123456789abcdef"
comptime _TIMEOUT: String = "TcpStream.connect timed out after 5 s"
comptime _Cred = GithubOidcCredential[ScriptedPkgTransport, RecordingSleeper]


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
) raises -> _Cred:
    return _Cred(
        t^, RecordingSleeper(), url, SecretValue.from_string(String(_REQ_TOKEN)), prefix_host.copy(), pypi_index.copy()
    )


def test_the_prefix_dev_exchange() raises:
    var jwt = _jwt(String("release"))
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(jwt))
    t.queue(_raw(200, String(_MINTED)))
    var cred = _cred(t^)
    assert_equal(cred.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")), String("Bearer ") + String(_MINTED))
    assert_equal(cred.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")), String("Bearer ") + String(_MINTED))
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
        cred.authorization(SURFACE_PYPI_UPLOAD, String("test.pypi.org")),
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
    _ = cred.authorization(SURFACE_PREFIX_DEV, String("conda.example.org"))
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
        _ = cred.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
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
        _ = cred.authorization(SURFACE_PYPI_UPLOAD, String("pypi.org"))
    print("  test_a_malformed_exchange_answer_is_refused: PASS")


def test_nothing_secret_reaches_an_error() raises:
    # (a) the ID-token endpoint echoes the request token.
    var t = ScriptedPkgTransport()
    t.queue(_raw(403, String("bad bearer ") + String(_REQ_TOKEN)))
    var cred = _cred(t^)
    try:
        _ = cred.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
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
        _ = cred2.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
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
        _ = cred3.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
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
    assert_equal(ok.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")), String("Bearer ") + String(_MINTED))
    assert_true(ok.has_claims())
    assert_equal(ok.claims().environment, String("release"))
    # Another environment: refused after the ID token, before the exchange.
    var t2 = ScriptedPkgTransport()
    t2.queue(_id_token_answer(_jwt(String("staging"))))
    var bad = _cred(t2^)
    bad.with_required_environment(String("release"))
    with assert_raises(contains="not the required 'release'"):
        _ = bad.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
    assert_equal(bad.transport().call_count(), 1)
    # No environment claim at all: refused the same way.
    var t3 = ScriptedPkgTransport()
    t3.queue(_id_token_answer(_jwt(String(""))))
    var none = _cred(t3^)
    none.with_required_environment(String("release"))
    with assert_raises(contains="not the required 'release'"):
        _ = none.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
    assert_equal(none.transport().call_count(), 1)
    print("  test_claims_and_the_required_environment: PASS")


def test_unserved_surfaces_and_construction_refusals() raises:
    var t = ScriptedPkgTransport()
    var only_prefix = _cred(t^)
    with assert_raises(contains="cannot serve the PYPI_UPLOAD surface"):
        _ = only_prefix.authorization(SURFACE_PYPI_UPLOAD, String("test.pypi.org"))
    assert_equal(only_prefix.transport().call_count(), 0)
    with assert_raises(contains="request token is EMPTY"):
        _ = _Cred(
            ScriptedPkgTransport(), RecordingSleeper(), String(_URL), SecretValue.from_string(String("")),
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
        _ = _Cred.from_actions_env(
            ScriptedPkgTransport(), RecordingSleeper(), String("prefix.dev"), String("")
        )
        assert_true(False, "absent handshake variables must be refused")
    except e:
        var msg = String(e)
        assert_true(msg.find(String(ACTIONS_ID_TOKEN_REQUEST_URL)) >= 0, msg)
        assert_true(msg.find(String(ACTIONS_ID_TOKEN_REQUEST_TOKEN)) >= 0, msg)
        assert_true(msg.find(String("id-token: write")) >= 0, msg)
    print("  test_from_actions_env_names_the_missing_variables: PASS")


def _conda_at(repo: String) -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            SUBSTRATE_PREFIX_DEV_CONDA,
            repo.copy(),
            String("komira-probe"),
            String("1.2.3"),
            String("linux-64"),
            String("komira-probe-1.2.3-h0_0.conda"),
        ),
        bytes_of(String("conda-bytes")),
        String(""),
    )


def _wheel_at(repo: String) -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            repo.copy(),
            String("komira_probe"),
            String("1.1.3"),
            String("linux-64"),
            String("komira_probe-1.1.3-py3-none-any.whl"),
        ),
        bytes_of(String("wheel-bytes")),
        String("Metadata-Version: 2.1\nName: komira_probe\nVersion: 1.1.3\n\n"),
    )


def _names() raises -> ApprovedNames:
    var p = ApprovedNames()
    p.approve(String("komira_probe"))
    p.approve(String("komira-probe"))
    return p^


def test_the_token_goes_only_to_its_mint_host() raises:
    var oidc = ScriptedPkgTransport()
    oidc.queue(_id_token_answer(_jwt(String("release"))))
    oidc.queue(_raw(200, String(_MINTED)))
    var w = ScriptedPkgTransport()
    w.queue(PkgResponse(201))
    var rs = RegistrySet[ScriptedPkgTransport, _Cred](
        w^, _cred(oidc^, String("prefix.dev"), String("test.pypi.org"))
    )
    var other = _conda_at(String("conda.example.org/example-channel"))
    with assert_raises(contains="will not present its PREFIX_DEV credential to 'conda.example.org'"):
        _ = rs.upload(other, _names())
    with assert_raises(contains="will not present"):
        _ = rs.read_back(other.coordinate)
    with assert_raises(contains="will not present"):
        _ = rs.fetch(other.coordinate)
    with assert_raises(contains="will not present its PYPI_UPLOAD credential to 'pypi.org'"):
        _ = rs.upload(_wheel_at(String("pypi.org")), _names())
    assert_equal(rs.transport().call_count(), 0, "nothing reached the other server")
    assert_equal(rs.credential().transport().call_count(), 0, "nothing was minted")
    # CONTROL: the mint host, in any case, gets the token.
    _ = rs.upload(_conda_at(String("Prefix.Dev/example-channel")), _names())
    assert_equal(rs.credential().transport().call_count(), 2)
    assert_equal(rs.transport().call_count(), 1)
    assert_equal(
        rs.transport().call(0).header_value(String("Authorization")),
        String("Bearer ") + String(_MINTED),
    )
    print("  test_the_token_goes_only_to_its_mint_host: PASS")


def _with_retry_after(status: Int, seconds: String) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_header(String("Retry-After"), seconds.copy())
    return r^


def test_the_id_token_request_is_retried() raises:
    var policy = id_token_retry_policy()
    assert_equal(policy.max_attempts, 4)
    assert_equal(policy.backoff.initial_ms, Int64(1000))
    assert_equal(policy.backoff.multiplier, 2.0)
    assert_equal(policy.backoff.max_ms, Int64(4000))
    assert_true(policy.backoff.jitter.is_full())
    assert_equal(policy.deadline_ms, Int64(60_000))
    assert_equal(policy.max_server_delay_ms, Int64(10_000))
    assert_equal(ID_TOKEN_RETRY_MAX_ATTEMPTS, 4)
    assert_equal(ID_TOKEN_RETRY_MAX_MS, Int64(4000))
    assert_equal(ID_TOKEN_RETRY_DEADLINE_MS, Int64(60_000))
    assert_equal(ID_TOKEN_RETRY_MAX_SERVER_DELAY_MS, Int64(10_000))
    # (a) two connect timeouts, then the ID token: minted, after two waits
    # within the first two backoff caps (full jitter: [0, 1 s], [0, 2 s]).
    var jwt = _jwt(String("release"))
    var t = ScriptedPkgTransport()
    t.queue_fault(String(_TIMEOUT))
    t.queue_fault(String(_TIMEOUT))
    t.queue(_id_token_answer(jwt))
    t.queue(_raw(200, String(_MINTED)))
    var cred = _cred(t^)
    assert_equal(cred.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")), String("Bearer ") + String(_MINTED))
    assert_equal(cred.transport().call_count(), 4)
    assert_equal(cred.transport().unconsumed(), 0)
    for i in range(3):
        assert_equal(cred.transport().call(i).path, String("/_apis/idtoken?api-version=2.0&audience=prefix.dev"))
        assert_equal(
            cred.transport().call(i).header_value(String("Authorization")), String("Bearer ") + String(_REQ_TOKEN)
        )
    assert_equal(cred.transport().call(3).method, HTTP_METHOD_POST)
    assert_equal(cred.id_token_retry().attempts(), 3)
    assert_equal(len(cred.id_token_retry().sleeper().slept), 2)
    assert_true(cred.id_token_retry().sleeper().slept[0] <= ID_TOKEN_RETRY_INITIAL_MS)
    assert_true(cred.id_token_retry().sleeper().slept[1] <= 2 * ID_TOKEN_RETRY_INITIAL_MS)
    # (b) the runner's service never answers: 4 sends, 3 waits, no mint; the
    # error names the attempts and the last fault.
    var t2 = ScriptedPkgTransport()
    for _ in range(4):
        t2.queue_fault(String(_TIMEOUT))
    var down = _cred(t2^)
    try:
        _ = down.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
        assert_true(False, "an unreachable ID-token service must be refused")
    except e:
        var msg = String(e)
        assert_true(msg.find(String("ID-token request faulted (after 4 attempts)")) >= 0, msg)
        assert_true(msg.find(String(_TIMEOUT)) >= 0, msg)
    assert_equal(down.transport().call_count(), 4, "bounded: no fifth send")
    assert_equal(len(down.id_token_retry().sleeper().slept), 3)
    for i in range(3):
        assert_true(down.id_token_retry().sleeper().slept[i] <= ID_TOKEN_RETRY_INITIAL_MS * Int64(1 << i))
    # (b2) a retried fault whose text echoes the request token: withheld.
    var t2b = ScriptedPkgTransport()
    for _ in range(4):
        t2b.queue_fault(String("connect refused for Bearer ") + String(_REQ_TOKEN))
    var echo = _cred(t2b^)
    try:
        _ = echo.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
        assert_true(False, "an echoing fault must be refused")
    except e:
        var msg = String(e)
        assert_true(msg.find(String(_REQ_TOKEN)) < 0, msg)
        assert_true(msg.find(String("withheld")) >= 0, msg)
    assert_equal(echo.transport().call_count(), 4)
    # (c) a 503 and a 429 are sent again; the 429's Retry-After is the wait
    # when it is longer than the backoff.
    var t3 = ScriptedPkgTransport()
    t3.queue(_raw(503, String("unavailable")))
    t3.queue(_with_retry_after(429, String("3")))
    t3.queue(_id_token_answer(jwt))
    t3.queue(_raw(200, String(_MINTED)))
    var busy = _cred(t3^)
    assert_equal(busy.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")), String("Bearer ") + String(_MINTED))
    assert_equal(busy.transport().call_count(), 4)
    assert_equal(len(busy.id_token_retry().sleeper().slept), 2)
    assert_equal(busy.id_token_retry().sleeper().slept[1], Int64(3000))
    # (c2) the 10 s boundary: Retry-After 10 on a 503 is waited out.
    var t3b = ScriptedPkgTransport()
    t3b.queue(_with_retry_after(503, String("10")))
    t3b.queue(_id_token_answer(jwt))
    t3b.queue(_raw(200, String(_MINTED)))
    var edge = _cred(t3b^)
    _ = edge.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
    assert_equal(edge.transport().call_count(), 3)
    assert_equal(len(edge.id_token_retry().sleeper().slept), 1)
    assert_equal(edge.id_token_retry().sleeper().slept[0], Int64(10_000))
    # (d) a 503 every time: the status, the attempts, and a body echoing the
    # request token still withheld.
    var t4 = ScriptedPkgTransport()
    for _ in range(4):
        t4.queue(_raw(503, String("bad bearer ") + String(_REQ_TOKEN)))
    var five = _cred(t4^)
    try:
        _ = five.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
        assert_true(False, "a 503 every time must be refused")
    except e:
        var msg = String(e)
        assert_true(msg.find(String("answered HTTP 503 (after 4 attempts)")) >= 0, msg)
        assert_true(msg.find(String(_REQ_TOKEN)) < 0, msg)
    assert_equal(five.transport().call_count(), 4)
    # (e) final after ONE send, no wait: 403, 404, and a 429 asking for more
    # than 10 s. The message carries no attempt count.
    var finals = List[PkgResponse]()
    finals.append(_raw(403, String("no id-token permission")))
    finals.append(_raw(404, String("not found")))
    finals.append(_with_retry_after(429, String("11")))
    finals.append(_with_retry_after(429, String("120")))
    finals.append(_with_retry_after(503, String("120")))
    finals.append(_with_retry_after(429, String("1000000")))
    var statuses = List[String]()
    statuses.append(String("answered HTTP 403: "))
    statuses.append(String("answered HTTP 404: "))
    statuses.append(String("answered HTTP 429: "))
    statuses.append(String("answered HTTP 429: "))
    statuses.append(String("answered HTTP 503: "))
    statuses.append(String("answered HTTP 429: "))
    for i in range(len(finals)):
        var tf = ScriptedPkgTransport()
        tf.queue(finals[i].copy())
        var c = _cred(tf^)
        with assert_raises(contains=statuses[i]):
            _ = c.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
        assert_equal(c.transport().call_count(), 1, statuses[i])
        assert_equal(len(c.id_token_retry().sleeper().slept), 0, statuses[i])
    # (f) the token exchange is not retried: a mint fault ends the call.
    var t6 = ScriptedPkgTransport()
    t6.queue(_id_token_answer(jwt))
    t6.queue_fault(String(_TIMEOUT))
    var mint = _cred(t6^)
    with assert_raises(contains="prefix.dev token exchange faulted"):
        _ = mint.authorization(SURFACE_PREFIX_DEV, String("prefix.dev"))
    assert_equal(mint.transport().call_count(), 2)
    assert_equal(len(mint.id_token_retry().sleeper().slept), 0)
    print("  test_the_id_token_request_is_retried: PASS")


def main() raises:
    test_the_prefix_dev_exchange()
    test_the_pypi_exchange()
    test_the_audience()
    test_a_malformed_exchange_answer_is_refused()
    test_nothing_secret_reaches_an_error()
    test_claims_and_the_required_environment()
    test_unserved_surfaces_and_construction_refusals()
    test_from_actions_env_names_the_missing_variables()
    test_the_token_goes_only_to_its_mint_host()
    test_the_id_token_request_is_retried()
    print("test_pkg_upload_github_oidc_credential: ALL PASS")
