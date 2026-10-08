# =============================================================================
# komira_gcp_wif/tests/test_external_account.mojo — an `external_account`
#   file's flow on the wire, over komira_http_core's ScriptedConnector.
# =============================================================================
#
# Three connectors per fetcher, each with its own write capture: the
# credential_source URL (plaintext, an IP literal), STS, and IAM Credentials
# (TLS-reporting; no handshake runs). As in test_wif_mint, the client
# resolves the two Google host names before it hands the scripted connector
# a dial. Every claim reads back the
# exact bytes the client wrote.
#
#   §1 a file-sourced subject: the whole STS form against hand-written text
#      (the jwt type and the file's audience), without and with
#      impersonation.
#   §2 a URL-sourced subject (one JSON field of a GET with the file's
#      headers): the same two cases.
#   §3 refusals: each required field absent, named; sources this reader does
#      not run; endpoints that are not bare https hosts; an STS refusal never
#      reaching IAM Credentials.
#
# ⛔ EVERY ABSENCE HAS A POSITIVE CONTROL. "IAM Credentials was not dialed"
# (no impersonation URL) is paired with the impersonation case of the same
# source, whose IAM capture is the whole expected request.
#
# The scripted responses are SYNTHETIC, written from the documented schemas
# (STS: `access_token`, `expires_in`; generateAccessToken: `accessToken`,
# `expireTime`). The tokens are made up.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import FixedWallClock, MapFiles
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_gcp_wif import (
    ExternalAccountFetcher,
    JWT_SUBJECT_TOKEN_TYPE,
    generate_access_token_body,
    parse_external_account,
)


comptime TIMEOUT_US: Int = 5_000_000
comptime NOW_S: Int = 1_790_856_000  # 2026-10-01T12:00:00Z
comptime NOW_MS: Int = 5_000
comptime AUDIENCE = (
    "//iam.googleapis.com/projects/1234567890/locations/global/"
    "workloadIdentityPools/ci-pool/providers/ci-oidc"
)
# The audience and the jwt type, form-encoded as the STS body carries them.
comptime AUDIENCE_FORM = (
    "%2F%2Fiam.googleapis.com%2Fprojects%2F1234567890%2Flocations%2Fglobal"
    "%2FworkloadIdentityPools%2Fci-pool%2Fproviders%2Fci-oidc"
)
comptime JWT_FORM = "urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Ajwt"
comptime IMP_URL = (
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/"
    "deployer@demo-project.example:generateAccessToken"
)
comptime IMP_PATH = (
    "/v1/projects/-/serviceAccounts/deployer@demo-project.example"
    ":generateAccessToken"
)
comptime TOKEN_FILE = "/var/run/ci/oidc-token"
# An IP literal over plain http, as a link-local metadata service is
# reached: the client resolves no name for it, and its connector is the
# plaintext one.
comptime SOURCE_URL = "http://127.0.0.1/oidc?audience=gcp"
comptime OIDC = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJjaSJ9.OIDC-FAKE"
comptime SOURCE_BEARER = "SOURCE-BEARER-FAKE"
comptime FEDERATED = "ya29.FEDERATED-FAKE"
comptime IMPERSONATED = "ya29.IMPERSONATED-FAKE"

comptime Fetcher = ExternalAccountFetcher[
    ScriptedConnector, ScriptedConnector, MapFiles, FixedWallClock
]


# =============================================================================
# Fixtures.
# =============================================================================


def _http(status_line: String, body: String) -> List[UInt8]:
    var http = String("HTTP/1.1 ") + status_line + String("\r\nContent-Length: ")
    http += String(len(body.as_bytes()))
    http += String("\r\nConnection: close\r\n\r\n")
    http += body
    var out = List[UInt8]()
    out.extend(Span(http.as_bytes()))
    return out^


def _sts_ok() -> List[UInt8]:
    return _http(
        String("200 OK"),
        String('{"access_token":"') + FEDERATED + '","issued_token_type":'
        + '"urn:ietf:params:oauth:token-type:access_token","token_type":'
        + '"Bearer","expires_in":3599}',
    )


def _iam_ok() -> List[UInt8]:
    # expireTime 1800 s after NOW_S.
    return _http(
        String("200 OK"),
        String('{"accessToken":"') + IMPERSONATED
        + '","expireTime":"2026-10-01T12:30:00Z"}',
    )


def _source_ok() -> List[UInt8]:
    return _http(String("200 OK"), String('{"count":1,"value":"') + OIDC + '"}')


def _capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _text(cap: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(cap[]))


def _tls(var script: List[UInt8], shared: ArcPointer[List[UInt8]]) -> ScriptedConnector:
    return ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(script^, shared)
    )


def _plain(var script: List[UInt8], shared: ArcPointer[List[UInt8]]) -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script_with_capture(script^, shared)
    )


