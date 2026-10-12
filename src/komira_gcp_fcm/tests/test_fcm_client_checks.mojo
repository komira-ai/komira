# =============================================================================
# komira_gcp_fcm/tests/test_fcm_client_checks.mojo -- client.mojo's checks
#   that run before anything is sent: the endpoint's host and port, the
#   token-error and transport-error readers, and `send_one`'s order.
# =============================================================================
#
# No request reaches a server here. Where a client is built, its endpoint is
# 127.0.0.1 on a port that was just bound and released, so a client that
# sent anyway would come back with a TRANSIENT outcome (connection refused)
# instead of the raise each test asserts.
#
# Each test is run by `main` on its own and every failure is printed before
# the run fails, and each case of a test is checked even after another case
# of it fails, so one broken check does not hide another.
#
# What each test proves, and the defect it catches:
#   * test_https_host_bytes: `FcmEndpoint.https` keeps a host of `a`, `z`,
#     `0`, `9`, `.` and `-` and turns down an empty host and each byte just
#     outside a range (`` ` `` `{` `/` `:`) and an upper-case letter.
#     Catches an off-by-one at either end of a range and a lost `.` or `-`
#     (a host check that let `:` or `/` through would let the endpoint name
#     another host or port, to which the bearer token is sent).
#   * test_endpoint_ports_and_urls: port 0 is refused by `https` and
#     `loopback_plaintext`, port 1 is not; an empty host with port 0 is
#     refused for the host first; `url` gives https for a TLS endpoint and
#     http for 127.0.0.1, and refuses a plaintext endpoint for 192.0.2.1.
#   * test_token_status_reading: `token_mint_error` keeps only three digits
#     after the first `HTTP `: `HTTP 409` is 409 (both digit ends),
#     `HTTP 4031` is 403, `HTTP 4x3`, `HTTP 40/` and `HTTP 40:` (bytes
#     just outside 0-9) and a bare `HTTP ` have no status, `http 403` has
#     none, and of two statuses the first is named.
#   * test_transport_kind_bounds: `send_failure_outcome` keeps a tag of 54
#     bytes (`]` 64 bytes after `HttpError[` starts) and drops one of 55; a
#     tag with no `]` is `transport error`; a `]` before the tag does not
#     end it; `HttpError[URL_INVALID_X]` is not URL_INVALID (the match is
#     exact, not a prefix).
#   * test_send_one_order: the body is checked before the URL, the URL before
#     the token source is asked (counted: 0 asks), a token source that
#     returns "" raises `empty token; nothing was sent` after one ask, and
#     one that raises names only its status. Catches a token asked for a
#     request that was going to be refused, and an empty bearer sent.
#   * test_accessors: `tokens()` is the client's own source (its ask count
#     moves) and `endpoint()` is a copy of the client's endpoint.
#   * test_constructor_refusal: `FcmClient` refuses a project id holding a
#     `/` when it is built, not at the first send.
# =============================================================================

from std.testing import assert_equal

from komira_gcp_core import GcpTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.codec import HttpMethod
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_gcp_fcm import (
    FcmClient,
    FcmEndpoint,
    FcmWake,
    fcm_outcome_name,
    send_failure_outcome,
    token_mint_error,
)


comptime _PROJECT = "example-project-123"
comptime _NOTHING_SENT_TOKEN = "komira_gcp_fcm: no access token ("


@fieldwise_init
struct _CountingSource(GcpTokenSource, Movable, Deinitable):
    """Answers `token`, or raises `fail` when it is non-empty; counts asks."""

    var token: String
    var fail: String
    var asks: Int

    def access_token(mut self) raises -> String:
        self.asks += 1
        if self.fail.byte_length() > 0:
            raise Error(self.fail)
        return self.token.copy()


comptime _Client = FcmClient[KernelTcpConnector, _CountingSource]


def _closed_port() raises -> UInt16:
    """A loopback port that was just bound and released."""
    var router = Router()
    router.add(HttpMethod.post(), "/", 0)
    var s = HttpServer(config=HttpServerConfig.default_ephemeral(), router=router^)
    var port = s.local_port()
    _ = s^
    return port


