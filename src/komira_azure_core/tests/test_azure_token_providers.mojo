# AzureImdsProvider and ServicePrincipalProvider over a capturing HttpService:
# no socket, no metadata service, no tenant. The service records the request
# each provider put on the wire (method, URL, headers, the serialized bytes
# with the body) and answers with a scripted status and body.
#
# Rows: IMDS asks for a storage-scoped token with the mandatory `Metadata:
# true` header (and the user-assigned `client_id` when one is set), reads
# `expires_in` as the JSON string IMDS sends, and caches the token against
# its injected clock (a ManualClock here); the service principal POSTs the form-encoded
# client-credentials grant to `/<tenant>/oauth2/v2.0/token` with its values
# percent-encoded, and reads `expires_in` as the JSON number Entra sends; a
# non-2xx answer and a body that is not a token response are named errors
# that leave no token cached; a login endpoint that is not https (or http on
# loopback), a host or tenant outside `[A-Za-z0-9.-]` or with an empty label
# are refused before the service is called, at construction and at refresh;
# and a token near its expiry is due for a refresh.
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_core import (
    AzureBearerToken,
    AzureImdsProvider,
    ServicePrincipalProvider,
)
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
    """Answers every call with one scripted status and body, and keeps what
    the last request carried."""

    var status: Int
    var body: String
    var calls: Int
    var method: String
    var url: String
    var metadata_header: String
    var content_type: String
    var wire: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^
        self.calls = 0
        self.method = String("")
        self.url = String("")
        self.metadata_header = String("")
        self.content_type = String("")
        self.wire = String("")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self.calls += 1
        self.method = req.method.name()
        var url = String(req.url.scheme) + "://" + String(req.url.host)
        if req.url.port != UInt16(0):
            url += ":" + String(Int(req.url.port))
        url += String(req.url.path)
        if req.url.query.byte_length() > 0:
            url += "?" + String(req.url.query)
        self.url = url^
        var md = req.headers.get(String("Metadata"))
        self.metadata_header = md.value() if md else String("")
        var ct = req.headers.get(String("Content-Type"))
        self.content_type = ct.value() if ct else String("")
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


def _connector() -> ScriptedConnector:
    return ScriptedConnector.with_stream(ScriptedStream.empty())


