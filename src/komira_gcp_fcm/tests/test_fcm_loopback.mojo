# =============================================================================
# komira_gcp_fcm/tests/test_fcm_loopback.mojo -- `FcmClient` over a real
#   socket, against a fake FCM on 127.0.0.1.
# =============================================================================
#
# `_FakeFcm` is a komira_http_server `RequestDispatcher` on an ephemeral
# loopback port. It records every request as it arrived (method, path, Host,
# Authorization, Content-Type, body) and answers by the registration token
# in the body, with FCM v1's error envelope (synthetic, in the documented
# shape):
#
#   tok-ok           200 {"name": ...}
#   tok-gone         404 NOT_FOUND, FcmError UNREGISTERED
#   tok-throttled    429 RESOURCE_EXHAUSTED, QUOTA_EXCEEDED, Retry-After: 7
#   tok-unavailable  503 UNAVAILABLE
#   tok-bad          400 INVALID_ARGUMENT
#   any request whose bearer is not `_BEARER`: 401 UNAUTHENTICATED
#
# and a GET is answered as a metadata server's token request: its target
# (path and query) and its `Metadata-Flavor` header are recorded, and the
# answer is `{"access_token":"<_BEARER>","expires_in":3599}`.
#
# The client leg runs on its own thread (komira_http_tls_e2e's
# `serve_while`) with a real `KernelTcpConnector`, in order:
#   1. a client whose token source is Application Default Credentials over a
#      scripted metadata server that answers 403: `send_one` raises
#      `no access token (HTTP 403); nothing was sent`, and the fake records
#      no request for it (the request count below is the proof; the sends of
#      step 2 are its positive control);
#   2. a client with the right bearer sends one wake to each token above;
#   3. a client with another bearer sends to tok-ok;
#   4. a client pointed at a port nothing listens on sends to tok-ok;
#   5. a client whose token source is `fcm_application_default_token_source_from`
#      (the function `fcm_application_default_token_source` calls), with
#      GCE_METADATA_HOST naming the fake, sends to tok-ok: one metadata
#      token request, then one send with the token it answered.
#
# What each assertion proves, and the defect it catches:
#   * the six recorded requests: POST to /v1/projects/<p>/messages:send,
#     Host 127.0.0.1:<port>, `Bearer <token>` from the token source, JSON
#     content type, and the first body byte for byte (a client that sent
#     elsewhere, dropped a header, or changed the body on the way);
#   * each outcome's kind, status, FcmError and delay, read off the socket
#     (404 read as TRANSIENT, a lost Retry-After header, 401 read as
#     anything but REFUSED);
#   * the mint-failure message, exactly, with none of the token endpoint's
#     description in it (a client that passed the source's text on, or
#     dialled FCM without a token);
#   * the closed port: TRANSIENT with status 0, not a raise (one dead
#     endpoint would otherwise abort a caller's loop over many tokens).
#   * step 5: the metadata request target, whole, carries exactly the
#     firebase.messaging scope, with `Metadata-Flavor: Google`, and the
#     seventh send carries the token it answered and is ACCEPTED. Catches
#     the production ADC entry asking for another scope, or none (a mutant
#     passing `AdcOptions()` there sends no `?scopes=`).
#   * test_endpoint_refusals: an https endpoint over a plaintext connector
#     raises with its exact message instead of returning a TRANSIENT outcome
#     a caller would retry for every token.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_gcp_core import (
    AdcFetcher,
    CachingTokenSource,
    FixedWallClock,
    GcpConnectorTransport,
    GcpHttpTransport,
    MapEnv,
    MapFiles,
    StaticTokenSource,
    TokenHttpRequest,
    TokenHttpResponse,
    application_default_token_source_with,
)
from komira_http_client.client import HttpClient, HttpClientConfig
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_json import parse_json_bytes
from komira_retry import ManualClock

from komira_http_tls_e2e import ClientLeg, DispatchServeLoop, serve_while

from komira_gcp_fcm import (
    FCM_ACCEPTED,
    FCM_DEAD,
    FCM_REFUSED,
    FCM_TRANSIENT,
    FcmClient,
    FcmEndpoint,
    FcmOutcome,
    FcmWake,
    fcm_adc_options,
    fcm_application_default_token_source_from,
    fcm_message_json,
    fcm_outcome_name,
    token_mint_error,
)


