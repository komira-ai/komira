# =============================================================================
# komira_gcp_wif/tests/test_fetch_failures.mojo — the fetchers' and the
#   minter's failure paths on the wire, over komira_http_core's
#   ScriptedConnector, each beside its positive control.
# =============================================================================
#
#   §1 WifTokenMinter with a token source that returns "": refused before
#      any byte reaches IAM Credentials; the control, a non-empty static
#      token, is sent as the one bearer.
#   §2 ExternalAccountFetcher with a credential_source file that cannot be
#      read: refused before STS is dialed; the control, the same file
#      present, is exchanged.
#   §3 ExternalAccountFetcher whose impersonation is refused: the message
#      names the RPC, the status and the code, and holds neither the
#      federated token it sent nor a byte of the body; the 2xx range ends
#      at 299 (a 300 with a token-shaped body is refused, a 299 accepted),
#      and PostReply.is_success at 199/200/299/300; a token file's trailing
#      newline reaches the STS form.
#      A refused STS exchange appends an OAuth code only when the
#      body names a listed one (the whole message, both ways).
#      The credential_source URL's 2xx range ends at 299 too.
#   §4 AwsWifTokenFetcher's `audience` and `set_scope`: the scope set is the
#      one on the wire, the default is not.
#
# Every host dialed is an address of 192.0.2.0/24 (RFC 5737), which the
# client parses rather than resolves; the scripted connectors report TLS and
# run no handshake. Every response is SYNTHETIC; the tokens are made up.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_gcp_core import (
    FixedWallClock,
    GcpTokenSource,
    MapFiles,
    StaticTokenSource,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_gcp_wif._post import PostReply
from komira_gcp_wif import (
    AwsWifTokenFetcher,
    ExternalAccountFetcher,
    JWT_SUBJECT_TOKEN_TYPE,
    WifTokenMinter,
    parse_external_account,
)


comptime TIMEOUT_US: Int = 5_000_000
comptime NOW_S: Int = 1_790_856_000  # 2026-10-01T12:00:00Z
comptime NOW_MS: Int = 9_000
comptime SA = "signer@demo-project.example.test"
comptime JWT_AUD = "https://ingest.example.test"
comptime SIGNED = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJmYWtlIn0.SIGNATURE-FAKE"
comptime STATIC = "ya29.STATIC-FAKE"
comptime FEDERATED = "ya29.FEDERATED-FAKE"
comptime OIDC = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJjaSJ9.OIDC-FAKE"
comptime TOKEN_FILE = "/run/ci/oidc-token"
comptime AUDIENCE = (
    "//iam.example.test/projects/1/locations/global/"
    "workloadIdentityPools/pool/providers/provider"
)
comptime IMP_PATH = (
    "/v1/projects/-/serviceAccounts/deployer@demo-project.example.test"
    ":generateAccessToken"
)

comptime EaFetcher = ExternalAccountFetcher[
    ScriptedConnector, ScriptedConnector, MapFiles, FixedWallClock
]
comptime AwsFetcher = AwsWifTokenFetcher[
    ScriptedConnector, StaticCredsSource, FixedClock
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


def _capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _text(cap: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(cap[]))


def _tls_client(
    var script: List[UInt8], shared: ArcPointer[List[UInt8]]
) -> HttpClient[ScriptedConnector]:
    return HttpClient[ScriptedConnector].with_request_timeout_us(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(script^, shared)
        ),
        TIMEOUT_US,
    )


def _body_of(req: String) -> String:
    var at = req.find("\r\n\r\n")
    if at < 0:
        return String("")
    return String(req[byte = at + 4 :])


def _form_value(body: String, key: String) -> String:
    """The raw (still encoded) value of `key` in a form body, or "<absent>"."""
    var parts = body.split("&")
    for i in range(len(parts)):
        var p = String(parts[i])
        if p.startswith(key + "="):
            return String(p[byte = key.byte_length() + 1 :])
    return String("<absent>")


# =============================================================================
# §1 — an empty bearer is never sent.
# =============================================================================


