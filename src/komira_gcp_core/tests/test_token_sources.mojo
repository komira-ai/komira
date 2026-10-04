# =============================================================================
# test_token_sources.mojo — each token fetcher over komira_http_client.
# =============================================================================
#
# Every fetcher sends through `GcpConnectorTransport` — the production
# transport, komira_http_client's `HttpClient` on a `BlockingRuntime` — over
# a komira_http_core `ScriptedConnector`: canned HTTP/1.1 answers, every
# written byte captured, no socket and no name resolution (every host is an
# IP literal). Each case checks:
#
#   * the request on the wire, byte for byte, as komira_http_client sends
#     it: it puts `User-Agent` and `Content-Length` first, then the
#     builder's headers with their names in lower case;
#   * the answer read: the token, and `expires_in` as an expiry on the
#     caller's monotonic timeline;
#   * the error mapping: an HTTP failure names the endpoint, its status and
#     at most an RFC 6749 error code; a failed dial names the endpoint; no
#     error carries an assertion, a secret or a token.
#
# `CachingTokenSource` wraps a fetcher: a second request inside the token's
# life sends nothing, and one past the refresh margin dials again.
#
# The service-account key is Google's published dummy key, read from the
# conformance-tests archive //third_party/googleapis_conformance_tests pins
# (staged at conformance/), with its token_uri pointed at 127.0.0.1.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import (
    DEFAULT_REFRESH_BEFORE_MS,
    AuthorizedUserFetcher,
    CachingTokenSource,
    FixedWallClock,
    GcpConnectorTransport,
    MetadataServerFetcher,
    SelfSignedJwtFetcher,
    ServiceAccountKeyFetcher,
    authorized_user_from_json,
    jwt_grant_assertion,
    metadata_endpoint,
    parse_credentials_json,
    parse_service_account_key,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _T0: Int64 = 1_790_000_000
comptime _CLOUD = "https://www.googleapis.com/auth/cloud-platform"
comptime _TOKEN_PATH = "/computeMetadata/v1/instance/service-accounts/default/token"
comptime _OK_BODY = '{"access_token":"ya29.FROM-SERVER","expires_in":3599,"token_type":"Bearer"}'