def _client(var source: _CountingSource, var endpoint: FcmEndpoint) raises -> _Client:
    return _Client(
        HttpClient[KernelTcpConnector].with_request_timeout_us(
            KernelTcpConnector.new(), 5_000_000
        ),
        source^,
        String(_PROJECT),
        endpoint^,
    )


def _wake() -> FcmWake:
    return FcmWake(
        String("evt-2026-10-01-0001"), String("message"), String("inbox.example.com")
    )


def _https_refusal(host: String, port: UInt16) -> String:
    try:
        var e = FcmEndpoint.https(host, port)
        return String("<kept ") + e.host + ":" + String(Int(e.port)) + ">"
    except e:
        return String(e)


def _send_refusal(mut c: _Client, token: String) -> String:
    try:
        var o = c.send_one(token, _wake())
        return String("<an outcome: ") + fcm_outcome_name(o.kind) + " " + o.detail + ">"
    except e:
        return String(e)


def _mint(text: String) -> String:
    var s = String(token_mint_error(text))
    var start = s.find(_NOTHING_SENT_TOKEN)
    var end = s.find(")")
    if start != 0 or end < 0:
        return String("<unexpected: ") + s + ">"
    return String(s[byte = String(_NOTHING_SENT_TOKEN).byte_length() : end])


def _no_answer_detail(text: String) raises -> String:
    var o = send_failure_outcome(text)
    assert_equal(fcm_outcome_name(o.kind), "TRANSIENT", text)
    assert_equal(o.http_status, 0, text)
    return o.detail



def _eq[T: Equatable & Writable](
    mut bad: List[String], got: T, want: T, what: String = ""
):
    """Records a mismatch instead of stopping, so every case of a table runs
    and a failure names each case that went wrong."""
    if not (got == want):
        bad.append(what + " (got " + String(got) + ", want " + String(want) + ")")


def _done(bad: List[String]) raises:
    if len(bad) > 0:
        var all = String()
        for i in range(len(bad)):
            all += "\n    MISMATCH " + bad[i]
        raise Error(String(len(bad)) + " mismatch(es):" + all)

# -----------------------------------------------------------------------------


def test_https_host_bytes() raises:
    var bad = List[String]()
    comptime OUTSIDE = "komira_gcp_fcm: the FCM host holds a byte outside [a-z0-9.-]"
    _eq(bad, _https_refusal(String("az09.-"), 443), "<kept az09.-:443>")
    _eq(bad, _https_refusal(String("a"), 443), "<kept a:443>", "a")
    _eq(bad, _https_refusal(String("z"), 443), "<kept z:443>", "z")
    _eq(bad, _https_refusal(String("0"), 443), "<kept 0:443>", "0")
    _eq(bad, _https_refusal(String("9"), 443), "<kept 9:443>", "9")
    _eq(bad, _https_refusal(String("."), 443), "<kept .:443>", ".")
    _eq(bad, _https_refusal(String("-"), 443), "<kept -:443>", "-")
    _eq(bad,
        _https_refusal(String(), 443), "komira_gcp_fcm: the FCM host is empty"
    )
    _eq(bad, _https_refusal(String("a`"), 443), OUTSIDE, "` sits just below a")
    _eq(bad, _https_refusal(String("z{"), 443), OUTSIDE, "{ sits just above z")
    _eq(bad, _https_refusal(String("0/"), 443), OUTSIDE, "/ sits just below 0")
    _eq(bad, _https_refusal(String("9:"), 443), OUTSIDE, ": sits just above 9")
    _eq(bad, _https_refusal(String("Fcm.example.com"), 443), OUTSIDE, "upper case")
    _eq(bad,
        _https_refusal(String("proxy.example.com:8443"), 443), OUTSIDE, "a port in the host"
    )
    _done(bad)