struct EmptyTokenSource(GcpTokenSource, Movable, Deinitable):
    """A source that answers "" and counts how often it was asked."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def access_token(mut self) raises -> String:
        self.calls += 1
        return String("")


def test_an_empty_bearer_never_dials_signjwt() raises:
    """The control first: a static token reaches IAM Credentials as the
    bearer and the signed JWT comes back. The same minter over a source
    answering "" raises before IAM Credentials sees a byte, after asking
    the source once."""
    var ok_cap = _capture()
    var ok = WifTokenMinter[ScriptedConnector, StaticTokenSource, FixedClock](
        _tls_client(
            _http(String("200 OK"), String('{"keyId":"k","signedJwt":"') + SIGNED + '"}'),
            ok_cap,
        ),
        StaticTokenSource(String(STATIC)),
        FixedClock(NOW_S),
    )
    ok.set_iam_host(String("192.0.2.10"))
    assert_equal(ok.mint_jwt(String(SA), String(JWT_AUD)), SIGNED)
    assert_true(
        (String("\r\nauthorization: Bearer ") + STATIC + "\r\n") in _text(ok_cap),
        _text(ok_cap),
    )

    var cap = _capture()
    var m = WifTokenMinter[ScriptedConnector, EmptyTokenSource, FixedClock](
        _tls_client(
            _http(String("200 OK"), String('{"keyId":"k","signedJwt":"') + SIGNED + '"}'),
            cap,
        ),
        EmptyTokenSource(),
        FixedClock(NOW_S),
    )
    m.set_iam_host(String("192.0.2.10"))
    with assert_raises(
        contains="komira_gcp_wif: the token source returned an empty token"
    ):
        _ = m.mint_jwt(String(SA), String(JWT_AUD))
    assert_equal(m.tokens().calls, 1)
    assert_equal(len(cap[]), 0)
    # Two faults at once (no audience, an empty source): the audience is
    # reported, and the source is not asked.
    with assert_raises(contains="komira_gcp_wif: the JWT audience is empty"):
        _ = m.mint_jwt(String(SA), String(""))
    assert_equal(m.tokens().calls, 1)
    assert_equal(len(cap[]), 0)


# =============================================================================
# §2 and §3 — the external_account fetcher.
# =============================================================================


def _ea_text(impersonate: Bool) -> String:
    var out = (
        String('{"type":"external_account","audience":"') + AUDIENCE
        + '","subject_token_type":"' + JWT_SUBJECT_TOKEN_TYPE
        + '","token_url":"https://192.0.2.1/v1/token",'
    )
    if impersonate:
        out += (
            String('"service_account_impersonation_url":"https://192.0.2.2')
            + IMP_PATH + '",'
        )
    out += String('"credential_source":{"file":"') + TOKEN_FILE + '"}}'
    return out^


def _ea_fetcher(
    impersonate: Bool,
    var files: MapFiles,
    sts_cap: ArcPointer[List[UInt8]],
    var iam_script: List[UInt8],
    iam_cap: ArcPointer[List[UInt8]],
) raises -> EaFetcher:
    return EaFetcher(
        parse_external_account(_ea_text(impersonate)),
        _tls_client(List[UInt8](), _capture()),
        _tls_client(_sts_ok(), sts_cap),
        _tls_client(iam_script^, iam_cap),
        files^,
        FixedWallClock(Int64(NOW_S)),
    )


def _with_token_file() -> MapFiles:
    var f = MapFiles()
    f.put(String(TOKEN_FILE), String(OIDC))
    return f^


def test_an_unreadable_source_file_never_dials_sts() raises:
    """The control first: the file present is the subject token STS gets,
    and the federated token is returned. With no file at that path, the
    fetch raises before STS sees a byte."""
    var sts_ok_cap = _capture()
    var ok = _ea_fetcher(
        False, _with_token_file(), sts_ok_cap, List[UInt8](), _capture()
    )
    assert_equal(ok.fetch(Int64(NOW_MS)).token, FEDERATED)
    assert_equal(_form_value(_body_of(_text(sts_ok_cap)), String("subject_token")), OIDC)

    var sts_cap = _capture()
    var f = _ea_fetcher(False, MapFiles(), sts_cap, List[UInt8](), _capture())
    var msg = String("NOT REFUSED")
    try:
        _ = f.fetch(Int64(NOW_MS))
    except e:
        msg = String(e)
    # The whole message: the path the file names is not repeated.
    assert_equal(msg, "komira_gcp_wif: the credential_source file cannot be read")
    assert_equal(len(sts_cap[]), 0)


def _impersonation_failure(status_line: String, body: String) raises -> String:
    var sts_cap = _capture()
    var iam_cap = _capture()
    var f = _ea_fetcher(
        True, _with_token_file(), sts_cap, _http(status_line, body), iam_cap
    )
    var msg = String("NOT REFUSED")
    try:
        _ = f.fetch(Int64(NOW_MS))
    except e:
        msg = String(e)
    # Both legs were dialed: the federated token went to IAM Credentials.
    assert_true(len(sts_cap[]) > 0)
    var iam = _text(iam_cap)
    assert_true(iam.startswith(String("POST ") + IMP_PATH + " HTTP/1.1\r\n"), iam)
    assert_true(
        (String("\r\nauthorization: Bearer ") + FEDERATED + "\r\n") in iam, iam
    )
    return msg^


def test_a_refused_impersonation_names_the_status_not_the_token() raises:
    """A 403 with a google.rpc.Status and a 500 with no body: each raises
    `service account impersonation refused: POST
    IAMCredentials.GenerateAccessToken: HTTP <n>`, with neither the
    federated token nor the body's message in it. The success control is
    test_external_account's impersonation case."""
    var denied = _impersonation_failure(
        String("403 Forbidden"),
        String(
            '{"error":{"code":403,"message":"SECRET-DETAIL-IN-BODY",'
            '"status":"PERMISSION_DENIED"}}'
        ),
    )
    assert_true(
        denied.startswith(
            "komira_gcp_wif: service account impersonation refused: POST"
            " IAMCredentials.GenerateAccessToken: HTTP 403"
        ),
        denied,
    )
    assert_true("PERMISSION_DENIED" in denied, denied)
    assert_false(FEDERATED in denied, denied)
    assert_false("SECRET-DETAIL" in denied, denied)

    var down = _impersonation_failure(String("500 Internal Server Error"), String(""))
    assert_true(
        down.startswith(
            "komira_gcp_wif: service account impersonation refused: POST"
            " IAMCredentials.GenerateAccessToken: HTTP 500"
        ),
        down,
    )
    assert_false(FEDERATED in down, down)

    # A refusal whose body reads as a token answer is still a refusal: the
    # status is checked before the body is read.
    var shaped = _impersonation_failure(
        String("403 Forbidden"),
        String('{"accessToken":"ya29.NOT-A-GRANT","expireTime":"2026-10-01T13:00:00Z"}'),
    )
    assert_true(
        shaped.startswith("komira_gcp_wif: service account impersonation refused: "),
        shaped,
    )
    assert_false("NOT-A-GRANT" in shaped, shaped)