def _client(var c: ScriptedConnector) -> HttpClient[ScriptedConnector]:
    return HttpClient[ScriptedConnector].with_request_timeout_us(c^, TIMEOUT_US)


def _file_source() -> String:
    return String('{"file":"') + TOKEN_FILE + '"}'


def _url_source() -> String:
    return (
        String('{"url":"') + SOURCE_URL + '","headers":{"Authorization":'
        + '"Bearer ' + SOURCE_BEARER + '"},"format":{"type":"json",'
        + '"subject_token_field_name":"value"}}'
    )


def _file_json(source: String, impersonate: Bool) -> String:
    var out = (
        String('{"type":"external_account","audience":"') + AUDIENCE
        + '","subject_token_type":"' + JWT_SUBJECT_TOKEN_TYPE
        + '","token_url":"https://sts.googleapis.com/v1/token",'
    )
    if impersonate:
        out += String('"service_account_impersonation_url":"') + IMP_URL + '",'
    out += String('"credential_source":') + source + "}"
    return out^


def _files() -> MapFiles:
    var f = MapFiles()
    f.put(String(TOKEN_FILE), String(OIDC))
    return f^


struct Caps(Movable, Deinitable):
    var source: ArcPointer[List[UInt8]]
    var sts: ArcPointer[List[UInt8]]
    var iam: ArcPointer[List[UInt8]]

    def __init__(out self):
        self.source = _capture()
        self.sts = _capture()
        self.iam = _capture()


def _fetcher(file_text: String, caps: Caps, var source_script: List[UInt8]) raises -> Fetcher:
    """Every connector armed with its success answer; a test reads which of
    them were written to."""
    return Fetcher(
        parse_external_account(file_text),
        _client(_plain(source_script^, caps.source)),
        _client(_tls(_sts_ok(), caps.sts)),
        _client(_tls(_iam_ok(), caps.iam)),
        _files(),
        FixedWallClock(Int64(NOW_S)),
    )


# =============================================================================
# Readers of what the client wrote.
# =============================================================================


def _body_of(req: String) -> String:
    var at = req.find("\r\n\r\n")
    if at < 0:
        return String("")
    return String(req[byte = at + 4 :])


def _head_lines(req: String) -> List[String]:
    var out = List[String]()
    var b = req.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")):
            var end = i
            if end > start and b[end - 1] == UInt8(ord("\r")):
                end -= 1
            if end == start:
                break
            out.append(String(unsafe_from_utf8=b[start:end]))
            start = i + 1
    return out^


def _header_names(req: String) raises -> String:
    var lines = _head_lines(req)
    var names = List[String]()
    for i in range(1, len(lines)):
        var colon = lines[i].find(":")
        if colon <= 0:
            raise Error("a head line with no name: " + lines[i])
        names.append(String(lines[i][byte=0:colon]).lower())
    sort(names)
    var out = String("")
    for i in range(len(names)):
        if i > 0:
            out += ","
        out += names[i]
    return out^


def _header_value(req: String, name: String) raises -> String:
    var lines = _head_lines(req)
    var found = List[String]()
    for i in range(1, len(lines)):
        var colon = lines[i].find(":")
        if colon > 0 and String(lines[i][byte=0:colon]).lower() == name:
            found.append(String(String(lines[i][byte=colon + 1 :]).strip()))
    if len(found) != 1:
        raise Error("header " + name + " appears " + String(len(found)) + " times")
    return found[0].copy()


def _sts_form(scope_form: String) -> String:
    """The whole STS body, by hand: the reference's field order, the file's
    audience, the OIDC token (it holds only unreserved bytes) and the jwt
    type."""
    return (
        String("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange")
        + "&audience=" + AUDIENCE_FORM
        + "&scope=" + scope_form
        + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
        + "&subject_token=" + OIDC
        + "&subject_token_type=" + JWT_FORM
    )


comptime CLOUD_FORM = "https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform"


def _check_sts(req: String) raises:
    assert_true(req.startswith("POST /v1/token HTTP/1.1\r\n"), req)
    assert_equal(_header_value(req, String("host")), "sts.googleapis.com")
    assert_equal(_header_names(req), "content-length,content-type,host,user-agent")
    assert_equal(_body_of(req), _sts_form(String(CLOUD_FORM)))


def _check_iam(req: String) raises:
    """The whole generateAccessToken request: the file's path, the federated
    token as the one credential, the scope and the default lifetime."""
    assert_true(req.startswith(String("POST ") + IMP_PATH + " HTTP/1.1\r\n"), req)
    assert_equal(_header_value(req, String("host")), "iamcredentials.googleapis.com")
    assert_equal(
        _header_names(req), "authorization,content-length,content-type,host,user-agent"
    )
    assert_equal(_header_value(req, String("authorization")), String("Bearer ") + FEDERATED)
    assert_equal(
        _body_of(req),
        '{"scope":["https://www.googleapis.com/auth/cloud-platform"],"lifetime":"3600s"}',
    )


