# =============================================================================
# komira_azure_core/creds_service_principal.mojo — ServicePrincipalProvider
# =============================================================================
#
# An Entra ID service principal authenticates with the OAuth2
# client-credentials grant against its tenant's token endpoint:
#
#   POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
#     Content-Type: application/x-www-form-urlencoded
#     body:
#       grant_type=client_credentials
#       &client_id=<app-id>
#       &client_secret=<secret>
#       &scope=https://storage.azure.com/.default
#
#   Response JSON (Entra returns expires_in as a NUMBER):
#     {"token_type":"Bearer","expires_in":3599,"access_token":"eyJ0..."}
#
# The token URL is checked before anything is dialed, at construction and
# again at every refresh (the fields are public): the scheme is `https`, or
# `http` for a loopback host only (`localhost`, `127.0.0.1`: an emulator or a
# test); the host is a non-empty RFC 3986 reg-name of letters, digits, `-`
# and `.` with no empty label, so no userinfo, port, path, space or
# percent-escape can ride in it; the port is a UInt16, 0 meaning the
# scheme's default. The tenant (a GUID or a verified domain name) is the
# token path's first segment and is held to the same charset, so a `/`, `?`,
# `#`, `%`, whitespace or `..` cannot rewrite the path the secret is POSTed
# to.
#
# Caller-constructed, NO ambient discovery: the caller explicitly supplies
# (tenant_id, client_id, client_secret) — typically from a secret store —
# and drives the refresh. The provider never reads the environment or
# probes a metadata endpoint.
#
# The refresh is synchronous, `refresh_with_service[S, RT, C]`, driven by the
# caller's HttpClient, runtime and reactor; the provider caches the token and
# its wall-clock expiry, as AzureImdsProvider does.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_clock import now_unix_ms

from komira_http_client.body import BytesBody, RequestBody
from komira_http_client.client import build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.request_writer import method_post
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector

from .azure_token import (
    AzureBearerToken,
    OAuthTokenResponse,
    parse_oauth_token_response,
)


# -----------------------------------------------------------------------------
# Constants — canonical Entra token endpoint + storage scope
# -----------------------------------------------------------------------------

comptime ENTRA_LOGIN_HOST: StaticString = "login.microsoftonline.com"
comptime AZURE_STORAGE_SCOPE: StaticString = "https://storage.azure.com/.default"
comptime DEFAULT_SP_REFRESH_MARGIN_SECONDS: Int64 = 300


# -----------------------------------------------------------------------------
# ServicePrincipalProvider — Entra client-credentials grant
# -----------------------------------------------------------------------------