def _impersonation_answer(status_line: String, body: String) raises -> String:
    """`TOKEN <token> EXPIRES <ms>` for an accepted impersonation answer, the
    error text for a refused one."""
    var f = _ea_fetcher(
        True, _with_token_file(), _capture(), _http(status_line, body), _capture()
    )
    try:
        var t = f.fetch(Int64(NOW_MS))
        return String("TOKEN ") + t.token + " EXPIRES " + String(t.expires_at_ms)
    except e:
        return String(e)


def test_the_2xx_range_ends_at_299() raises:
    """The same body, one that reads as a valid generateAccessToken answer
    expiring an hour after the wall clock: under `299` it is the token;
    under `300 Multiple Choices` it is a refusal naming HTTP 300 and not the
    token (the client follows no redirect, so a 300 is the final answer)."""
    var shaped = String(
        '{"accessToken":"ya29.EDGE-FAKE","expireTime":"2026-10-01T13:00:00Z"}'
    )
    assert_equal(
        _impersonation_answer(String("299 Edge"), shaped),
        String("TOKEN ya29.EDGE-FAKE EXPIRES ") + String(NOW_MS + 3_600_000),
    )
    var three = _impersonation_answer(String("300 Multiple Choices"), shaped)
    assert_true(
        three.startswith(
            "komira_gcp_wif: service account impersonation refused: POST"
            " IAMCredentials.GenerateAccessToken: HTTP 300"
        ),
        three,
    )
    assert_false("EDGE-FAKE" in three, three)