comptime _PROJECT = "example-project-123"
comptime _PATH = "/v1/projects/example-project-123/messages:send"
comptime _BEARER = "ya29.LOOPBACK-7f3a"
comptime _NAME = "projects/example-project-123/messages/0:1790000000000000%31bd1c96"
comptime _REQUEST_TIMEOUT_US = 10_000_000

comptime _Adc = CachingTokenSource[
    AdcFetcher[_RefusingMetadata, _RefusingMetadata, FixedWallClock], ManualClock
]
comptime _MintingClient = FcmClient[KernelTcpConnector, _Adc]
comptime _StaticClient = FcmClient[KernelTcpConnector, StaticTokenSource]
comptime _FcmAdcClient = FcmClient[
    KernelTcpConnector,
    CachingTokenSource[
        AdcFetcher[
            GcpConnectorTransport[KernelTcpConnector],
            GcpConnectorTransport[KernelTcpConnector],
            FixedWallClock,
        ],
        ManualClock,
    ],
]


def _tokens() -> List[String]:
    return [
        String("tok-ok"),
        String("tok-gone"),
        String("tok-throttled"),
        String("tok-unavailable"),
        String("tok-bad"),
    ]


def _wake() -> FcmWake:
    return FcmWake(String("evt-0001"), String("job.failed"), String("jobs.example.com"))


# -----------------------------------------------------------------------------
# The fake FCM, stepped on the server's thread.
# -----------------------------------------------------------------------------


def _envelope(code: Int, status: String, error_code: String) -> String:
    var out = (
        String('{"error":{"code":') + String(code)
        + ',"message":"SECRET-BODY-TEXT","status":"' + status + '"'
    )
    if error_code.byte_length() > 0:
        out += (
            String(',"details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError",')
            + '"errorCode":"' + error_code + '"}]'
        )
    return out + "}}"


def _json_response(status: Int, body: String) -> HttpResponse:
    var resp = HttpResponse(Int32(status))
    resp.headers[String("content-type")] = String("application/json; charset=UTF-8")
    resp.headers[String("content-length")] = String(body.byte_length())
    var bytes = List[UInt8]()
    bytes.extend(Span(body.as_bytes()))
    resp.body = bytes^
    return resp^


def _token_of(body: List[UInt8]) -> String:
    try:
        return parse_json_bytes(body, 16).get(String("message")).get(
            String("token")
        ).as_string()
    except:
        return String("<unreadable>")


struct _FakeFcm(RequestDispatcher):
    var methods: List[String]
    var paths: List[String]
    var hosts: List[String]
    var auths: List[String]
    var types: List[String]
    var bodies: List[String]
    var metadata_targets: List[String]
    var metadata_flavors: List[String]

    def __init__(out self):
        self.methods = List[String]()
        self.paths = List[String]()
        self.hosts = List[String]()
        self.auths = List[String]()
        self.types = List[String]()
        self.bodies = List[String]()
        self.metadata_targets = List[String]()
        self.metadata_flavors = List[String]()

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        if req.method.code == HttpMethod.get().code:
            var target = String(req.path)
            if req.query_string.byte_length() > 0:
                target += "?" + req.query_string
            self.metadata_targets.append(target^)
            self.metadata_flavors.append(
                req.headers.get(String("metadata-flavor")).or_else(
                    String("<absent>")
                )
            )
            return _json_response(
                200,
                String('{"access_token":"') + _BEARER + '","expires_in":3599}',
            )
        var auth = req.headers.get(String("authorization")).or_else(
            String("<absent>")
        )
        self.methods.append(String("POST") if req.method.code == HttpMethod.post().code else String("other"))
        self.paths.append(String(req.path))
        self.hosts.append(req.headers.get(String("host")).or_else(String("<absent>")))
        self.auths.append(auth.copy())
        self.types.append(
            req.headers.get(String("content-type")).or_else(String("<absent>"))
        )
        self.bodies.append(String(unsafe_from_utf8=Span(req.body)))
        if auth != String("Bearer ") + _BEARER:
            return _json_response(401, _envelope(401, String("UNAUTHENTICATED"), String()))
        var token = _token_of(req.body)
        if token == "tok-ok":
            return _json_response(200, String('{"name":"') + _NAME + '"}')
        if token == "tok-gone":
            return _json_response(404, _envelope(404, String("NOT_FOUND"), String("UNREGISTERED")))
        if token == "tok-throttled":
            var r = _json_response(
                429, _envelope(429, String("RESOURCE_EXHAUSTED"), String("QUOTA_EXCEEDED"))
            )
            r.headers[String("retry-after")] = String("7")
            return r^
        if token == "tok-unavailable":
            return _json_response(503, _envelope(503, String("UNAVAILABLE"), String("UNAVAILABLE")))
        return _json_response(400, _envelope(400, String("INVALID_ARGUMENT"), String("INVALID_ARGUMENT")))


