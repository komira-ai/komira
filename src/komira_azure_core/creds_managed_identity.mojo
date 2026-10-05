# =============================================================================
# komira_azure_core/creds_managed_identity.mojo — AzureImdsProvider
# =============================================================================
#
# Azure managed identity (system-assigned or user-assigned), the credential
# source on Azure VMs, scale sets, App Service, Functions and AKS. The Azure
# Instance Metadata Service (IMDS) at the link-local address
# `http://169.254.169.254/metadata/identity/oauth2/token` returns an OAuth2
# access token for a requested `resource` (audience):
#
#   GET http://169.254.169.254/metadata/identity/oauth2/token
#         ?api-version=2018-02-01
#         &resource=https://storage.azure.com/
#         [&client_id=<user-assigned-client-id>]
#     Header:  Metadata: true
#
#   Response JSON:
#     {
#       "access_token": "eyJ0...",
#       "expires_in": "3599",          (NOTE: Azure IMDS returns this as a
#       "token_type": "Bearer",         STRING, unlike GCP's number)
#       "resource": "https://storage.azure.com/",
#       ...
#     }
#
# The refresh is synchronous,
# `refresh_with_service[S: HttpService, RT: Runtime, C: Connector]`, driven
# by the caller's HttpClient, runtime and reactor. The provider caches the
# token and its expiry on the wall clock (komira_clock's `now_unix_ms`), and
# reports when it is within the refresh margin of that expiry.
#
# Caller-constructed, NO ambient discovery: the caller explicitly builds
# `AzureImdsProvider.make()` (system-assigned) or `.for_client_id(...)`
# (user-assigned) and drives the refresh. The provider never auto-probes.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_clock import now_unix_ms

from komira_http_client.body import EmptyBody, RequestBody
from komira_http_client.client import build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector

from .azure_token import (
    AzureBearerToken,
    extract_oauth_token_field,
    parse_oauth_expires_in_str,
)


# -----------------------------------------------------------------------------
# Constants — canonical IMDS endpoint + storage audience
# -----------------------------------------------------------------------------

comptime AZURE_IMDS_ENDPOINT: StaticString = "http://169.254.169.254"
comptime AZURE_IMDS_TOKEN_PATH: StaticString = "/metadata/identity/oauth2/token"
comptime AZURE_IMDS_API_VERSION: StaticString = "2018-02-01"
comptime AZURE_STORAGE_RESOURCE: StaticString = "https://storage.azure.com/"
comptime DEFAULT_AZURE_IMDS_REFRESH_MARGIN_SECONDS: Int64 = 300