def test_post_reply_success_is_exactly_200_to_299() raises:
    """`PostReply.is_success` at both edges of the range, on the struct (a
    1xx never reaches it over the wire: the client reads it as interim)."""
    var cases: List[Int] = [199, 200, 299, 300]
    var want: List[Bool] = [False, True, True, False]
    for i in range(len(cases)):
        assert_equal(
            PostReply(cases[i], List[UInt8]()).is_success(), want[i], String(cases[i])
        )


def test_a_trailing_newline_in_the_token_file_is_sent() raises:
    """A token file written by `echo` ends in a newline. The reference
    strips nothing, so the newline is part of the subject token on the STS
    form (`%0A`), not dropped."""
    var files = MapFiles()
    files.put(String(TOKEN_FILE), String(OIDC) + "\n")
    var sts_cap = _capture()
    var f = _ea_fetcher(False, files^, sts_cap, List[UInt8](), _capture())
    assert_equal(f.fetch(Int64(NOW_MS)).token, FEDERATED)
    assert_equal(
        _form_value(_body_of(_text(sts_cap)), String("subject_token")),
        String(OIDC) + "%0A",
    )


def _url_source_fetch(status_line: String) raises -> String:
    """A text-mode `credential_source.url` (plain http) answering
    `status_line` with the OIDC token as its body: `SUBJECT <subject_token
    on the STS form>` when the fetch succeeds, the error text when it does
    not (then STS must not have been dialed)."""
    var text = (
        String('{"type":"external_account","audience":"') + AUDIENCE
        + '","subject_token_type":"' + JWT_SUBJECT_TOKEN_TYPE
        + '","token_url":"https://192.0.2.1/v1/token",'
        + '"credential_source":{"url":"http://192.0.2.9/token"}}'
    )
    var sts_cap = _capture()
    var f = EaFetcher(
        parse_external_account(text),
        HttpClient[ScriptedConnector].with_request_timeout_us(
            ScriptedConnector.with_stream(
                ScriptedStream.from_read_script_with_capture(
                    _http(status_line, String(OIDC)), _capture()
                )
            ),
            TIMEOUT_US,
        ),
        _tls_client(_sts_ok(), sts_cap),
        _tls_client(List[UInt8](), _capture()),
        MapFiles(),
        FixedWallClock(Int64(NOW_S)),
    )
    try:
        assert_equal(f.fetch(Int64(NOW_MS)).token, FEDERATED)
    except e:
        assert_equal(len(sts_cap[]), 0)
        return String(e)
    return String("SUBJECT ") + _form_value(
        _body_of(_text(sts_cap)), String("subject_token")
    )


def test_the_source_urls_2xx_range_ends_at_299() raises:
    """The credential_source URL's answer is the subject token only under a
    2xx status: under `299` its body goes to STS; under `300 Multiple
    Choices` (a final answer: the client follows no redirect) the same body
    is refused, naming the status alone, and STS is never dialed."""
    assert_equal(_url_source_fetch(String("299 Edge")), String("SUBJECT ") + OIDC)
    assert_equal(
        _url_source_fetch(String("300 Multiple Choices")),
        "komira_gcp_wif: the credential_source url answered HTTP 300",
    )


def _sts_refusal(status_line: String, body: String) raises -> String:
    """What a fetch raises when STS answers `status_line` with `body` (the
    file names no impersonation, so IAM Credentials is never dialed)."""
    var f = EaFetcher(
        parse_external_account(_ea_text(False)),
        _tls_client(List[UInt8](), _capture()),
        _tls_client(_http(status_line, body), _capture()),
        _tls_client(List[UInt8](), _capture()),
        _with_token_file(),
        FixedWallClock(Int64(NOW_S)),
    )
    try:
        _ = f.fetch(Int64(NOW_MS))
    except e:
        return String(e)
    return String("NOT REFUSED")