# -----------------------------------------------------------------------------
# A scripted metadata server that refuses every token request with 403 and
# a description that must not reach the client's error.
# -----------------------------------------------------------------------------


struct _RefusingMetadata(GcpHttpTransport, Movable, Deinitable):
    def __init__(out self):
        pass

    def send(mut self, req: TokenHttpRequest) raises -> TokenHttpResponse:
        var body = List[UInt8]()
        body.extend(
            Span(
                String(
                    '{"error":"access_denied","error_description":"SECRET-TOKEN-TEXT"}'
                ).as_bytes()
            )
        )
        return TokenHttpResponse(403, body^)


# -----------------------------------------------------------------------------
# The client leg.
# -----------------------------------------------------------------------------


def _mk_tcp() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def _http() raises -> HttpClient[KernelTcpConnector]:
    return HttpClient[KernelTcpConnector].with_request_timeout_us(
        KernelTcpConnector.new(), _REQUEST_TIMEOUT_US
    )


struct _FcmLeg(ClientLeg):
    var port: UInt16
    var closed_port: UInt16
    var mint_error: String
    var outcomes: List[FcmOutcome]
    var wrong_bearer: List[FcmOutcome]
    var closed: List[FcmOutcome]
    var adc_sent: List[FcmOutcome]

    def __init__(out self, port: UInt16, closed_port: UInt16):
        self.port = port
        self.closed_port = closed_port
        self.mint_error = String("<not run>")
        self.outcomes = List[FcmOutcome]()
        self.wrong_bearer = List[FcmOutcome]()
        self.closed = List[FcmOutcome]()
        self.adc_sent = List[FcmOutcome]()

    def run(mut self) raises:
        var env = MapEnv()
        env.set(String("GCE_METADATA_HOST"), String("127.0.0.1:8080"))
        var files = MapFiles()
        var adc = application_default_token_source_with(
            env,
            files,
            _RefusingMetadata(),
            _RefusingMetadata(),
            _RefusingMetadata(),
            FixedWallClock(1_790_000_000),
            ManualClock(0),
            fcm_adc_options(),
        )
        var minting = _MintingClient(
            _http(), adc^, String(_PROJECT), FcmEndpoint.loopback_plaintext(self.port)
        )
        try:
            _ = minting.send_one(String("tok-ok"), _wake())
            self.mint_error = String("<no error>")
        except e:
            self.mint_error = String(e)

        var client = _StaticClient(
            _http(),
            StaticTokenSource(String(_BEARER)),
            String(_PROJECT),
            FcmEndpoint.loopback_plaintext(self.port),
        )
        for t in _tokens():
            self.outcomes.append(client.send_one(t, _wake()))

        var wrong = _StaticClient(
            _http(),
            StaticTokenSource(String("ya29.SOMEONE-ELSE")),
            String(_PROJECT),
            FcmEndpoint.loopback_plaintext(self.port),
        )
        self.wrong_bearer.append(wrong.send_one(String("tok-ok"), _wake()))

        var nowhere = _StaticClient(
            _http(),
            StaticTokenSource(String(_BEARER)),
            String(_PROJECT),
            FcmEndpoint.loopback_plaintext(self.closed_port),
        )
        self.closed.append(nowhere.send_one(String("tok-ok"), _wake()))

        var fenv = MapEnv()
        fenv.set(
            String("GCE_METADATA_HOST"),
            String("127.0.0.1:") + String(Int(self.port)),
        )
        var ffiles = MapFiles()
        var fcm_adc = fcm_application_default_token_source_from(
            fenv,
            ffiles,
            HttpClientConfig.defaults(),
            _mk_tcp,
            _mk_tcp,
            FixedWallClock(1_790_000_000),
            ManualClock(0),
        )
        var adc_client = _FcmAdcClient(
            _http(), fcm_adc^, String(_PROJECT), FcmEndpoint.loopback_plaintext(self.port)
        )
        self.adc_sent.append(adc_client.send_one(String("tok-ok"), _wake()))