# -----------------------------------------------------------------------------
# AzureImdsProvider — Azure managed-identity token fetcher
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureImdsProvider(Movable, Deinitable):
    """A provider that fetches OAuth2 access tokens from the Azure
    Instance Metadata Service (IMDS) for a managed identity.

    Refresh contract (mirrors GcpMetadataProvider): synchronous; the
    caller drives the runtime + reactor + connector; refresh fires when
    the cached token is within `refresh_margin_seconds` of expiry.

    Field layout:
      var endpoint: String              — canonical
                                          "http://169.254.169.254"
                                          (overridable for tests)
      var resource: String              — the audience the token is for
                                          (storage.azure.com by default)
      var client_id: String             — user-assigned identity client_id;
                                          empty for system-assigned
      var refresh_margin_seconds: Int64 — proactive-refresh margin (300)
      var _cached_token: AzureBearerToken
      var _cached_expiry_unix_ms: Int64 — -1 means "no cached token"
    """

    var endpoint: String
    var resource: String
    var client_id: String
    var refresh_margin_seconds: Int64
    var _cached_token: AzureBearerToken
    var _cached_expiry_unix_ms: Int64

    @staticmethod
    def make() -> AzureImdsProvider:
        """System-assigned managed identity at the canonical IMDS
        endpoint, requesting a storage-scoped token."""
        return AzureImdsProvider(
            String(AZURE_IMDS_ENDPOINT),
            String(AZURE_STORAGE_RESOURCE),
            String(""),
            DEFAULT_AZURE_IMDS_REFRESH_MARGIN_SECONDS,
            AzureBearerToken(String(""), Int64(-1)),
            Int64(-1),
        )

    @staticmethod
    def for_client_id(client_id: String) -> AzureImdsProvider:
        """User-assigned managed identity — IMDS resolves the token for
        the given identity client_id."""
        return AzureImdsProvider(
            String(AZURE_IMDS_ENDPOINT),
            String(AZURE_STORAGE_RESOURCE),
            client_id,
            DEFAULT_AZURE_IMDS_REFRESH_MARGIN_SECONDS,
            AzureBearerToken(String(""), Int64(-1)),
            Int64(-1),
        )

    @staticmethod
    def with_endpoint(endpoint: String) -> AzureImdsProvider:
        """Custom endpoint (an emulator, or a test's scripted connector)."""
        return AzureImdsProvider(
            endpoint,
            String(AZURE_STORAGE_RESOURCE),
            String(""),
            DEFAULT_AZURE_IMDS_REFRESH_MARGIN_SECONDS,
            AzureBearerToken(String(""), Int64(-1)),
            Int64(-1),
        )

    def credential(self) raises -> AzureBearerToken:
        """Return the cached token. Raises if no token has been fetched
        yet — callers should fire `refresh_with_service` first."""
        if self._cached_expiry_unix_ms < Int64(0):
            raise Error(
                "AzureImdsProvider.credential: no cached token; call"
                " refresh_with_service() first"
            )
        return self._cached_token

    def has_credential(self) -> Bool:
        """Diagnostic: whether the provider has a non-empty cached token."""
        return self._cached_expiry_unix_ms >= Int64(0)

    def cached_expiry_unix_ms(self) -> Int64:
        """Diagnostic: cached token expiry, or -1 if none."""
        return self._cached_expiry_unix_ms

    def is_expired_or_near_expiry(self) -> Bool:
        """Whether the cached token is missing, expired, or within
        `refresh_margin_seconds` of expiry. Wall clock from
        komira_clock's `now_unix_ms()`."""
        if self._cached_expiry_unix_ms < Int64(0):
            return True
        var now_ms = now_unix_ms()
        var margin_ms = self.refresh_margin_seconds * Int64(1000)
        return now_ms + margin_ms >= self._cached_expiry_unix_ms

    def refresh_with_service[S: HttpService, RT: Runtime, C: Connector](
        mut self,
        mut http: S,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises:
        """Production HTTP-fetch refresh path.

        Single GET against {endpoint}/metadata/identity/oauth2/token with
        the mandatory `Metadata: true` header. On success, the parsed
        access_token is cached and expiry is set to
        `now + expires_in * 1000` (ms).
        """
        var path = String(AZURE_IMDS_TOKEN_PATH)
        var query = String("api-version=") + String(AZURE_IMDS_API_VERSION)
        query += "&resource=" + _percent_encode_query_value(self.resource)
        if self.client_id.byte_length() > 0:
            query += "&client_id=" + _percent_encode_query_value(self.client_id)
        var url = _parse_http_endpoint_with_path(self.endpoint, path^)
        url.query = query^
        var headers = HeaderMap()
        # IMDS REQUIRES this header (anti-SSRF safeguard) — bare GET 400s.
        headers.append(String("Metadata"), String("true"))
        var req = build_get_request(url^, headers^)
        var resp = http.call[RT, C, EmptyBody](req^, connector, reactor)
        var status_int = Int(resp.status)
        if status_int < 200 or status_int >= 300:
            raise Error(
                String("AzureImdsProvider: token GET returned status ")
                + String(status_int)
            )
        var body = _response_body_string(resp)
        var access_token = extract_oauth_token_field(
            body, String("access_token")
        )
        if access_token.byte_length() == 0:
            raise Error(
                "AzureImdsProvider: missing access_token in response"
            )
        # Azure IMDS returns expires_in as a STRING.
        var expires_in = parse_oauth_expires_in_str(body)
        var now_ms = now_unix_ms()
        var expiry_ms = now_ms + (expires_in * Int64(1000))
        self._cached_token = AzureBearerToken(access_token^, expiry_ms)
        self._cached_expiry_unix_ms = expiry_ms

    def set_credential_for_test(
        mut self, var token: AzureBearerToken, expiry_unix_ms: Int64
    ):
        """Test-only: bypass refresh_with_service and inject a token
        directly. Production code calls refresh_with_service() through
        HTTP."""
        self._cached_token = token^
        self._cached_expiry_unix_ms = expiry_unix_ms


# -----------------------------------------------------------------------------
# Internal helpers — query encoding + endpoint parse + body read
# -----------------------------------------------------------------------------


def _hex_upper(v: Int) -> String:
    if v < 10:
        return chr(0x30 + v)
    return chr(0x41 + (v - 10))


def _percent_encode_query_value(s: String) -> String:
    """RFC 3986 percent-encode a query-parameter value (the storage
    resource audience contains `:` and `/`)."""
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


def _parse_http_endpoint_with_path(
    endpoint: String, path: String
) raises -> Url:
    """Parse `endpoint` (e.g. "http://169.254.169.254" or
    "http://127.0.0.1:18080") and append `path` into a fully-resolved
    Url. Strict shape — no trailing `/` on endpoint."""
    var endpoint_bs = endpoint.as_bytes()
    var n = len(endpoint_bs)
    var scheme: String
    var rest_start: Int
    if n >= 7 and endpoint_bs[0] == UInt8(0x68) and endpoint_bs[1] == UInt8(
        0x74
    ) and endpoint_bs[2] == UInt8(0x74) and endpoint_bs[3] == UInt8(
        0x70
    ) and endpoint_bs[4] == UInt8(0x3A) and endpoint_bs[5] == UInt8(
        0x2F
    ) and endpoint_bs[6] == UInt8(0x2F):
        scheme = String("http")
        rest_start = 7
    elif n >= 8 and endpoint_bs[0] == UInt8(0x68) and endpoint_bs[1] == UInt8(
        0x74
    ) and endpoint_bs[2] == UInt8(0x74) and endpoint_bs[3] == UInt8(
        0x70
    ) and endpoint_bs[4] == UInt8(0x73) and endpoint_bs[5] == UInt8(
        0x3A
    ) and endpoint_bs[6] == UInt8(0x2F) and endpoint_bs[7] == UInt8(0x2F):
        scheme = String("https")
        rest_start = 8
    else:
        raise Error(
            "AzureImdsProvider: endpoint must start with http:// or"
            " https://, got: " + endpoint
        )
    var colon = UInt8(0x3A)
    var slash = UInt8(0x2F)
    var i = rest_start
    while i < n and endpoint_bs[i] != colon and endpoint_bs[i] != slash:
        i += 1
    var host = String("")
    var bi = rest_start
    while bi < i:
        host += chr(Int(endpoint_bs[bi]))
        bi += 1
    var port_val: UInt16 = UInt16(0)
    if i < n and endpoint_bs[i] == colon:
        i += 1
        var port_str = String("")
        while i < n and endpoint_bs[i] != slash:
            port_str += chr(Int(endpoint_bs[i]))
            i += 1
        try:
            port_val = UInt16(Int(port_str))
        except:
            raise Error(
                "AzureImdsProvider: malformed port in endpoint: " + endpoint
            )
    return Url(scheme=scheme^, host=host^, port=port_val, path=path)


def _response_body_string(
    ref resp: ClientResponse[BufferedResponseBody]
) -> String:
    """Copy out the response body bytes as an owned String. Assumes
    ASCII / UTF-8 content (IMDS emits JSON ASCII)."""
    ref src = resp.body.bytes_ref()
    var out = String()
    var i = 0
    var n = src.__len__()
    while i < n:
        out += chr(Int(src[i]))
        i += 1
    return out^
