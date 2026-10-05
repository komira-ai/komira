# AzureImdsProvider and ServicePrincipalProvider over a capturing HttpService:
# no socket, no metadata service, no tenant. The service records the request
# each provider put on the wire (method, URL, headers, the serialized bytes
# with the body) and answers with a scripted status and body.
#
# Rows: IMDS asks for a storage-scoped token with the mandatory `Metadata:
# true` header (and the user-assigned `client_id` when one is set), reads
# `expires_in` as the JSON string IMDS sends, and caches the token against
# the wall clock; the service principal POSTs the form-encoded
# client-credentials grant to `/<tenant>/oauth2/v2.0/token` with its values
# percent-encoded, and reads `expires_in` as the JSON number Entra sends; a
# non-2xx answer and a body with no token are named errors that leave no
# token cached; and a token near its expiry is due for a refresh.
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
from komira_clock import now_unix_ms
from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


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


def _refresh_imds(mut p: AzureImdsProvider, mut svc: CapturingService) raises:
    var conn = _connector()
    var reactor = _reactor()
    p.refresh_with_service[CapturingService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


def _refresh_sp(
    mut p: ServicePrincipalProvider, mut svc: CapturingService
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
    var p = AzureImdsProvider.with_endpoint(String("http://127.0.0.1:18080"))
    assert_false(p.has_credential())
    assert_true(p.is_expired_or_near_expiry())
    with assert_raises(contains="no cached token"):
        _ = p.credential()
    var svc = CapturingService(200, String(_IMDS_OK))
    var before = now_unix_ms()
    _refresh_imds(p, svc)
    var after = now_unix_ms()
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
    # expires_in "3599" (a JSON string) lands 3599 s after the fetch.
    var expiry = p.cached_expiry_unix_ms()
    assert_true(expiry >= before + 3_599_000 and expiry <= after + 3_599_000)
    assert_equal(p.credential().expiry_unix_ms, expiry)
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
    with assert_raises(contains="AzureImdsProvider: missing access_token"):
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
    )
    var svc = CapturingService(
        200,
        String('{"token_type":"Bearer","expires_in":3599,"ext_expires_in":3599,'
        '"access_token":"sp-token"}'),
    )
    var before = now_unix_ms()
    _refresh_sp(p, svc)
    var after = now_unix_ms()
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
    var expiry = p.cached_expiry_unix_ms()
    assert_true(expiry >= before + 3_599_000 and expiry <= after + 3_599_000)


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
    # Entra sends a number; a string `expires_in` is not its shape.
    var stringy = CapturingService(
        200, String('{"access_token":"x","expires_in":"3599"}')
    )
    with assert_raises(contains="value not numeric"):
        _refresh_sp(local, stringy)
    assert_false(local.has_credential())


def test_near_expiry_is_due_for_refresh() raises:
    var p = AzureImdsProvider.make()
    var now = now_unix_ms()
    # Inside the 300 s margin: due.
    p.set_credential_for_test(AzureBearerToken(String("t"), now + 60_000), now + 60_000)
    assert_true(p.is_expired_or_near_expiry())
    # Well outside it: not due.
    p.set_credential_for_test(
        AzureBearerToken(String("t"), now + 3_600_000), now + 3_600_000
    )
    assert_false(p.is_expired_or_near_expiry())
    var sp = ServicePrincipalProvider.make(String("t"), String("c"), String("s"))
    sp.set_credential_for_test(AzureBearerToken(String("t"), now - 1), now - 1)
    assert_true(sp.is_expired_or_near_expiry())


def main() raises:
    test_imds_request_and_cached_token()
    test_imds_user_assigned_identity_sends_client_id()
    test_imds_refusals_cache_nothing()
    test_service_principal_grant_on_the_wire()
    test_service_principal_defaults_and_refusals()
    test_near_expiry_is_due_for_refresh()
    print("OK")