def _kind(o: FcmOutcome) -> String:
    return fcm_outcome_name(o.kind)


def _closed_port() raises -> UInt16:
    """A loopback port that was just bound and released."""
    var router = Router()
    router.add(HttpMethod.post(), "/", 0)
    var s = HttpServer(config=HttpServerConfig.default_ephemeral(), router=router^)
    var port = s.local_port()
    _ = s^
    return port


def test_send_over_loopback() raises:
    var closed_port = _closed_port()
    var router = Router()
    router.add(HttpMethod.post(), "/", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=router^
    )
    var port = server.local_port()
    var loop = DispatchServeLoop(server^, _FakeFcm())
    var leg = _FcmLeg(port, closed_port)
    serve_while(loop, leg)

    assert_equal(
        leg.mint_error,
        "komira_gcp_fcm: no access token (HTTP 403); nothing was sent",
        "the mint failure",
    )

    ref fake = loop.dispatcher
    # 5 sends with the right bearer, 1 with another and 1 with the token the
    # fake's metadata answer gave; none from the client whose token could
    # not be minted.
    assert_equal(len(fake.paths), 7, "requests the fake received")
    var host = String("127.0.0.1:") + String(Int(port))
    for i in range(7):
        assert_equal(fake.methods[i], "POST", "method #" + String(i))
        assert_equal(fake.paths[i], _PATH, "path #" + String(i))
        assert_equal(fake.hosts[i], host, "Host #" + String(i))
        assert_equal(
            fake.types[i], "application/json; charset=utf-8", "Content-Type #" + String(i)
        )
        var want = String("Bearer ") + _BEARER
        if i == 5:
            want = String("Bearer ya29.SOMEONE-ELSE")
        assert_equal(fake.auths[i], want, "Authorization #" + String(i))
    assert_equal(fake.bodies[0], fcm_message_json(String("tok-ok"), _wake()))
    assert_equal(fake.bodies[1], fcm_message_json(String("tok-gone"), _wake()))

    assert_equal(len(leg.outcomes), 5)
    ref ok = leg.outcomes[0]
    assert_equal(_kind(ok), fcm_outcome_name(FCM_ACCEPTED), "tok-ok")
    assert_equal(ok.http_status, 200)
    assert_equal(ok.message_name, _NAME)

    ref gone = leg.outcomes[1]
    assert_equal(_kind(gone), fcm_outcome_name(FCM_DEAD), "tok-gone")
    assert_equal(gone.http_status, 404)
    assert_equal(gone.fcm_error, "UNREGISTERED")

    ref throttled = leg.outcomes[2]
    assert_equal(_kind(throttled), fcm_outcome_name(FCM_TRANSIENT), "tok-throttled")
    assert_equal(throttled.http_status, 429)
    assert_equal(throttled.fcm_error, "QUOTA_EXCEEDED")
    assert_equal(throttled.retry_after_ms, 7000, "Retry-After read off the socket")

    ref unavailable = leg.outcomes[3]
    assert_equal(_kind(unavailable), fcm_outcome_name(FCM_TRANSIENT), "tok-unavailable")
    assert_equal(unavailable.http_status, 503)
    assert_equal(unavailable.retry_after_ms, -1)

    ref bad = leg.outcomes[4]
    assert_equal(_kind(bad), fcm_outcome_name(FCM_REFUSED), "tok-bad")
    assert_equal(bad.http_status, 400)
    assert_equal(bad.fcm_error, "INVALID_ARGUMENT")

    ref wrong = leg.wrong_bearer[0]
    assert_equal(_kind(wrong), fcm_outcome_name(FCM_REFUSED), "another bearer")
    assert_equal(wrong.http_status, 401)

    for o in leg.outcomes:
        assert_true(o.detail.find("SECRET") < 0, "a detail quoted the body")

    ref closed = leg.closed[0]
    assert_equal(_kind(closed), fcm_outcome_name(FCM_TRANSIENT), "closed port")
    assert_equal(closed.http_status, 0)
    # The connect failure's own text (errno, address) is not kept.
    assert_equal(
        closed.detail,
        "POST FirebaseMessaging.SendMessage: no answer, transport error",
    )

    # Step 5: the production ADC entry's one metadata request, whole.
    assert_equal(len(fake.metadata_targets), 1, "metadata token requests")
    assert_equal(
        fake.metadata_targets[0],
        "/computeMetadata/v1/instance/service-accounts/default/token"
        "?scopes=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Ffirebase.messaging",
    )
    assert_equal(fake.metadata_flavors[0], "Google")
    assert_equal(len(leg.adc_sent), 1)
    assert_equal(_kind(leg.adc_sent[0]), fcm_outcome_name(FCM_ACCEPTED), "ADC send")
    assert_equal(fake.bodies[6], fcm_message_json(String("tok-ok"), _wake()))
    print("  test_send_over_loopback PASS")