def test_a_refused_exchange_adds_only_a_listed_oauth_code() raises:
    """The whole refusal of the STS exchange. The control: a 400 whose body
    is an RFC 6749 error with a listed code ends `, OAuth error
    invalid_grant`. A 401 whose body names no `error`, and a 503 with no
    body, end at komira_gcp_core's status text: nothing is appended, not
    even the separator, and no byte of `error_description` is repeated."""
    var P = String("komira_gcp_wif: external account federation refused: POST sts.v1.token: HTTP ")
    var NO_ENV = String(", no google.rpc.Status envelope, body ")
    var coded = String('{"error":"invalid_grant","error_description":"SECRET-DESC"}')
    assert_equal(
        _sts_refusal(String("400 Bad Request"), coded),
        String(P) + "400, INVALID_ARGUMENT (code 3)" + NO_ENV
        + String(coded.byte_length()) + " bytes, OAuth error invalid_grant",
    )
    var uncoded = String('{"error_description":"SECRET-DESC"}')
    var msg = _sts_refusal(String("401 Unauthorized"), uncoded)
    assert_equal(
        msg,
        String(P) + "401, UNAUTHENTICATED (code 16)" + NO_ENV
        + String(uncoded.byte_length()) + " bytes",
    )
    assert_false("SECRET-DESC" in msg, msg)
    var empty = _sts_refusal(String("503 Service Unavailable"), String(""))
    assert_true(empty.startswith(String(P) + "503, UNAVAILABLE (code 14)"), empty)
    assert_false(empty.endswith(","), empty)
    assert_false(empty.endswith(", "), empty)
    assert_false("OAuth" in empty, empty)


# =============================================================================
# §4 — the AWS fetcher's audience and scope.
# =============================================================================


def _aws_fetcher(var client: HttpClient[ScriptedConnector]) raises -> AwsFetcher:
    var f = AwsFetcher(
        client^,
        StaticCredsSource(
            AwsCredential(
                String("AKIAIOSFODNN7EXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
                String("EXAMPLE-SESSION-TOKEN"),
            )
        ),
        FixedClock(NOW_S),
        String("us-east-1"),
        String(AUDIENCE),
    )
    f.set_sts_host(String("192.0.2.1"))
    return f^


comptime SCOPE = "https://scope.example.test/auth/read only"
comptime SCOPE_FORM = "https%3A%2F%2Fscope.example.test%2Fauth%2Fread%20only"


def test_the_aws_fetchers_audience_and_scope() raises:
    """`audience()` is the audience given. Without `set_scope` the form's
    scope is the default (cloud-platform); after it, the scope set,
    form-encoded, and the default is gone."""
    var default_cap = _capture()
    var d = _aws_fetcher(_tls_client(_sts_ok(), default_cap))
    assert_equal(d.audience(), AUDIENCE)
    assert_equal(d.fetch(Int64(NOW_MS)).token, FEDERATED)
    var default_scope = _form_value(_body_of(_text(default_cap)), String("scope"))
    assert_true(default_scope.endswith("%2Fauth%2Fcloud-platform"), default_scope)

    var cap = _capture()
    var f = _aws_fetcher(_tls_client(_sts_ok(), cap))
    f.set_scope(String(SCOPE))
    assert_equal(f.fetch(Int64(NOW_MS)).token, FEDERATED)
    var body = _body_of(_text(cap))
    assert_equal(_form_value(body, String("scope")), SCOPE_FORM)
    assert_false("cloud-platform" in body, body)


def main() raises:
    test_an_empty_bearer_never_dials_signjwt()
    test_an_unreadable_source_file_never_dials_sts()
    test_a_refused_impersonation_names_the_status_not_the_token()
    test_the_2xx_range_ends_at_299()
    test_post_reply_success_is_exactly_200_to_299()
    test_a_trailing_newline_in_the_token_file_is_sent()
    test_a_refused_exchange_adds_only_a_listed_oauth_code()
    test_the_source_urls_2xx_range_ends_at_299()
    test_the_aws_fetchers_audience_and_scope()