def test_endpoint_ports_and_urls() raises:
    var bad = List[String]()
    _eq(bad,
        _https_refusal(String("proxy.example.com"), 0),
        "komira_gcp_fcm: the FCM port is 0",
    )
    _eq(bad, _https_refusal(String("proxy.example.com"), 1), "<kept proxy.example.com:1>")
    _eq(bad,
        _https_refusal(String(), 0),
        "komira_gcp_fcm: the FCM host is empty",
        "the host is checked before the port",
    )
    var lo = FcmEndpoint.loopback_plaintext(1)
    _eq(bad, lo.host, "127.0.0.1")
    _eq(bad, Int(lo.port), 1)
    _eq(bad, lo.tls, False, "loopback is plaintext")
    var lu = lo.url(String("/v1/x"))
    _eq(bad, lu.scheme, "http")
    _eq(bad, lu.host, "127.0.0.1")
    _eq(bad, Int(lu.port), 1)
    _eq(bad, lu.path, "/v1/x")
    var tu = FcmEndpoint.https(String("proxy.example.com"), 8443).url(String("/v1/y"))
    _eq(bad, tu.scheme, "https")
    _eq(bad, tu.host, "proxy.example.com")
    _eq(bad, Int(tu.port), 8443)
    _eq(bad, tu.path, "/v1/y")
    var msg = String("<not refused>")
    try:
        _ = FcmEndpoint(String("192.0.2.1"), 80, False).url(String("/v1/z"))
    except e:
        msg = String(e)
    _eq(bad,
        msg,
        "komira_gcp_fcm: plain http is only for 127.0.0.1; the bearer token"
        " would cross the network in clear",
    )
    _done(bad)


def test_token_status_reading() raises:
    var bad = List[String]()
    _eq(bad, _mint(String("answered HTTP 409")), "HTTP 409", "both digit ends")
    _eq(bad, _mint(String("answered HTTP 4031 x")), "HTTP 403", "three digits at most")
    _eq(bad, _mint(String("answered HTTP 4x3")), "no HTTP status", "a letter")
    _eq(bad, _mint(String("answered HTTP 40/")), "no HTTP status", "/ sits below 0")
    _eq(bad, _mint(String("answered HTTP 40:")), "no HTTP status", ": sits above 9")
    _eq(bad, _mint(String("answered HTTP ")), "no HTTP status", "nothing after")
    _eq(bad, _mint(String("answered http 403")), "no HTTP status", "lower case")
    _eq(bad,
        _mint(String("answered HTTP 503 after HTTP 401")), "HTTP 503", "the first"
    )
    _done(bad)


def test_transport_kind_bounds() raises:
    var bad = List[String]()
    comptime NO_ANSWER = "POST FirebaseMessaging.SendMessage: no answer, "
    var tag54 = String("HttpError[") + _rep(String("K"), 54) + "]"
    _eq(bad,
        _no_answer_detail(tag54 + ": 127.0.0.1:9"),
        String(NO_ANSWER) + tag54,
        "a 54-byte kind is kept",
    )
    var tag55 = String("HttpError[") + _rep(String("K"), 55) + "]"
    _eq(bad,
        _no_answer_detail(tag55 + ": 127.0.0.1:9"),
        String(NO_ANSWER) + "transport error",
        "a 55-byte kind is not",
    )
    _eq(bad,
        _no_answer_detail(String("HttpError[TIMEOUT after 30 s")),
        String(NO_ANSWER) + "transport error",
        "no closing bracket",
    )
    _eq(bad,
        _no_answer_detail(String("[a] HttpError[TIMEOUT]: x")),
        String(NO_ANSWER) + "HttpError[TIMEOUT]",
        "a bracket before the tag",
    )
    _eq(bad,
        _no_answer_detail(String("HttpError[URL_INVALID_X]: x")),
        String(NO_ANSWER) + "HttpError[URL_INVALID_X]",
        "URL_INVALID is matched whole",
    )
    _done(bad)


