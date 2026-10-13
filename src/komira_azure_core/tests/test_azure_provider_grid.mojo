# Grids over both token providers and the token-response reader they share,
# through a capturing HttpService: no socket, no metadata service, no tenant.
#
# Rows:
#   * every token-response fixture goes through all three readers
#     (parse_oauth_token_response, AzureImdsProvider, ServicePrincipalProvider)
#     with its exact expected result: an accepted body compares as a whole
#     record (access_token, expires_in, token_type) and lands in each
#     provider's cache at clock + expires_in * 1000; a refused body raises
#     its named refusal (prefixed with the provider's name), quotes no body
#     byte and caches nothing. The fixtures walk token_type one mismatched
#     byte at each position and every length 0 to 7, the digit boundaries of
#     a string expires_in (`/` `0` `9` `:`), its bounds, twelve digits
#     with leading zeros, nesting at the 8-deep limit and one past it, and a
#     repeated member in first and last place;
#   * the IMDS endpoint: `http://` and `https://` with and without a port,
#     one wrong byte at each position of either scheme prefix, a prefix cut
#     short, and a port that is not a number are refused before the
#     service is called;
#   * percent-encoding, one byte per row, of the IMDS query (`resource`,
#     `client_id`) and the service principal's form (`client_id`): the
#     unreserved set's edges pass through, their neighbours and a UTF-8
#     byte pair are escaped in upper-case hex;
#   * the status line: 200, 201, 204 and 299 are read; 100, 199, 300, 301,
#     400, 404, 500 and 503 are named errors that cache nothing, whatever
#     the body says;
#   * the login host and tenant refuse a byte outside `[A-Za-z0-9.-]` as
#     the first or the last byte, and a one-byte name is read whole;
#   * each factory's settings, and `with_clock` keeping every setting and
#     the cached token (its own expiry and the provider's, set apart), as
#     whole-object comparisons; a token expiring at clock 0 is held, one at
#     -1 is not, and with no margin it is not due at clock -1 and due at 0.
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_core import (
    AzureBearerToken,
    AzureImdsProvider,
    OAuthTokenResponse,
    ServicePrincipalProvider,
    parse_oauth_token_response,
)
from komira_azure_core.creds_managed_identity import AZURE_IMDS_API_VERSION
from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock, MonotonicClock


comptime _RT = PerCoreAsyncRuntime[NoopSink]