def _check_source_get(req: String) raises:
    """One GET of the source URL with exactly the file's header."""
    assert_true(req.startswith("GET /oidc?audience=gcp HTTP/1.1\r\n"), req)
    assert_equal(_header_value(req, String("host")), "127.0.0.1")
    assert_equal(
        _header_value(req, String("authorization")), String("Bearer ") + SOURCE_BEARER
    )
    assert_false(OIDC in req, req)


# =============================================================================
# §1 — a file-sourced subject.
# =============================================================================


def test_file_subject_without_impersonation_is_the_sts_token() raises:
    """The token file's text goes to STS with the jwt type and the file's
    audience, and the federated token is returned; neither the source URL nor
    IAM Credentials sees a byte."""
    var caps = Caps()
    var f = _fetcher(_file_json(_file_source(), False), caps, List[UInt8]())
    var tok = f.fetch(Int64(NOW_MS))
    _check_sts(_text(caps.sts))
    assert_equal(tok.token, FEDERATED)
    assert_equal(tok.expires_at_ms, Int64(NOW_MS + 3599 * 1000))
    assert_equal(len(caps.iam[]), 0)
    assert_equal(len(caps.source[]), 0)


def test_file_subject_with_impersonation_returns_the_impersonated_token() raises:
    """THE POSITIVE CONTROL for the absence above: with an impersonation URL,
    the same exchange is followed by one generateAccessToken request whose
    bearer is the federated token, and ITS token is returned, expiring at
    expireTime (1800 s after the wall clock) on the monotonic timeline."""
    var caps = Caps()
    var f = _fetcher(_file_json(_file_source(), True), caps, List[UInt8]())
    var tok = f.fetch(Int64(NOW_MS))
    _check_sts(_text(caps.sts))
    _check_iam(_text(caps.iam))
    assert_equal(tok.token, IMPERSONATED)
    assert_equal(tok.expires_at_ms, Int64(NOW_MS + 1800 * 1000))
    assert_equal(len(caps.source[]), 0)


def test_impersonation_sends_the_callers_scope_and_sts_cloud_platform() raises:
    """`set_scope` reaches generateAccessToken; the exchange still asks for
    cloud-platform, as the reference does."""
    var caps = Caps()
    var f = _fetcher(_file_json(_file_source(), True), caps, List[UInt8]())
    f.set_scope(String("https://www.googleapis.com/auth/devstorage.read_only"))
    _ = f.fetch(Int64(NOW_MS))
    assert_equal(_body_of(_text(caps.sts)), _sts_form(String(CLOUD_FORM)))
    assert_equal(
        _body_of(_text(caps.iam)),
        generate_access_token_body(
            String("https://www.googleapis.com/auth/devstorage.read_only"), 3600
        ),
    )


# =============================================================================
# §2 — a URL-sourced subject.
# =============================================================================


def test_url_subject_without_impersonation_is_the_sts_token() raises:
    var caps = Caps()
    var f = _fetcher(_file_json(_url_source(), False), caps, _source_ok())
    var tok = f.fetch(Int64(NOW_MS))
    _check_source_get(_text(caps.source))
    _check_sts(_text(caps.sts))
    assert_equal(tok.token, FEDERATED)
    assert_equal(len(caps.iam[]), 0)


def test_url_subject_with_impersonation_returns_the_impersonated_token() raises:
    var caps = Caps()
    var f = _fetcher(_file_json(_url_source(), True), caps, _source_ok())
    var tok = f.fetch(Int64(NOW_MS))
    _check_source_get(_text(caps.source))
    _check_sts(_text(caps.sts))
    _check_iam(_text(caps.iam))
    assert_equal(tok.token, IMPERSONATED)


def test_a_refused_source_url_never_dials_sts() raises:
    """A non-2xx source answer raises with its status, quoting no body
    byte, before STS is dialed."""
    var caps = Caps()
    var f = _fetcher(
        _file_json(_url_source(), True),
        caps,
        _http(String("403 Forbidden"), String('{"value":"LEAKED-IN-ERROR"}')),
    )
    var msg = String("")
    try:
        _ = f.fetch(Int64(NOW_MS))
    except e:
        msg = String(e)
    assert_true("credential_source url answered HTTP 403" in msg, msg)
    assert_false("LEAKED" in msg, msg)
    assert_true(len(caps.source[]) > 0)
    assert_equal(len(caps.sts[]), 0)
    assert_equal(len(caps.iam[]), 0)


# =============================================================================
# §3 — refusals.
# =============================================================================


def _refusal(text: String) -> String:
    try:
        _ = parse_external_account(text)
    except e:
        return String(e)
    return String("NOT REFUSED")