def _rep(c: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += c
    return out^


def test_send_one_order() raises:
    var bad = List[String]()
    var port = _closed_port()
    # The body is checked first: an empty device token is refused with the
    # URL also bad and the token source failing.
    var c1 = _client(
        _CountingSource(String("ya29.T"), String("answered HTTP 500"), 0),
        FcmEndpoint(String("192.0.2.1"), port, False),
    )
    _eq(bad, _send_refusal(c1, String()), "komira_gcp_fcm: the device token is empty")
    _eq(bad, c1.tokens().asks, 0, "no token asked for a refused body")
    # The URL before the token.
    _eq(bad,
        _send_refusal(c1, String("tok-ok")),
        "komira_gcp_fcm: plain http is only for 127.0.0.1; the bearer token"
        " would cross the network in clear",
    )
    _eq(bad, c1.tokens().asks, 0, "no token asked for a refused URL")
    # A failing source: one ask, its status only.
    var c2 = _client(
        _CountingSource(String("ya29.T"), String("answered HTTP 500: SECRET"), 0),
        FcmEndpoint.loopback_plaintext(port),
    )
    _eq(bad,
        _send_refusal(c2, String("tok-ok")),
        "komira_gcp_fcm: no access token (HTTP 500); nothing was sent",
    )
    _eq(bad, c2.tokens().asks, 1)
    # An empty bearer is never sent.
    var c3 = _client(
        _CountingSource(String(), String(), 0), FcmEndpoint.loopback_plaintext(port)
    )
    _eq(bad,
        _send_refusal(c3, String("tok-ok")),
        "komira_gcp_fcm: the token source returned an empty token; nothing was sent",
    )
    _eq(bad, c3.tokens().asks, 1)
    # Positive control: the same client with a token does dial, and the
    # closed port comes back as an outcome, not a raise.
    c3.tokens().token = String("ya29.T")
    var sent = _send_refusal(c3, String("tok-ok"))
    _eq(bad, sent.startswith("<an outcome: TRANSIENT "), True, sent)
    _eq(bad, c3.tokens().asks, 2)
    _done(bad)


def test_accessors() raises:
    var bad = List[String]()
    var c = _client(
        _CountingSource(String("ya29.T"), String(), 0),
        FcmEndpoint.https(String("proxy.example.com"), 8443),
    )
    _eq(bad, c.tokens().access_token(), "ya29.T")
    _eq(bad, c.tokens().asks, 1)
    var e = c.endpoint()
    _eq(bad, e.host, "proxy.example.com")
    _eq(bad, Int(e.port), 8443)
    _eq(bad, e.tls, True, "the copy is TLS")
    _done(bad)


def test_constructor_refusal() raises:
    var bad = List[String]()
    var msg = String("<not refused>")
    try:
        _ = _Client(
            HttpClient[KernelTcpConnector].with_request_timeout_us(
                KernelTcpConnector.new(), 5_000_000
            ),
            _CountingSource(String("ya29.T"), String(), 0),
            String("p/../other"),
            FcmEndpoint.loopback_plaintext(1),
        )
    except e:
        msg = String(e)
    _eq(bad,
        msg, "komira_gcp_fcm: the project id holds a byte outside [a-z0-9.:-]"
    )
    _done(bad)


def main() raises:
    var failed = List[String]()
    try:
        test_https_host_bytes()
    except e:
        failed.append(String("test_https_host_bytes: ") + String(e))
    try:
        test_endpoint_ports_and_urls()
    except e:
        failed.append(String("test_endpoint_ports_and_urls: ") + String(e))
    try:
        test_token_status_reading()
    except e:
        failed.append(String("test_token_status_reading: ") + String(e))
    try:
        test_transport_kind_bounds()
    except e:
        failed.append(String("test_transport_kind_bounds: ") + String(e))
    try:
        test_send_one_order()
    except e:
        failed.append(String("test_send_one_order: ") + String(e))
    try:
        test_accessors()
    except e:
        failed.append(String("test_accessors: ") + String(e))
    try:
        test_constructor_refusal()
    except e:
        failed.append(String("test_constructor_refusal: ") + String(e))
    for i in range(len(failed)):
        print("FAIL", failed[i])
    if len(failed) > 0:
        raise Error(String(len(failed)) + " test(s) of test_fcm_client_checks failed")
    print("PASS komira_gcp_fcm client checks")