struct CapturingService(HttpService, Movable, Deinitable):
    """Answers every call with one scripted status and body, and keeps the
    last request's URL and serialized bytes."""

    var status: Int
    var body: String
    var calls: Int
    var url: String
    var wire: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^
        self.calls = 0
        self.url = String("")
        self.wire = String("")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self.calls += 1
        var url = String(req.url.scheme) + "://" + String(req.url.host)
        if req.url.port != UInt16(0):
            url += ":" + String(Int(req.url.port))
        url += String(req.url.path)
        if req.url.query.byte_length() > 0:
            url += "?" + String(req.url.query)
        self.url = url^
        self.wire = String(unsafe_from_utf8=Span(req.request_bytes))
        _ = req^
        var bytes = List[UInt8]()
        bytes.extend(Span(self.body.as_bytes()))
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(bytes^)
        )
        resp.status = Int32(self.status)
        resp.reason = String("Scripted")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _refresh_imds[K: MonotonicClock](
    mut p: AzureImdsProvider[K], mut svc: CapturingService
) raises:
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    p.refresh_with_service[CapturingService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


def _refresh_sp[K: MonotonicClock](
    mut p: ServicePrincipalProvider[K], mut svc: CapturingService
) raises:
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    p.refresh_with_service[CapturingService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


def _imds_local() -> AzureImdsProvider[ManualClock]:
    return AzureImdsProvider.with_endpoint(
        String("http://127.0.0.1:18080")
    ).with_clock(ManualClock(_CLOCK_MS))


def _sp_local() raises -> ServicePrincipalProvider[ManualClock]:
    return ServicePrincipalProvider.with_login_endpoint(
        String("t"),
        String("c"),
        String("s"),
        String("http"),
        String("127.0.0.1"),
        UInt16(18081),
    ).with_clock(ManualClock(_CLOCK_MS))


comptime _CLOCK_MS: Int64 = 5_000
comptime _OK = '{"access_token":"tok","expires_in":3599}'


# -----------------------------------------------------------------------------
# Every token-response fixture through every reader
# -----------------------------------------------------------------------------


@fieldwise_init
struct Fixture(Copyable, Movable):
    """A token endpoint's 2xx body and what reading it must give: the whole
    record when `refusal` is empty, else that refusal."""

    var body: String
    var token: String
    var expires_in: Int64
    var token_type: String
    var refusal: String


def _ok(body: String, token: String, exp: Int64, tt: String) -> Fixture:
    return Fixture(body, token, exp, tt, String(""))


def _no(body: String, refusal: String) -> Fixture:
    return Fixture(body, String(""), Int64(0), String(""), refusal)


comptime _NOT_BEARER = "the token response's token_type is not Bearer"
comptime _BAD_EXP = (
    "the token response's expires_in is not a positive whole number of"
    " seconds"
)


def _tt(tt: String) -> String:
    return (
        String('{"access_token":"SECRET","expires_in":1,"token_type":"')
        + tt
        + '"}'
    )


def _exp(exp: String) -> String:
    return String('{"access_token":"SECRET","expires_in":') + exp + "}"


def _fixtures() -> List[Fixture]:
    var f = List[Fixture]()
    # Accepted: expires_in at its bounds in both forms, the digit edges of
    # the string form, token_type absent or in any case, members in any
    # order.
    f.append(_ok('{"access_token":"t","expires_in":1}', "t", 1, "Bearer"))
    f.append(_ok('{"access_token":"t","expires_in":"1"}', "t", 1, "Bearer"))
    f.append(_ok('{"access_token":"t","expires_in":"19"}', "t", 19, "Bearer"))
    f.append(_ok('{"access_token":"t","expires_in":"90"}', "t", 90, "Bearer"))
    f.append(
        _ok(
            '{"access_token":"t","expires_in":999999999999}',
            "t",
            999_999_999_999,
            "Bearer",
        )
    )
    f.append(
        _ok(
            '{"access_token":"t","expires_in":"999999999999"}',
            "t",
            999_999_999_999,
            "Bearer",
        )
    )
    # Leading zeros in the string form: twelve digits, the most it takes.
    f.append(
        _ok('{"access_token":"t","expires_in":"000000000060"}', "t", 60, "Bearer")
    )
    # Nesting: the body is read at most 8 containers deep, the top object
    # one of them (komira_json counts every array and object).
    f.append(
        _ok(
            '{"x":[[[[[[[1]]]]]]],"access_token":"t","expires_in":2}',
            "t",
            2,
            "Bearer",
        )
    )
    for tt in ["Bearer", "bearer", "BEARER", "bEaReR"]:
        f.append(
            _ok(
                String('{"access_token":"t","expires_in":7,"token_type":"')
                + tt
                + '"}',
                "t",
                7,
                tt,
            )
        )
    f.append(
        _ok(
            '{"token_type":"Bearer","expires_in":3599,"x":[1],'
            '"access_token":"a.b"}',
            "a.b",
            3599,
            "Bearer",
        )
    )
    # token_type: one wrong byte at each position, every other length.
    for tt in [
        "xearer", "Bxarer", "Bexrer", "Beaxer", "Bearxr", "Bearex",
        "", "B", "Be", "Bea", "Bear", "Beare", "Bearer ", "BearerX",
    ]:
        f.append(_no(_tt(tt), _NOT_BEARER))
    for tt in ["null", "1", "true", "{}", '["Bearer"]']:
        f.append(
            _no(
                String('{"access_token":"SECRET","expires_in":1,"token_type":')
                + tt
                + "}",
                _NOT_BEARER,
            )
        )
    # expires_in: the bytes either side of the digits, zero, signs, past
    # the bound in both forms, not a number.
    for e in [
        '"1/"', '"1:"', '"/"', '":"', '"0"', '"-1"', "0", "-1", "null",
        "1000000000000", '"1000000000000"', '"1.5"', "1.5", "[1]",
    ]:
        f.append(_no(_exp(e), _BAD_EXP))
    # A repeated member, its second copy first and last; equal copies too.
    f.append(
        _no(
            '{"access_token":"SECRET","access_token":"SECRET","expires_in":1}',
            "the token response repeats access_token",
        )
    )
    f.append(
        _no(
            '{"expires_in":1,"access_token":"SECRET","access_token":"SECRET2"}',
            "the token response repeats access_token",
        )
    )
    f.append(
        _no(
            '{"access_token":"SECRET","expires_in":1,"expires_in":1}',
            "the token response repeats expires_in",
        )
    )
    f.append(
        _no(
            '{"access_token":"SECRET","token_type":"Bearer","expires_in":1,'
            '"token_type":"Bearer"}',
            "the token response repeats token_type",
        )
    )
    # The shape: not JSON, not an object, no access_token, no expires_in.
    f.append(
        _no(
            '{"x":[[[[[[[[1]]]]]]]],"access_token":"SECRET","expires_in":2}',
            "the token response is not JSON",
        )
    )
    f.append(_no('{"access_token":"SECRET"', "the token response is not JSON"))
    f.append(_no("[]", "the token response is not a JSON object"))
    f.append(_no("{}", "the token response has no access_token string"))
    f.append(
        _no(
            '{"access_token":["SECRET"],"expires_in":1}',
            "the token response has no access_token string",
        )
    )
    f.append(
        _no(
            '{"access_token":"","expires_in":1}',
            "the token response's access_token is empty",
        )
    )
    f.append(
        _no('{"access_token":"SECRET"}', "the token response has no expires_in")
    )
    return f^


def _assert_response(
    r: OAuthTokenResponse, f: Fixture, ctx: String
) raises:
    """The whole record, every field."""
    assert_equal(r.access_token, f.token, ctx)
    assert_equal(r.expires_in, f.expires_in, ctx)
    assert_equal(r.token_type, f.token_type, ctx)


def _assert_refusal(msg: String, prefix: String, f: Fixture) raises:
    assert_true(msg.startswith(prefix + f.refusal), msg + " | " + f.body)
    assert_equal(msg.find("SECRET"), -1, msg)


def _check_parse(f: Fixture) raises:
    var b = List[UInt8]()
    b.extend(Span(f.body.as_bytes()))
    if f.refusal.byte_length() == 0:
        _assert_response(parse_oauth_token_response(b^), f, f.body)
        return
    var raised = False
    try:
        _ = parse_oauth_token_response(b^)
    except e:
        raised = True
        _assert_refusal(String(e), String(""), f)
    assert_true(raised, f.body)


def _check_imds(f: Fixture) raises:
    var p = _imds_local()
    var svc = CapturingService(200, f.body)
    if f.refusal.byte_length() == 0:
        _refresh_imds(p, svc)
        var t = p.credential()
        assert_equal(t.token, f.token, f.body)
        assert_equal(t.expiry_ms, _CLOCK_MS + f.expires_in * 1000, f.body)
        assert_equal(p.cached_expiry_ms(), t.expiry_ms, f.body)
        return
    var raised = False
    try:
        _refresh_imds(p, svc)
    except e:
        raised = True
        _assert_refusal(String(e), String("AzureImdsProvider: "), f)
    assert_true(raised, f.body)
    assert_equal(svc.calls, 1, f.body)
    assert_false(p.has_credential(), f.body)
    assert_equal(p.cached_expiry_ms(), -1, f.body)


def _check_sp(f: Fixture) raises:
    var p = _sp_local()
    var svc = CapturingService(200, f.body)
    if f.refusal.byte_length() == 0:
        _refresh_sp(p, svc)
        var t = p.credential()
        assert_equal(t.token, f.token, f.body)
        assert_equal(t.expiry_ms, _CLOCK_MS + f.expires_in * 1000, f.body)
        assert_equal(p.cached_expiry_ms(), t.expiry_ms, f.body)
        return
    var raised = False
    try:
        _refresh_sp(p, svc)
    except e:
        raised = True
        _assert_refusal(String(e), String("ServicePrincipalProvider: "), f)
    assert_true(raised, f.body)
    assert_equal(svc.calls, 1, f.body)
    assert_false(p.has_credential(), f.body)
    assert_equal(p.cached_expiry_ms(), -1, f.body)


def test_every_fixture_through_every_reader() raises:
    var fixtures = _fixtures()
    for f in fixtures:
        _check_parse(f)
        _check_imds(f)
        _check_sp(f)


# -----------------------------------------------------------------------------
# The IMDS endpoint
# -----------------------------------------------------------------------------


def _imds_q(resource: String) -> String:
    """The path and query IMDS is asked on. The api-version is the
    package's own constant: test_azure_token_providers pins its value."""
    return (
        String("/metadata/identity/oauth2/token?api-version=")
        + String(AZURE_IMDS_API_VERSION)
        + "&resource="
        + resource
    )


comptime _STORAGE_Q = "https%3A%2F%2Fstorage.azure.com%2F"


def _imds_url(endpoint: String) raises -> String:
    var p = AzureImdsProvider.with_endpoint(endpoint)
    var svc = CapturingService(200, String(_OK))
    _refresh_imds(p, svc)
    assert_equal(p.credential().token, "tok", endpoint)
    return svc.url


def _imds_endpoint_refused(endpoint: String, contains: String) raises:
    var p = AzureImdsProvider.with_endpoint(endpoint)
    var svc = CapturingService(200, String(_OK))
    with assert_raises(contains=contains):
        _refresh_imds(p, svc)
    assert_equal(svc.calls, 0, endpoint)
    assert_false(p.has_credential(), endpoint)


def _with_byte(s: String, k: Int, c: String) -> String:
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        if i == k:
            out += c
        else:
            out += chr(Int(b[i]))
    return out^


def test_imds_endpoint_schemes_and_ports() raises:
    assert_equal(
        _imds_url("http://169.254.169.254"), "http://169.254.169.254" + _imds_q(_STORAGE_Q)
    )
    assert_equal(
        _imds_url("https://imds.example.com"),
        "https://imds.example.com" + _imds_q(_STORAGE_Q),
    )
    assert_equal(
        _imds_url("https://imds.example.com:8443"),
        "https://imds.example.com:8443" + _imds_q(_STORAGE_Q),
    )
    assert_equal(
        _imds_url("http://imds.example.com:1"),
        "http://imds.example.com:1" + _imds_q(_STORAGE_Q),
    )
    assert_equal(
        _imds_url("http://imds.example.com:65535"),
        "http://imds.example.com:65535" + _imds_q(_STORAGE_Q),
    )
    comptime scheme = "endpoint must start with http:// or https://"
    for k in range(7):
        _imds_endpoint_refused(_with_byte("http://imds.example.com", k, "x"), scheme)
    for k in range(8):
        _imds_endpoint_refused(
            _with_byte("https://imds.example.com", k, "x"), scheme
        )
    for e in ["", "h", "http:/", "https:/", "imds.example.com:80"]:
        _imds_endpoint_refused(e, scheme)
    comptime port = "AzureImdsProvider: malformed port in endpoint: "
    _imds_endpoint_refused(
        "http://127.0.0.1:abc", port + "http://127.0.0.1:abc"
    )
    _imds_endpoint_refused(
        "https://imds.example.com:8x", port + "https://imds.example.com:8x"
    )


# -----------------------------------------------------------------------------
# Percent-encoding, one byte per row
# -----------------------------------------------------------------------------


def _encoding_rows() -> List[Tuple[String, String]]:
    var rows = List[Tuple[String, String]]()
    # The unreserved set (RFC 3986 section 2.3), each range's ends.
    for c in ["A", "Z", "a", "z", "0", "9", "-", ".", "_", "~"]:
        rows.append((String(c), String(c)))
    # The bytes either side of each range and of each single unreserved
    # byte, and bytes a query or form gives meaning to.
    rows.append((String("@"), String("%40")))
    rows.append((String("["), String("%5B")))
    rows.append((String("`"), String("%60")))
    rows.append((String("{"), String("%7B")))
    rows.append((String("/"), String("%2F")))
    rows.append((String(":"), String("%3A")))
    rows.append((String(","), String("%2C")))
    rows.append((String("^"), String("%5E")))
    rows.append((String("}"), String("%7D")))
    rows.append((String(" "), String("%20")))
    rows.append((String("%"), String("%25")))
    rows.append((String("+"), String("%2B")))
    rows.append((String("&"), String("%26")))
    rows.append((String("="), String("%3D")))
    # A UTF-8 pair: both nibble ranges, hex digits 9 and A side by side.
    rows.append((String("é"), String("%C3%A9")))
    rows.append((String("a b"), String("a%20b")))
    return rows^


comptime _FORM_TAIL = (
    "&client_secret=s&scope=https%3A%2F%2Fstorage.azure.com%2F.default"
)


def test_percent_encoding_rows() raises:
    var rows = _encoding_rows()
    for row in rows:
        var raw = row[0]
        var want = row[1]
        # IMDS: the client_id query value.
        var p = AzureImdsProvider.with_endpoint(String("http://127.0.0.1:18080"))
        p.client_id = raw
        var svc = CapturingService(200, String(_OK))
        _refresh_imds(p, svc)
        assert_equal(
            svc.url,
            String("http://127.0.0.1:18080") + _imds_q(_STORAGE_Q) + "&client_id=" + want,
            raw,
        )
        # IMDS: the resource query value, no client_id.
        var r = AzureImdsProvider.with_endpoint(String("http://127.0.0.1:18080"))
        r.resource = raw
        var svc2 = CapturingService(200, String(_OK))
        _refresh_imds(r, svc2)
        assert_equal(
            svc2.url,
            String("http://127.0.0.1:18080") + _imds_q(want),
            raw,
        )
        # The service principal: the client_id form value.
        var s = _sp_local()
        s.client_id = raw
        var svc3 = CapturingService(200, String(_OK))
        _refresh_sp(s, svc3)
        assert_true(
            svc3.wire.endswith(
                String("\r\n\r\ngrant_type=client_credentials&client_id=")
                + want
                + _FORM_TAIL
            ),
            svc3.wire,
        )


# -----------------------------------------------------------------------------
# The status line
# -----------------------------------------------------------------------------


def test_status_boundaries() raises:
    for status in [200, 201, 204, 299]:
        var p = _imds_local()
        var svc = CapturingService(status, String(_OK))
        _refresh_imds(p, svc)
        assert_equal(p.credential().token, "tok", String(status))
        var s = _sp_local()
        var svc2 = CapturingService(status, String(_OK))
        _refresh_sp(s, svc2)
        assert_equal(s.credential().token, "tok", String(status))
    for status in [100, 199, 300, 301, 400, 404, 500, 503]:
        var p = _imds_local()
        var svc = CapturingService(status, String(_OK))
        with assert_raises(
            contains=String("AzureImdsProvider: token GET returned status ")
            + String(status)
        ):
            _refresh_imds(p, svc)
        assert_false(p.has_credential(), String(status))
        var s = _sp_local()
        var svc2 = CapturingService(status, String(_OK))
        with assert_raises(
            contains=String(
                "ServicePrincipalProvider: token POST returned status "
            )
            + String(status)
        ):
            _refresh_sp(s, svc2)
        assert_false(s.has_credential(), String(status))


# -----------------------------------------------------------------------------
# Factories and with_clock, as whole objects
# -----------------------------------------------------------------------------


def _assert_cached[K: MonotonicClock](
    p: AzureImdsProvider[K], token: String, token_expiry: Int64, expiry: Int64
) raises:
    assert_equal(p.cached_expiry_ms(), expiry)
    if expiry < 0:
        assert_false(p.has_credential())
        with assert_raises(contains="no cached token"):
            _ = p.credential()
        return
    assert_true(p.has_credential())
    var t = p.credential()
    assert_equal(t.token, token)
    assert_equal(t.expiry_ms, token_expiry)


def _assert_imds[K: MonotonicClock](
    p: AzureImdsProvider[K],
    endpoint: String,
    resource: String,
    client_id: String,
    margin: Int64,
    token: String,
    token_expiry: Int64,
    expiry: Int64,
) raises:
    assert_equal(p.endpoint, endpoint)
    assert_equal(p.resource, resource)
    assert_equal(p.client_id, client_id)
    assert_equal(p.refresh_margin_seconds, margin)
    _assert_cached(p, token, token_expiry, expiry)


def _assert_sp_cached[K: MonotonicClock](
    p: ServicePrincipalProvider[K],
    token: String,
    token_expiry: Int64,
    expiry: Int64,
) raises:
    assert_equal(p.cached_expiry_ms(), expiry)
    if expiry < 0:
        assert_false(p.has_credential())
        with assert_raises(contains="no cached token"):
            _ = p.credential()
        return
    assert_true(p.has_credential())
    var t = p.credential()
    assert_equal(t.token, token)
    assert_equal(t.expiry_ms, token_expiry)


def _assert_sp[K: MonotonicClock](
    p: ServicePrincipalProvider[K],
    tenant: String,
    client_id: String,
    secret: String,
    scope: String,
    host: String,
    scheme: String,
    port: UInt16,
    margin: Int64,
    token: String,
    token_expiry: Int64,
    expiry: Int64,
) raises:
    assert_equal(p.tenant_id, tenant)
    assert_equal(p.client_id, client_id)
    assert_equal(p.client_secret, secret)
    assert_equal(p.scope, scope)
    assert_equal(p.login_host, host)
    assert_equal(p.login_scheme, scheme)
    assert_equal(p.login_port, port)
    assert_equal(p.refresh_margin_seconds, margin)
    _assert_sp_cached(p, token, token_expiry, expiry)


comptime _IMDS = "http://169.254.169.254"
comptime _STORAGE = "https://storage.azure.com/"
comptime _SCOPE = "https://storage.azure.com/.default"


def test_imds_factories_and_with_clock() raises:
    _assert_imds(AzureImdsProvider.make(), _IMDS, _STORAGE, "", 300, "", -1, -1)
    _assert_imds(
        AzureImdsProvider.for_client_id(String("cid")),
        _IMDS, _STORAGE, "cid", 300, "", -1, -1,
    )
    _assert_imds(
        AzureImdsProvider.with_endpoint(String("http://e.example.com")),
        "http://e.example.com", _STORAGE, "", 300, "", -1, -1,
    )
    # with_clock keeps every setting and the cached token; the token's own
    # expiry and the provider's are set apart to show each is carried.
    var p = AzureImdsProvider.for_client_id(String("cid"))
    p.endpoint = String("http://e.example.com")
    p.resource = String("r")
    p.refresh_margin_seconds = 7
    p.set_credential_for_test(AzureBearerToken(String("tk"), 41), 42)
    var q = p^.with_clock(ManualClock(123))
    _assert_imds(q, "http://e.example.com", "r", "cid", 7, "tk", 41, 42)
    assert_equal(q.clock().now_ms(), 123)
    # A token expiring at clock 0 is held; -1 is the "none" sentinel.
    q.set_credential_for_test(AzureBearerToken(String("z"), 0), 0)
    _assert_cached(q, "z", 0, 0)
    q.set_credential_for_test(AzureBearerToken(String("z"), -1), -1)
    _assert_cached(q, "", -1, -1)
    # A token expiring at clock 0 with no margin is not due while the clock
    # reads -1, and due at 0: a held token is judged by the clock, never by
    # the sign of its expiry.
    var n = AzureImdsProvider.make().with_clock(ManualClock(-1))
    n.refresh_margin_seconds = 0
    n.set_credential_for_test(AzureBearerToken(String("z"), 0), 0)
    assert_false(n.is_expired_or_near_expiry())
    n.clock().advance(1)
    assert_true(n.is_expired_or_near_expiry())


def test_sp_factories_and_with_clock() raises:
    _assert_sp(
        ServicePrincipalProvider.make(
            String("tenant"), String("cid"), String("sec")
        ),
        "tenant", "cid", "sec", _SCOPE, "login.microsoftonline.com", "https",
        0, 300, "", -1, -1,
    )
    _assert_sp(
        ServicePrincipalProvider.with_login_endpoint(
            String("tn"),
            String("cid"),
            String("sec"),
            String("https"),
            String("login.example.com"),
            UInt16(8443),
        ),
        "tn", "cid", "sec", _SCOPE, "login.example.com", "https", 8443, 300,
        "", -1, -1,
    )
    var p = ServicePrincipalProvider.with_login_endpoint(
        String("tn"),
        String("cid"),
        String("sec"),
        String("http"),
        String("localhost"),
        UInt16(8080),
    )
    p.scope = String("sc")
    p.refresh_margin_seconds = 9
    p.set_credential_for_test(AzureBearerToken(String("tk"), 41), 42)
    var q = p^.with_clock(ManualClock(456))
    _assert_sp(
        q, "tn", "cid", "sec", "sc", "localhost", "http", 8080, 9, "tk", 41, 42
    )
    assert_equal(q.clock().now_ms(), 456)
    q.set_credential_for_test(AzureBearerToken(String("z"), 0), 0)
    _assert_sp_cached(q, "z", 0, 0)
    q.set_credential_for_test(AzureBearerToken(String("z"), -1), -1)
    _assert_sp_cached(q, "", -1, -1)
    var n = ServicePrincipalProvider.make(
        String("t"), String("c"), String("s")
    ).with_clock(ManualClock(-1))
    n.refresh_margin_seconds = 0
    n.set_credential_for_test(AzureBearerToken(String("z"), 0), 0)
    assert_false(n.is_expired_or_near_expiry())
    n.clock().advance(1)
    assert_true(n.is_expired_or_near_expiry())


# -----------------------------------------------------------------------------
# The login host and tenant: a refused byte first and last, not only inside
# -----------------------------------------------------------------------------


def test_dns_name_bad_byte_at_either_edge() raises:
    for bad in ["@", "/", ":", "_", " "]:
        for host in [
            String(bad) + "login.example.com",
            String("login.example.com") + bad,
        ]:
            with assert_raises(
                contains="ServicePrincipalProvider: login host holds a byte"
                " outside [A-Za-z0-9.-]"
            ):
                _ = ServicePrincipalProvider.with_login_endpoint(
                    String("t"), String("c"), String("s"), String("https"),
                    host, UInt16(0),
                )
        for tenant in [String(bad) + "tenant", String("tenant") + bad]:
            with assert_raises(
                contains="ServicePrincipalProvider: tenant_id holds a byte"
                " outside [A-Za-z0-9.-]"
            ):
                _ = ServicePrincipalProvider.make(
                    tenant, String("c"), String("s")
                )
    # One-byte names: the byte is both edges.
    var one = ServicePrincipalProvider.with_login_endpoint(
        String("t"), String("c"), String("s"), String("https"), String("h"),
        UInt16(0),
    )
    assert_equal(one.login_host, "h")
    assert_equal(one.tenant_id, "t")
    with assert_raises(contains="login host has an empty label"):
        _ = ServicePrincipalProvider.with_login_endpoint(
            String("t"), String("c"), String("s"), String("https"), String("."),
            UInt16(0),
        )


def main() raises:
    test_every_fixture_through_every_reader()
    test_dns_name_bad_byte_at_either_edge()
    test_imds_endpoint_schemes_and_ports()
    test_percent_encoding_rows()
    test_status_boundaries()
    test_imds_factories_and_with_clock()
    test_sp_factories_and_with_clock()
    print("OK")