def _without(field: String) -> String:
    """A good file (file source, impersonating) without `field`."""
    var out = String('{"type":"external_account"')
    if field != "audience":
        out += String(',"audience":"') + AUDIENCE + '"'
    if field != "subject_token_type":
        out += String(',"subject_token_type":"') + JWT_SUBJECT_TOKEN_TYPE + '"'
    if field != "token_url":
        out += String(',"token_url":"https://sts.googleapis.com/v1/token"')
    out += String(',"service_account_impersonation_url":"') + IMP_URL + '"'
    if field != "credential_source":
        out += String(',"credential_source":') + _file_source()
    out += "}"
    return out^


def test_each_required_field_absent_is_refused_by_name() raises:
    """The control first: the same builder with nothing removed parses."""
    _ = parse_external_account(_without(String("none")))
    var fields: List[String] = [
        "audience", "subject_token_type", "token_url", "credential_source"
    ]
    for i in range(len(fields)):
        var msg = _refusal(_without(fields[i]))
        assert_equal(
            msg,
            String("komira_gcp_wif: the external_account file has no \"")
            + fields[i] + "\"",
        )


def test_other_types_and_sources_are_refused() raises:
    var not_ea = _file_json(_file_source(), False).replace(
        "external_account", "service_account"
    )
    assert_true("other than external_account" in _refusal(not_ea))
    assert_true(
        "AwsWifTokenFetcher" in _refusal(
            _file_json(String('{"environment_id":"aws1","region_url":"x"}'), False)
        )
    )
    assert_true(
        "executable" in _refusal(
            _file_json(String('{"executable":{"command":"x"}}'), False)
        )
    )
    assert_true(
        "both" in _refusal(
            _file_json(String('{"file":"/a","url":"https://token.example.com/"}'), False)
        )
    )
    assert_true("neither" in _refusal(_file_json(String("{}"), False)))
    var wf = _file_json(_file_source(), False).replace(
        '"type":', '"workforce_pool_user_project":"p","type":'
    )
    assert_true("workforce_pool_user_project" in _refusal(wf))


def test_endpoints_must_be_bare_https_hosts() raises:
    """A credential is sent to each, so each is checked before any dial."""
    var good = _file_json(_file_source(), True)
    assert_true(
        "\"token_url\" that is not https"
        in _refusal(good.replace("https://sts.", "http://sts."))
    )
    assert_true(
        "a port, a query" in _refusal(good.replace("/v1/token", "/v1/token?x=1"))
    )
    assert_true(
        "a port, a query"
        in _refusal(good.replace("sts.googleapis.com", "sts.googleapis.com:8443"))
    )
    assert_true(
        "generateAccessToken" in _refusal(good.replace(":generateAccessToken", ":signJwt"))
    )
    var injected = _file_json(
        String('{"url":"https://token.example.com/","headers":{"X-A":"v\\r\\nHost: x"}}'),
        False,
    )
    var msg = _refusal(injected)
    assert_true("control byte" in msg, msg)
    assert_false("Host: x" in msg, msg)


def test_a_refused_exchange_never_dials_iam_credentials() raises:
    """An STS 400 raises naming the status and the allow-listed code, and
    IAM Credentials sees no byte."""
    var caps = Caps()
    var f = Fetcher(
        parse_external_account(_file_json(_file_source(), True)),
        _client(_plain(List[UInt8](), caps.source)),
        _client(
            _tls(
                _http(
                    String("400 Bad Request"),
                    String('{"error":"invalid_grant","error_description":"aud x"}'),
                ),
                caps.sts,
            )
        ),
        _client(_tls(_iam_ok(), caps.iam)),
        _files(),
        FixedWallClock(Int64(NOW_S)),
    )
    var msg = String("")
    try:
        _ = f.fetch(Int64(NOW_MS))
    except e:
        msg = String(e)
    assert_true("external account federation refused" in msg, msg)
    assert_true("OAuth error invalid_grant" in msg, msg)
    assert_false(OIDC in msg, msg)
    assert_true(len(caps.sts[]) > 0)
    assert_equal(len(caps.iam[]), 0)


def main() raises:
    test_file_subject_without_impersonation_is_the_sts_token()
    test_file_subject_with_impersonation_returns_the_impersonated_token()
    test_impersonation_sends_the_callers_scope_and_sts_cloud_platform()
    test_url_subject_without_impersonation_is_the_sts_token()
    test_url_subject_with_impersonation_returns_the_impersonated_token()
    test_a_refused_source_url_never_dials_sts()
    test_each_required_field_absent_is_refused_by_name()
    test_other_types_and_sources_are_refused()
    test_endpoints_must_be_bare_https_hosts()
    test_a_refused_exchange_never_dials_iam_credentials()
    print("OK")