def test_token_mint_error_text() raises:
    assert_equal(
        String(token_mint_error(String(
            "the metadata server answered HTTP 401 (invalid_grant)"
        ))),
        "komira_gcp_fcm: no access token (HTTP 401); nothing was sent",
    )
    assert_equal(
        String(token_mint_error(String(
            "the metadata server could not be reached: HttpError[CONNECT_FAILED]"
        ))),
        "komira_gcp_fcm: no access token (no HTTP status); nothing was sent",
    )
    assert_equal(
        String(token_mint_error(String("answered HTTP 40"))),
        "komira_gcp_fcm: no access token (no HTTP status); nothing was sent",
    )
    print("  test_token_mint_error_text PASS")


def test_endpoint_refusals() raises:
    var msg = String()
    try:
        _ = FcmEndpoint.https(String("fcm.example.com@evil"), 443)
    except e:
        msg = String(e)
    assert_equal(msg, "komira_gcp_fcm: the FCM host holds a byte outside [a-z0-9.-]")
    msg = String()
    try:
        _ = FcmEndpoint.loopback_plaintext(0)
    except e:
        msg = String(e)
    assert_equal(msg, "komira_gcp_fcm: the FCM port is 0")
    # A plaintext endpoint built by hand for a host other than 127.0.0.1
    # (`localhost`, so a client without the check dials loopback, finds
    # nothing listening and returns an outcome instead of raising).
    var cleartext = _StaticClient(
        _http(),
        StaticTokenSource(String(_BEARER)),
        String(_PROJECT),
        FcmEndpoint(String("localhost"), _closed_port(), False),
    )
    msg = String()
    try:
        _ = cleartext.send_one(String("tok-ok"), _wake())
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_gcp_fcm: plain http is only for 127.0.0.1; the bearer token"
        " would cross the network in clear",
    )
    # An https endpoint over a plaintext connector: komira_http_client's
    # scheme check refuses it before dialling, and that raises rather than
    # coming back TRANSIENT. The host is 127.0.0.1 and the port closed, so
    # a client that dialled anyway finds nothing and returns an outcome.
    var mismatched = _StaticClient(
        _http(),
        StaticTokenSource(String(_BEARER)),
        String(_PROJECT),
        FcmEndpoint.https(String("127.0.0.1"), _closed_port()),
    )
    msg = String("<not refused>")
    try:
        var o = mismatched.send_one(String("tok-ok"), _wake())
        msg = String("<an outcome: ") + _kind(o) + " " + o.detail + ">"
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_gcp_fcm: komira_http_client refused the request URL"
        " (HttpError[URL_INVALID]: the endpoint's scheme and the connector"
        " disagree); nothing was sent",
    )
    var p = FcmEndpoint.public()
    assert_equal(p.host, "fcm.googleapis.com")
    assert_equal(Int(p.port), 443)
    assert_true(p.tls)
    print("  test_endpoint_refusals PASS")


def main() raises:
    test_token_mint_error_text()
    test_endpoint_refusals()
    test_send_over_loopback()
    print("PASS komira_gcp_fcm loopback")