comptime Transport = GcpConnectorTransport[ScriptedConnector]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> List[UInt8]:
    """A server answer that closes the connection after it."""
    return _bytes(
        String("HTTP/1.1 ")
        + String(status)
        + " "
        + reason
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _captured(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _plain(
    var script: List[UInt8], capture: ArcPointer[List[UInt8]]
) raises -> Transport:
    var c = ScriptedConnector()
    c.arm(ScriptedStream.from_read_script_with_capture(script^, capture))
    return Transport(HttpClientConfig.defaults(), c^)


def _tls(
    var script: List[UInt8], capture: ArcPointer[List[UInt8]]
) raises -> Transport:
    var c = ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(script^, capture)
    )
    return Transport(HttpClientConfig.defaults(), c^)


def _refused() raises -> Transport:
    """A connector whose one dial is refused (ECONNREFUSED)."""
    var c = ScriptedConnector()
    c.arm_connect_error(111)
    return Transport(HttpClientConfig.defaults(), c^)


def _scopes(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _wire_get(target: String, host: String, extra: String) -> String:
    """A GET as komira_http_client writes it from the builder's head."""
    return (
        String("GET ") + target + " HTTP/1.1\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: 0\r\n"
        + "host: " + host + "\r\n"
        + extra
        + "\r\n"
    )


# =============================================================================
# The metadata server
# =============================================================================


def test_metadata_fetch() raises:
    var capture = ArcPointer(List[UInt8]())
    var f = MetadataServerFetcher(
        _plain(_answer(200, "OK", _OK_BODY), capture),
        metadata_endpoint(String("127.0.0.1:8080")),
        _scopes(_CLOUD),
    )
    var tok = f.fetch(10_000)
    assert_equal(tok.token, "ya29.FROM-SERVER")
    assert_equal(tok.expires_at_ms, 10_000 + 3_599_000)
    assert_equal(
        _captured(capture),
        _wire_get(
            String(_TOKEN_PATH)
            + "?scopes=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform",
            String("127.0.0.1:8080"),
            String("metadata-flavor: Google\r\n"),
        ),
    )


def test_metadata_errors() raises:
    var url = String("http://127.0.0.1:8080") + _TOKEN_PATH
    var capture = ArcPointer(List[UInt8]())
    var f = MetadataServerFetcher(
        _plain(_answer(404, "Not Found", "no such account ya29.LEAK"), capture),
        metadata_endpoint(String("127.0.0.1:8080")),
        List[String](),
    )
    var msg = String("")
    try:
        _ = f.fetch(0)
    except e:
        msg = String(e)
    assert_equal(msg, "the metadata server at " + url + " answered HTTP 404")

    var g = MetadataServerFetcher(
        _refused(), metadata_endpoint(String("127.0.0.1:8080")), List[String]()
    )
    msg = String("")
    try:
        _ = g.fetch(0)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("the metadata server at " + url + " could not be reached: "),
        msg,
    )


def test_caching_source_wraps_a_fetcher() raises:
    var first = ArcPointer(List[UInt8]())
    var second = ArcPointer(List[UInt8]())
    var c = ScriptedConnector()
    c.arm(ScriptedStream.from_read_script_with_capture(_answer(200, "OK", _OK_BODY), first))
    c.arm_next(
        ScriptedStream.from_read_script_with_capture(
            _answer(200, "OK", '{"access_token":"ya29.SECOND","expires_in":3600}'),
            second,
        )
    )
    var src = CachingTokenSource(
        MetadataServerFetcher(
            Transport(HttpClientConfig.defaults(), c^),
            metadata_endpoint(String("127.0.0.1:8080")),
            List[String](),
        ),
        ManualClock(0),
    )
    assert_equal(src.access_token(), "ya29.FROM-SERVER")
    assert_equal(src.access_token(), "ya29.FROM-SERVER")
    assert_equal(src.fetches(), 1)
    assert_equal(len(second[]), 0)
    # 3599 s on, less the refresh margin: the next request dials again.
    src.clock().now = 3_599_000 - DEFAULT_REFRESH_BEFORE_MS
    assert_equal(src.access_token(), "ya29.SECOND")
    assert_equal(src.fetches(), 2)
    assert_true(len(second[]) > 0)


# =============================================================================
# A service-account key
# =============================================================================


def _local_key_text() raises -> String:
    var text: String
    with open(String(_ACCOUNT), "r") as f:
        text = f.read()
    return text.replace(
        "https://oauth2.googleapis.com/token", "https://127.0.0.1:8443/token"
    )


def test_service_account_fetch() raises:
    var key = parse_service_account_key(_local_key_text(), String("k.json"))
    var expected_jwt = jwt_grant_assertion(key, _scopes(_CLOUD), String(""), _T0)
    var capture = ArcPointer(List[UInt8]())
    var f = ServiceAccountKeyFetcher(
        _tls(_answer(200, "OK", _OK_BODY), capture),
        FixedWallClock(_T0),
        key^,
        _scopes(_CLOUD),
    )
    var tok = f.fetch(7)
    assert_equal(tok.token, "ya29.FROM-SERVER")
    assert_equal(tok.expires_at_ms, 7 + 3_599_000)
    var body = (
        String("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer")
        + "&assertion=" + expected_jwt
    )
    assert_equal(
        _captured(capture),
        String("POST /token HTTP/1.1\r\n")
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: " + String(body.byte_length()) + "\r\n"
        + "host: 127.0.0.1:8443\r\n"
        + "content-type: application/x-www-form-urlencoded\r\n"
        + "\r\n"
        + body,
    )


def test_service_account_errors() raises:
    var key = parse_service_account_key(_local_key_text(), String("k.json"))
    var capture = ArcPointer(List[UInt8]())
    var f = ServiceAccountKeyFetcher(
        _tls(
            _answer(
                400,
                "Bad Request",
                '{"error":"invalid_grant","error_description":"Invalid JWT Signature."}',
            ),
            capture,
        ),
        FixedWallClock(_T0),
        key.copy(),
        _scopes(_CLOUD),
    )
    var msg = String("")
    try:
        _ = f.fetch(0)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "the token endpoint https://127.0.0.1:8443/token answered HTTP 400"
        " (invalid_grant)",
    )
    # The grant needs a scope.
    msg = String("")
    try:
        _ = ServiceAccountKeyFetcher(
            _refused(), FixedWallClock(_T0), key.copy(), List[String]()
        )
    except e:
        msg = String(e)
    assert_equal(
        msg, "ServiceAccountKeyFetcher: the JWT bearer grant needs at least one scope"
    )
    # A failed dial names the endpoint, and nothing of the assertion.
    var g = ServiceAccountKeyFetcher(
        _refused(), FixedWallClock(_T0), key.copy(), _scopes(_CLOUD)
    )
    msg = String("")
    try:
        _ = g.fetch(0)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "the token endpoint https://127.0.0.1:8443/token could not be reached: "
        ),
        msg,
    )
    assert_false("eyJ" in msg, msg)