def _refresh_imds[K: MonotonicClock](
    mut p: AzureImdsProvider[K], mut svc: CapturingService
) raises:
    var conn = _connector()
    var reactor = _reactor()
    p.refresh_with_service[CapturingService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


def _refresh_sp[K: MonotonicClock](
    mut p: ServicePrincipalProvider[K], mut svc: CapturingService
) raises:
    var conn = _connector()
    var reactor = _reactor()
    p.refresh_with_service[CapturingService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


comptime _IMDS_OK = (
    '{"access_token":"imds-token","refresh_token":"","expires_in":"3599",'
    '"expires_on":"0","not_before":"0","resource":"https://storage.azure.com/",'
    '"token_type":"Bearer"}'
)


def test_imds_request_and_cached_token() raises:
    var p = AzureImdsProvider.with_endpoint(
        String("http://127.0.0.1:18080")
    ).with_clock(ManualClock(7_000))
    assert_false(p.has_credential())
    assert_true(p.is_expired_or_near_expiry())
    with assert_raises(contains="no cached token"):
        _ = p.credential()
    var svc = CapturingService(200, String(_IMDS_OK))
    _refresh_imds(p, svc)
    assert_equal(svc.calls, 1)
    assert_equal(svc.method, "GET")
    assert_equal(
        svc.url,
        "http://127.0.0.1:18080/metadata/identity/oauth2/token"
        "?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F",
    )
    assert_equal(svc.metadata_header, "true")
    assert_true(p.has_credential())
    assert_equal(p.credential().token, "imds-token")
    # expires_in "3599" (a JSON string) lands 3599 s after the clock's
    # reading at the fetch.
    assert_equal(p.cached_expiry_ms(), 7_000 + 3_599_000)
    assert_equal(p.credential().expiry_ms, 7_000 + 3_599_000)
    assert_false(p.is_expired_or_near_expiry())


def test_imds_user_assigned_identity_sends_client_id() raises:
    var p = AzureImdsProvider.for_client_id(String("11111111-2222-3333-4444-555555555555"))
    assert_equal(p.endpoint, "http://169.254.169.254")
    p.endpoint = String("http://127.0.0.1:18080")
    var svc = CapturingService(200, String(_IMDS_OK))
    _refresh_imds(p, svc)
    assert_true(
        svc.url.endswith(
            "&client_id=11111111-2222-3333-4444-555555555555"
        ),
        svc.url,
    )


def test_imds_refusals_cache_nothing() raises:
    var p = AzureImdsProvider.with_endpoint(String("http://127.0.0.1:18080"))
    var denied = CapturingService(400, String('{"error":"invalid_request"}'))
    with assert_raises(contains="AzureImdsProvider: token GET returned status 400"):
        _refresh_imds(p, denied)
    assert_false(p.has_credential())
    var empty = CapturingService(200, String('{"access_token":"","expires_in":"60"}'))
    with assert_raises(
        contains="AzureImdsProvider: the token response's access_token is empty"
    ):
        _refresh_imds(p, empty)
    assert_false(p.has_credential())
    var bad = AzureImdsProvider.with_endpoint(String("169.254.169.254"))
    var svc = CapturingService(200, String(_IMDS_OK))
    with assert_raises(contains="endpoint must start with http:// or https://"):
        _refresh_imds(bad, svc)
    assert_equal(svc.calls, 0)


def test_service_principal_grant_on_the_wire() raises:
    var p = ServicePrincipalProvider.with_login_endpoint(
        String("contoso.example"),
        String("app id"),
        String("s3cr&t=+/"),
        String("http"),
        String("127.0.0.1"),
        UInt16(18081),
    ).with_clock(ManualClock(9_000))
    var svc = CapturingService(
        200,
        String('{"token_type":"Bearer","expires_in":3599,"ext_expires_in":3599,'
        '"access_token":"sp-token"}'),
    )
    _refresh_sp(p, svc)
    assert_equal(svc.method, "POST")
    assert_equal(
        svc.url, "http://127.0.0.1:18081/contoso.example/oauth2/v2.0/token"
    )
    assert_equal(svc.content_type, "application/x-www-form-urlencoded")
    var form = String(
        "grant_type=client_credentials&client_id=app%20id"
        "&client_secret=s3cr%26t%3D%2B%2F"
        "&scope=https%3A%2F%2Fstorage.azure.com%2F.default"
    )
    assert_true(svc.wire.endswith(String("\r\n\r\n") + form), svc.wire)
    assert_true(
        svc.wire.find(String("Content-Length: ") + String(form.byte_length())) >= 0,
        svc.wire,
    )
    assert_equal(p.credential().token, "sp-token")
    assert_equal(p.cached_expiry_ms(), 9_000 + 3_599_000)
    assert_equal(p.credential().expiry_ms, 9_000 + 3_599_000)


def test_service_principal_defaults_and_refusals() raises:
    var p = ServicePrincipalProvider.make(
        String("tenant"), String("client"), String("secret")
    )
    assert_equal(p.login_scheme, "https")
    assert_equal(p.login_host, "login.microsoftonline.com")
    assert_equal(p.scope, "https://storage.azure.com/.default")
    with assert_raises(contains="no cached token"):
        _ = p.credential()
    var local = ServicePrincipalProvider.with_login_endpoint(
        String("t"), String("c"), String("s"), String("http"), String("127.0.0.1"), UInt16(18081)
    )
    var denied = CapturingService(401, String('{"error":"invalid_client"}'))
    with assert_raises(contains="ServicePrincipalProvider: token POST returned status 401"):
        _refresh_sp(local, denied)
    assert_false(local.has_credential())
    # A body that is not JSON caches nothing.
    var garbled = CapturingService(
        200, String('{"access_token":"x","expires_in":3599')
    )
    with assert_raises(contains="the token response is not JSON"):
        _refresh_sp(local, garbled)
    assert_false(local.has_credential())


def test_near_expiry_is_due_for_refresh() raises:
    var now = Int64(50_000_000)
    var p = AzureImdsProvider.make().with_clock(ManualClock(now))
    # Inside the 300 s margin: due.
    p.set_credential_for_test(AzureBearerToken(String("t"), now + 60_000), now + 60_000)
    assert_true(p.is_expired_or_near_expiry())
    # Well outside it: not due.
    p.set_credential_for_test(
        AzureBearerToken(String("t"), now + 3_600_000), now + 3_600_000
    )
    assert_false(p.is_expired_or_near_expiry())
    var sp = ServicePrincipalProvider.make(
        String("t"), String("c"), String("s")
    ).with_clock(ManualClock(now))
    sp.set_credential_for_test(AzureBearerToken(String("t"), now - 1), now - 1)
    assert_true(sp.is_expired_or_near_expiry())


# -----------------------------------------------------------------------------
# The login endpoint and the tenant are checked before anything is dialed:
# the client secret is POSTed to that URL, and the tenant is its first path
# segment. A refusal leaves the capturing service uncalled.
# -----------------------------------------------------------------------------


comptime _SP_OK = (
    '{"token_type":"Bearer","expires_in":3599,"access_token":"sp-token"}'
)


def _sp_refused(
    tenant: String,
    scheme: String,
    host: String,
    port: UInt16,
    contains: String,
) raises:
    """Constructing the provider raises `contains`; and a valid provider
    whose fields are then set to these values raises `contains` at refresh,
    with the service never called. Each checkpoint is asserted alone."""
    with assert_raises(contains=contains):
        _ = ServicePrincipalProvider.with_login_endpoint(
            tenant, String("c"), String("s"), scheme, host, port
        )
    var p = ServicePrincipalProvider.with_login_endpoint(
        String("t"),
        String("c"),
        String("s"),
        String("https"),
        String("login.microsoftonline.com"),
        UInt16(0),
    )
    p.tenant_id = tenant
    p.login_scheme = scheme
    p.login_host = host
    p.login_port = port
    var svc = CapturingService(200, String(_SP_OK))
    with assert_raises(contains=contains):
        _refresh_sp(p, svc)
    assert_equal(svc.calls, 0, host)
    assert_false(p.has_credential())


def test_login_scheme_must_be_https() raises:
    comptime msg = "login scheme must be https"
    _sp_refused("t", "http", "login.microsoftonline.com", 0, msg)
    _sp_refused("t", "http", "10.0.0.1", 0, msg)
    _sp_refused("t", "ftp", "login.microsoftonline.com", 0, msg)
    _sp_refused("t", "HTTPS", "login.microsoftonline.com", 0, msg)
    _sp_refused("t", "", "login.microsoftonline.com", 0, msg)


def test_login_host_charset() raises:
    comptime msg = "login host holds a byte outside [A-Za-z0-9.-]"
    # userinfo: the secret would go to evil.example
    _sp_refused("t", "https", "login.microsoftonline.com@evil.example", 0, msg)
    _sp_refused("t", "https", "login microsoftonline.com", 0, msg)
    _sp_refused("t", "https", "login%2emicrosoftonline.com", 0, msg)
    _sp_refused("t", "https", "evil.example/x", 0, msg)
    _sp_refused("t", "https", "evil.example:8443", 0, msg)
    _sp_refused("t", "https", "evil.example?x", 0, msg)
    _sp_refused("t", "https", "evil.example#x", 0, msg)
    _sp_refused("t", "https", "[::1]", 0, msg)
    _sp_refused("t", "https", "", 0, "login host is empty")
    _sp_refused("t", "https", "a..b", 0, "login host has an empty label")
    _sp_refused("t", "https", ".example", 0, "login host has an empty label")
    _sp_refused("t", "https", "example.", 0, "login host has an empty label")


def test_tenant_id_charset() raises:
    comptime msg = "tenant_id holds a byte outside [A-Za-z0-9.-]"
    _sp_refused("a/b", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("a?b", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("a#b", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("a%2Fb", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("a b", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("a\tb", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("a\nb", "https", "login.microsoftonline.com", 0, msg)
    _sp_refused("", "https", "login.microsoftonline.com", 0, "tenant_id is empty")
    _sp_refused(
        "..", "https", "login.microsoftonline.com", 0, "tenant_id has an empty label"
    )
    _sp_refused(
        "a..b", "https", "login.microsoftonline.com", 0, "tenant_id has an empty label"
    )
    # make() checks the tenant too.
    with assert_raises(contains=msg):
        _ = ServicePrincipalProvider.make(
            String("t/../other"), String("c"), String("s")
        )


def test_endpoint_rechecked_before_dialing() raises:
    # The fields are public; one changed after construction is refused at
    # refresh, still before the service is called.
    var p = ServicePrincipalProvider.make(
        String("contoso.onmicrosoft.com"), String("c"), String("s")
    )
    var svc = CapturingService(200, String(_SP_OK))
    p.login_host = String("evil.example/x")
    with assert_raises(contains="login host holds a byte outside"):
        _refresh_sp(p, svc)
    p.login_host = String("login.microsoftonline.com")
    p.login_scheme = String("http")
    with assert_raises(contains="login scheme must be https"):
        _refresh_sp(p, svc)
    p.login_scheme = String("https")
    p.tenant_id = String("a/b")
    with assert_raises(contains="tenant_id holds a byte outside"):
        _refresh_sp(p, svc)
    assert_equal(svc.calls, 0)
    assert_false(p.has_credential())


def test_valid_endpoints_and_tenants() raises:
    # A GUID tenant on the default endpoint.
    var guid = ServicePrincipalProvider.make(
        String("00000000-0000-4000-8000-000000000000"), String("c"), String("s")
    )
    var svc = CapturingService(200, String(_SP_OK))
    _refresh_sp(guid, svc)
    assert_equal(
        svc.url,
        "https://login.microsoftonline.com/00000000-0000-4000-8000-000000000000"
        "/oauth2/v2.0/token",
    )
    assert_equal(guid.credential().token, "sp-token")
    # A verified-domain tenant on a sovereign-cloud authority, with a port.
    var sov = ServicePrincipalProvider.with_login_endpoint(
        String("Contoso.onmicrosoft.us"),
        String("c"),
        String("s"),
        String("https"),
        String("login.microsoftonline.us"),
        UInt16(8443),
    )
    var svc2 = CapturingService(200, String(_SP_OK))
    _refresh_sp(sov, svc2)
    assert_equal(
        svc2.url,
        "https://login.microsoftonline.us:8443/Contoso.onmicrosoft.us"
        "/oauth2/v2.0/token",
    )
    # Plain http is kept for a loopback host only (an emulator, a test).
    var lo = ServicePrincipalProvider.with_login_endpoint(
        String("t"),
        String("c"),
        String("s"),
        String("http"),
        String("localhost"),
        UInt16(18081),
    )
    var svc3 = CapturingService(200, String(_SP_OK))
    _refresh_sp(lo, svc3)
    assert_equal(svc3.url, "http://localhost:18081/t/oauth2/v2.0/token")


# -----------------------------------------------------------------------------
# The token response is read as JSON.
# -----------------------------------------------------------------------------


def _sp_local() raises -> ServicePrincipalProvider[]:
    return ServicePrincipalProvider.with_login_endpoint(
        String("t"),
        String("c"),
        String("s"),
        String("http"),
        String("127.0.0.1"),
        UInt16(18081),
    )


def _sp_token(body: String) raises -> AzureBearerToken:
    var p = _sp_local().with_clock(ManualClock(1_000))
    var svc = CapturingService(200, body)
    _refresh_sp(p, svc)
    return p.credential()


def _sp_body_refused(body: String, contains: String) raises:
    var p = _sp_local()
    var svc = CapturingService(200, body)
    with assert_raises(contains=contains):
        _refresh_sp(p, svc)
    assert_false(p.has_credential())


def test_token_response_json_shapes() raises:
    # expires_in as a numeric string (IMDS's shape) and as a number.
    var t = _sp_token(
        String('{"access_token":"x","expires_in":"3599","token_type":"Bearer"}')
    )
    assert_equal(t.token, "x")
    assert_equal(t.expiry_ms, 1_000 + 3_599_000)
    # Extra fields, nested objects and arrays are skipped; a decoy
    # access_token inside a nested object is not the token.
    t = _sp_token(
        String(
            '{"extra":{"access_token":"decoy","n":[1,{"k":"v"}]},'
            '"token_type":"bearer","ext_expires_in":7199,'
            '"access_token":"real","expires_in":3599,"foo":null}'
        )
    )
    assert_equal(t.token, "real")
    # Escapes in the token are decoded as JSON decodes them.
    t = _sp_token(
        String(
            '{"access_token":"a\\"b\\\\c\\/d\\u0041","expires_in":60}'
        )
    )
    assert_equal(t.token, 'a"b\\c/dA')
    # IMDS reads the same way, and takes the number form too.
    var p = AzureImdsProvider.with_endpoint(String("http://127.0.0.1:18080"))
    var svc = CapturingService(
        200, String('{"access_token":"i\\"t","expires_in":3599}')
    )
    _refresh_imds(p, svc)
    assert_equal(p.credential().token, 'i"t')


def test_token_response_refusals() raises:
    _sp_body_refused(
        String('{"access_token":"x","expires_in":3599'),
        "ServicePrincipalProvider: the token response is not JSON",
    )
    _sp_body_refused(
        String("access_token=x&expires_in=3599"),
        "ServicePrincipalProvider: the token response is not JSON",
    )
    _sp_body_refused(
        String('["access_token","x"]'),
        "the token response is not a JSON object",
    )
    _sp_body_refused(
        String('{"expires_in":3599,"extra":{"access_token":"decoy"}}'),
        "the token response has no access_token string",
    )
    _sp_body_refused(
        String('{"access_token":42,"expires_in":3599}'),
        "the token response has no access_token string",
    )
    _sp_body_refused(
        String('{"access_token":"","expires_in":3599}'),
        "the token response's access_token is empty",
    )
    _sp_body_refused(
        String('{"access_token":"x"}'),
        "the token response has no expires_in",
    )
    _sp_body_refused(
        String('{"access_token":"x","expires_in":"soon"}'),
        "the token response's expires_in is not a positive whole number",
    )
    _sp_body_refused(
        String('{"access_token":"x","expires_in":3599.5}'),
        "the token response's expires_in is not a positive whole number",
    )
    _sp_body_refused(
        String('{"access_token":"x","expires_in":0}'),
        "the token response's expires_in is not a positive whole number",
    )
    _sp_body_refused(
        String('{"access_token":"x","expires_in":3599,"token_type":"pop"}'),
        "the token response's token_type is not Bearer",
    )


def test_token_response_refusal_quotes_no_token() raises:
    var p = _sp_local()
    var svc = CapturingService(
        200, String('{"access_token":"SECRET-TOKEN","expires_in":"never"}')
    )
    var raised = False
    try:
        _refresh_sp(p, svc)
    except e:
        raised = True
        assert_equal(String(e).find("SECRET-TOKEN"), -1, String(e))
    assert_true(raised, "refresh should have raised")


def main() raises:
    test_imds_request_and_cached_token()
    test_imds_user_assigned_identity_sends_client_id()
    test_imds_refusals_cache_nothing()
    test_service_principal_grant_on_the_wire()
    test_service_principal_defaults_and_refusals()
    test_near_expiry_is_due_for_refresh()
    test_login_scheme_must_be_https()
    test_login_host_charset()
    test_tenant_id_charset()
    test_endpoint_rechecked_before_dialing()
    test_valid_endpoints_and_tenants()
    test_token_response_json_shapes()
    test_token_response_refusals()
    test_token_response_refusal_quotes_no_token()
    print("OK")
