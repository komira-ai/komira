# komira_azure_core

Azure credentials that are not specific to one service:

- `AzureSharedKey` (a Storage account name and its base64 key) and
  `AzureSas` (a shared-access-signature query string), each with a static
  provider, `SharedKeyProvider` and `SasProvider`;
- `AzureBearerToken`, an OAuth2 access token with its expiry, and
  `parse_oauth_token_response`, the reader of a token endpoint's JSON answer
  (`expires_in` as a number or as a string of digits; a malformed answer is
  refused with a reason that repeats none of the body);
- `AzureImdsProvider`: a managed identity's token from the Azure Instance
  Metadata Service;
- `ServicePrincipalProvider`: the Microsoft Entra client-credentials grant.
  Its login endpoint and directory id are checked when it is built, before
  anything is sent: `https` only (plain `http` only to a loopback host), and
  a host name of `[A-Za-z0-9.-]` with no empty label.

The two token providers send through any komira_http_client `HttpService`
on a komira_async reactor, cache the token, and keep its expiry on a
komira_retry `MonotonicClock` (`SystemClock` unless `with_clock` swaps it);
`is_expired_or_near_expiry` turns true 300 s before expiry by default. Every
setting is a parameter: nothing here reads the environment. Shared Key
request signing is Storage-specific and lives in komira_azure_blob.

## Examples

The credential types, and a token endpoint's answer read. A refusal names
what is wrong and never repeats the token:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_azure_core import SasProvider, SharedKeyProvider, parse_oauth_token_response

var key = SharedKeyProvider.make(String("demoaccount"), String("a2V5Cg==")).credential()
assert_equal(key.account, "demoaccount")
assert_equal(key.key_b64, "a2V5Cg==")
var sas = SasProvider.make(String("sv=2026-10-01&sp=r&sig=abc")).credential()
assert_equal(sas.query_string, "sv=2026-10-01&sp=r&sig=abc")

# Entra writes expires_in as a number, IMDS as a string of digits.
var entra = List[UInt8]()
entra.extend(Span(String(
    '{"token_type":"Bearer","expires_in":3599,"access_token":"eyJ0.x.y"}'
).as_bytes()))
var answer = parse_oauth_token_response(entra)
assert_equal(answer.access_token, "eyJ0.x.y")
assert_equal(answer.expires_in, 3599)

var imds = List[UInt8]()
imds.extend(Span(String(
    '{"access_token":"t","expires_in":"86399","resource":"https://storage.azure.com/"}'
).as_bytes()))
assert_equal(parse_oauth_token_response(imds).expires_in, 86399)

var no_expiry = List[UInt8]()
no_expiry.extend(Span(String('{"access_token":"SECRET"}').as_bytes()))
var why = String("")
try:
    _ = parse_oauth_token_response(no_expiry)
except e:
    why = String(e)
assert_true("has no expires_in" in why)
assert_false("SECRET" in why)
```

A service principal. Built with the defaults it asks
`login.microsoftonline.com` for a Storage-scoped token; a login endpoint
that could send the client secret somewhere else is refused when the
provider is built:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises -->
```mojo
from komira_azure_core import ServicePrincipalProvider

var principal = ServicePrincipalProvider.make(
    String("contoso.example"), String("app-id"), String("app-secret")
)
assert_equal(principal.login_scheme, "https")
assert_equal(principal.login_host, "login.microsoftonline.com")
assert_equal(principal.scope, "https://storage.azure.com/.default")
assert_false(principal.has_credential())

with assert_raises(contains="login scheme must be https"):
    _ = ServicePrincipalProvider.with_login_endpoint(
        String("contoso.example"), String("app-id"), String("app-secret"),
        String("http"), String("login.microsoftonline.com"), UInt16(0),
    )
with assert_raises(contains="outside [A-Za-z0-9.-]"):
    _ = ServicePrincipalProvider.with_login_endpoint(
        String("contoso.example"), String("app-id"), String("app-secret"),
        String("https"), String("login.microsoftonline.com@evil.example"), UInt16(0),
    )
```

A refresh, through an `HttpService` that answers from a canned body and
keeps the request it was given (no socket), on a `ManualClock`. The grant
is a form POST to `/<directory>/oauth2/v2.0/token`, every value
percent-encoded; the token is cached with its expiry read on the injected
clock, and comes due for refresh 300 s before it:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from komira_azure_core import ServicePrincipalProvider
-->
```mojo module
from std.sys.info import CompilationTarget
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock


struct CannedTokenService(HttpService, Movable, Deinitable):
    """Answers every call 200 with `body`; keeps the last request's bytes."""

    var body: String
    var sent: String

    def __init__(out self, var body: String):
        self.body = body^
        self.sent = String("")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self.sent = String(unsafe_from_utf8=Span(req.request_bytes))
        _ = req^
        var bytes = List[UInt8]()
        bytes.extend(Span(self.body.as_bytes()))
        var resp = ClientResponse[BufferedResponseBody](BufferedResponseBody.from_bytes(bytes^))
        resp.status = Int32(200)
        resp.reason = String("OK")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^


def new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def main() raises:
    var provider = ServicePrincipalProvider.make(
        String("contoso.example"), String("app id"), String("s3cr&t")
    ).with_clock(ManualClock(Int64(9_000)))
    var service = CannedTokenService(
        String('{"token_type":"Bearer","expires_in":3599,"access_token":"sp-token"}')
    )
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = new_reactor()
    provider.refresh_with_service[CannedTokenService, PerCoreAsyncRuntime[NoopSink], ScriptedConnector](
        service, connector, reactor
    )

    assert_true(service.sent.startswith("POST "))
    assert_true("/contoso.example/oauth2/v2.0/token" in service.sent)
    assert_true(service.sent.endswith(
        "\r\n\r\ngrant_type=client_credentials&client_id=app%20id&client_secret=s3cr%26t"
        + "&scope=https%3A%2F%2Fstorage.azure.com%2F.default"
    ))
    assert_equal(provider.credential().token, "sp-token")
    assert_equal(provider.cached_expiry_ms(), Int64(9_000 + 3_599_000))

    assert_false(provider.is_expired_or_near_expiry())
    provider.clock().now = Int64(9_000 + 3_599_000 - 300_000)  # the margin
    assert_true(provider.is_expired_or_near_expiry())
```