def test_self_signed_jwt_fetch() raises:
    var key = parse_service_account_key(_local_key_text(), String("k.json"))
    var f = SelfSignedJwtFetcher(
        FixedWallClock(_T0), key^, String("https://logging.googleapis.com/"), List[String]()
    )
    var tok = f.fetch(1_000)
    assert_true(tok.token.startswith("eyJ"), "a JWT")
    assert_equal(len(tok.token.split(".")), 3)
    assert_equal(tok.expires_at_ms, 1_000 + 3_600_000)


# =============================================================================
# An authorized_user file
# =============================================================================

comptime _USER = (
    '{"type":"authorized_user","client_id":"cid","client_secret":"CLIENT-SECRET",'
    '"refresh_token":"REFRESH-TOKEN","token_uri":"https://127.0.0.1:8443/token"}'
)


def test_authorized_user_fetch() raises:
    var user = authorized_user_from_json(
        parse_credentials_json(String(_USER), String("u.json")), String("u.json")
    )
    var capture = ArcPointer(List[UInt8]())
    var f = AuthorizedUserFetcher(
        _tls(_answer(200, "OK", _OK_BODY), capture), user^, List[String]()
    )
    var tok = f.fetch(3)
    assert_equal(tok.token, "ya29.FROM-SERVER")
    assert_equal(tok.expires_at_ms, 3 + 3_599_000)
    var body = String(
        "grant_type=refresh_token&client_id=cid&client_secret=CLIENT-SECRET"
        "&refresh_token=REFRESH-TOKEN"
    )
    assert_equal(
        _captured(capture),
        String("POST /token HTTP/1.1\r\n")
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: " + String(body.byte_length()) + "\r\n"
        + "host: 127.0.0.1:8443\r\n"
        + "content-type: application/x-www-form-urlencoded\r\n"
        + "\r\n"
        + body,
    )


def test_authorized_user_errors() raises:
    var user = authorized_user_from_json(
        parse_credentials_json(String(_USER), String("u.json")), String("u.json")
    )
    var capture = ArcPointer(List[UInt8]())
    var f = AuthorizedUserFetcher(
        _tls(
            _answer(
                400,
                "Bad Request",
                '{"error":"invalid_grant","error_description":"Token has been expired or revoked."}',
            ),
            capture,
        ),
        user^,
        List[String](),
    )
    var msg = String("")
    try:
        _ = f.fetch(0)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "the token endpoint https://127.0.0.1:8443/token answered HTTP 400"
        " (invalid_grant)",
    )
    assert_false("REFRESH-TOKEN" in msg or "CLIENT-SECRET" in msg, msg)


def main() raises:
    test_metadata_fetch()
    test_metadata_errors()
    test_caching_source_wraps_a_fetcher()
    test_service_account_fetch()
    test_service_account_errors()
    test_self_signed_jwt_fetch()
    test_authorized_user_fetch()
    test_authorized_user_errors()
    print("OK")