@fieldwise_init
struct ServicePrincipalProvider(Movable, Deinitable):
    """A provider that exchanges an Entra service-principal client_id +
    client_secret for an OAuth2 access token via the client-credentials
    grant.

    Field layout:
      var tenant_id: String             — the Entra tenant (GUID or
                                          verified domain)
      var client_id: String             — the app registration's
                                          application (client) ID
      var client_secret: String         — the app registration secret
      var scope: String                 — OAuth2 scope (storage .default)
      var login_host: String            — login.microsoftonline.com
                                          (overridable for tests)
      var login_scheme: String          — "https"; "http" only for a
                                          loopback host
      var login_port: UInt16            — 0 = scheme default
      var refresh_margin_seconds: Int64 — proactive-refresh margin (300)
      var _cached_token: AzureBearerToken
      var _cached_expiry_unix_ms: Int64 — -1 means "no cached token"
    """

    var tenant_id: String
    var client_id: String
    var client_secret: String
    var scope: String
    var login_host: String
    var login_scheme: String
    var login_port: UInt16
    var refresh_margin_seconds: Int64
    var _cached_token: AzureBearerToken
    var _cached_expiry_unix_ms: Int64

    @staticmethod
    def make(
        tenant_id: String,
        client_id: String,
        client_secret: String,
    ) raises -> ServicePrincipalProvider:
        """Default config — real Entra endpoint, storage .default scope.
        Raises if `tenant_id` is not a GUID or domain name (see the module
        header)."""
        _check_tenant_id(tenant_id)
        return ServicePrincipalProvider(
            tenant_id,
            client_id,
            client_secret,
            String(AZURE_STORAGE_SCOPE),
            String(ENTRA_LOGIN_HOST),
            String("https"),
            UInt16(0),
            DEFAULT_SP_REFRESH_MARGIN_SECONDS,
            AzureBearerToken(String(""), Int64(-1)),
            Int64(-1),
        )

    @staticmethod
    def with_login_endpoint(
        tenant_id: String,
        client_id: String,
        client_secret: String,
        login_scheme: String,
        login_host: String,
        login_port: UInt16,
    ) raises -> ServicePrincipalProvider:
        """Custom token endpoint: a sovereign cloud's authority, an
        emulator, or a test's scripted connector. Raises, before anything
        is dialed, unless `login_scheme` is `https` (or `http` with a
        loopback host), `login_host` is a reg-name of `[A-Za-z0-9.-]` with
        no empty label, and `tenant_id` is held to the same charset."""
        _check_login_endpoint(login_scheme, login_host)
        _check_tenant_id(tenant_id)
        return ServicePrincipalProvider(
            tenant_id,
            client_id,
            client_secret,
            String(AZURE_STORAGE_SCOPE),
            login_host,
            login_scheme,
            login_port,
            DEFAULT_SP_REFRESH_MARGIN_SECONDS,
            AzureBearerToken(String(""), Int64(-1)),
            Int64(-1),
        )

    def credential(self) raises -> AzureBearerToken:
        """Return the cached token. Raises if none fetched yet."""
        if self._cached_expiry_unix_ms < Int64(0):
            raise Error(
                "ServicePrincipalProvider.credential: no cached token;"
                " call refresh_with_service() first"
            )
        return self._cached_token

    def has_credential(self) -> Bool:
        return self._cached_expiry_unix_ms >= Int64(0)

    def cached_expiry_unix_ms(self) -> Int64:
        return self._cached_expiry_unix_ms

    def is_expired_or_near_expiry(self) -> Bool:
        if self._cached_expiry_unix_ms < Int64(0):
            return True
        var now_ms = now_unix_ms()
        var margin_ms = self.refresh_margin_seconds * Int64(1000)
        return now_ms + margin_ms >= self._cached_expiry_unix_ms

    def _token_path(self) -> String:
        return (
            String("/")
            + self.tenant_id
            + String("/oauth2/v2.0/token")
        )

    def _form_body(self) -> String:
        """Build the application/x-www-form-urlencoded request body."""
        var body = String("grant_type=client_credentials")
        body += "&client_id=" + _percent_encode_form_value(self.client_id)
        body += "&client_secret=" + _percent_encode_form_value(
            self.client_secret
        )
        body += "&scope=" + _percent_encode_form_value(self.scope)
        return body^

    def refresh_with_service[S: HttpService, RT: Runtime, C: Connector](
        mut self,
        mut http: S,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises:
        """Production HTTP-fetch refresh path: POST the client-credentials
        grant to the Entra token endpoint, parse the access_token +
        expires_in, cache the token. The endpoint and tenant are checked
        again first, so a field changed after construction is refused
        before the request is built."""
        _check_login_endpoint(self.login_scheme, self.login_host)
        _check_tenant_id(self.tenant_id)
        var url = Url(
            scheme=self.login_scheme,
            host=self.login_host,
            port=self.login_port,
            path=self._token_path(),
        )
        var headers = HeaderMap()
        headers.append(
            String("Content-Type"),
            String("application/x-www-form-urlencoded"),
        )
        var body = BytesBody.from_str(self._form_body())
        var req = build_request_with_body[BytesBody](
            method_post(), url^, headers^, body^
        )
        var resp = http.call[RT, C, BytesBody](req^, connector, reactor)
        var status_int = Int(resp.status)
        if status_int < 200 or status_int >= 300:
            raise Error(
                String(
                    "ServicePrincipalProvider: token POST returned status "
                )
                + String(status_int)
            )
        var parsed: OAuthTokenResponse
        try:
            parsed = parse_oauth_token_response(resp.body.take_bytes())
        except e:
            raise Error(String("ServicePrincipalProvider: ") + String(e))
        var access_token = parsed.access_token.copy()
        var expires_in = parsed.expires_in
        var now_ms = now_unix_ms()
        var expiry_ms = now_ms + (expires_in * Int64(1000))
        self._cached_token = AzureBearerToken(access_token^, expiry_ms)
        self._cached_expiry_unix_ms = expiry_ms

    def set_credential_for_test(
        mut self, var token: AzureBearerToken, expiry_unix_ms: Int64
    ):
        """Test-only: bypass refresh_with_service and inject a token."""
        self._cached_token = token^
        self._cached_expiry_unix_ms = expiry_unix_ms


# -----------------------------------------------------------------------------
# Internal helpers — form encoding + body read
# -----------------------------------------------------------------------------


def _hex_upper(v: Int) -> String:
    if v < 10:
        return chr(0x30 + v)
    return chr(0x41 + (v - 10))


def _percent_encode_form_value(s: String) -> String:
    """application/x-www-form-urlencoded value encoding. Encodes
    everything that is not unreserved (RFC 3986). Spaces become %20 (not
    `+`) — both are accepted by the Entra endpoint, and %20 is the
    RFC-3986-pure form."""
    var out = String()
    var bs = s.as_bytes()
    var n = len(bs)
    var i = 0
    while i < n:
        var c = bs[i]
        var is_unreserved = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2D)
            or c == UInt8(0x2E)
            or c == UInt8(0x5F)
            or c == UInt8(0x7E)
        )
        if is_unreserved:
            out += chr(Int(c))
        else:
            out += "%"
            out += _hex_upper(Int(c) >> 4)
            out += _hex_upper(Int(c) & 0xF)
        i += 1
    return out^



# -----------------------------------------------------------------------------
# The token URL's checks — every one runs before a request exists
# -----------------------------------------------------------------------------


def _check_dns_name(what: String, s: String) raises:
    """A non-empty run of `[A-Za-z0-9.-]` with no empty label: an RFC 3986
    reg-name narrowed to DNS, so it holds no userinfo (`@`), port (`:`),
    path (`/`), query, fragment, whitespace or percent-escape."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("ServicePrincipalProvider: " + what + " is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise Error(
                "ServicePrincipalProvider: " + what + " holds a byte outside"
                " [A-Za-z0-9.-]"
            )
    var dot = UInt8(ord("."))
    if b[0] == dot or b[len(b) - 1] == dot or s.find("..") >= 0:
        raise Error("ServicePrincipalProvider: " + what + " has an empty label")


def _is_loopback_host(host: String) -> Bool:
    return host == "localhost" or host == "127.0.0.1"


def _check_login_endpoint(scheme: String, host: String) raises:
    """The login authority the client secret is POSTed to."""
    _check_dns_name(String("login host"), host)
    if scheme == "https":
        return
    if scheme == "http" and _is_loopback_host(host):
        return
    raise Error(
        "ServicePrincipalProvider: login scheme must be https (http only"
        " for a loopback host: localhost, 127.0.0.1)"
    )


def _check_tenant_id(tenant_id: String) raises:
    """The tenant, a GUID or a verified domain name: the token path's first
    segment."""
    _check_dns_name(String("tenant_id"), tenant_id)
