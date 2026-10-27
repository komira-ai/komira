# =============================================================================
# azure_token_source.mojo: the Entra access-token seam under the Key Vault store.
# =============================================================================
#
# The Key Vault REST call needs one thing from the runtime identity: an Entra
# OAuth2 access token for the Key Vault audience. In production it comes from
# one of two providers in komira_azure_core:
#   * `ServicePrincipalProvider`: the client-credentials grant (tenant id,
#     client id and client secret POSTed to the Entra token endpoint);
#   * `AzureImdsProvider`: a managed identity (system- or user-assigned) minted
#     off the Instance Metadata Service. No credential is stored.
#
# AUDIENCE. The providers default to the Storage audience
# (`https://storage.azure.com/`). Key Vault rejects such a token with 401, so
# the sources here set the provider's public `scope` (service principal,
# `https://vault.azure.net/.default`) or `resource` (IMDS,
# `https://vault.azure.net`) field after construction.
#
# The seam is `access_token() -> String`, `raises` on a mint failure (a resolve
# never falls back to anonymous). A test binds `StaticAzureTokenSource`; the
# live sources drive the provider's `refresh_with_service` over a fresh
# connector and `BlockingRuntime`, and re-mint only when the cached token is
# within the provider's refresh margin of expiry.
#
# The token is a short-lived runtime credential and is never logged. No
# UnsafePointer crosses the seam, no wildcard origin, no `unsafe_from_address`.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.client import HttpClient
from komira_http_core.transport.io_stream import Connector

from komira_azure_core.creds_service_principal import ServicePrincipalProvider
from komira_azure_core.creds_managed_identity import AzureImdsProvider
from komira_retry import SystemClock


# =============================================================================
# §0 — the Key Vault AAD audience facts (the audience pivot off Storage).
# =============================================================================
# The Entra OAuth2 SCOPE for a service-principal Key Vault token (the
# client-credentials grant form). Distinct from the objectstore's
# `https://storage.azure.com/.default`.
comptime AZURE_KV_SP_SCOPE: String = "https://vault.azure.net/.default"
# The IMDS RESOURCE (audience) for a managed-identity Key Vault token. The IMDS
# form is the bare resource (no `/.default`).
comptime AZURE_KV_IMDS_RESOURCE: String = "https://vault.azure.net"


# =============================================================================
# §1 — AzureTokenSource — the pluggable AAD-token seam.
# =============================================================================
trait AzureTokenSource(Movable, Deinitable):
    """Produce a fresh AAD (Entra) OAuth2 access token (the `Bearer` value) for
    the Azure Key Vault REST call, scoped to the Key Vault audience
    (`https://vault.azure.net`). A mint failure RAISES (fail fast and loud: a
    resolve path that cannot authenticate must not fall back to anonymous and
    then 401/403 on the Key Vault read). No UnsafePointer crosses the boundary;
    there is no stored credential in the managed-identity case. The input is
    implicit (the runtime identity or the configured service principal) and the
    output is the Bearer token string."""

    def access_token(mut self) raises -> String:
        ...


# =============================================================================
# §2 — StaticAzureTokenSource — a canned token (the test double).
#
# Returns a fixed Bearer string with NO network. Lets the store test assert the
# `Authorization: Bearer <token>` header was stamped on the outbound request
# (the canned value flows to the wire) — and lets every resolve test run offline.
# A live source (the SP / IMDS sources below) never holds a fixed token like
# this; it mints per-use from Entra / the metadata server.
# =============================================================================
struct StaticAzureTokenSource(AzureTokenSource, Movable):
    """An in-memory, canned `AzureTokenSource` (the TEST DOUBLE). Returns a fixed
    Bearer token on every `access_token()` and records a `mint_count` (the
    auth-call proof). No network, no reactor."""

    var _token: String
    var _mint_count: Int

    def __init__(out self, var token: String):
        self._token = token^
        self._mint_count = 0

    def mint_count(self) -> Int:
        """How many times a token was requested (the auth-call proof)."""
        return self._mint_count

    def access_token(mut self) raises -> String:
        """Return the canned token + bump the mint count. NEVER raises (the
        double always has a token); a live source raises on a mint failure."""
        self._mint_count += 1
        return self._token.copy()


# =============================================================================
# §3 — ServicePrincipalTokenSource[C] — the live Entra client-credentials source
#   over komira_azure_core's `ServicePrincipalProvider`.
#
# Wraps the provider with the Key Vault audience pinned (the `scope`
# field overridden off the storage default). On each `access_token()` it drives
# the provider's synchronous `refresh_with_service` over a FRESH connector +
# `BlockingRuntime` then
# hands back the cached `access_token`. The caller-supplied `client_secret` is a
# secret (sourced from a secret store); it lives on the provider, never logged.
# A mint failure RAISES (fail-LOUD — never anonymous).
# =============================================================================
struct ServicePrincipalTokenSource[C: Connector](AzureTokenSource, Movable):
    """The live Entra client-credentials `AzureTokenSource`: exchanges a
    service-principal `client_secret` for a Key-Vault-scoped AAD token via
    `ServicePrincipalProvider.refresh_with_service`, with the audience
    pinned to `https://vault.azure.net/.default` (the audience pivot off the
    provider's storage default). A mint failure RAISES (fail-LOUD — the error
    NEVER carries the token or the client_secret). The connector factory is a
    `def () thin -> C` fn-ptr field (a code pointer, no heap).

    Fields are that fn-ptr and the moved-in provider (flat-String values). No
    wildcard-origin field, no UnsafePointer field; the minted token is a value,
    never logged."""

    var _mk_connector: def () thin -> Self.C
    var _provider: ServicePrincipalProvider[SystemClock]

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        tenant_id: String,
        client_id: String,
        var client_secret: String,
    ) raises:
        """Raises if `tenant_id` is not a GUID or domain name (the provider checks).
        Construct with the connector factory + the Entra service-principal
        identity (tenant + app id + secret). The audience is PINNED to the Key
        Vault scope (overriding the provider's storage default)."""
        self._mk_connector = mk_connector
        var provider = ServicePrincipalProvider.make(
            tenant_id, client_id, client_secret^
        )
        # The audience PIVOT: override the storage `.default` scope with the Key
        # Vault scope. The field is public (`@fieldwise_init`), so this needs no
        # modification of the provider.
        provider.scope = AZURE_KV_SP_SCOPE
        self._provider = provider^

    def access_token(mut self) raises -> String:
        """Mint (or re-use the cached) Key-Vault-scoped AAD token by driving the
        provider's `refresh_with_service` over a fresh connector +
        BlockingRuntime. A mint failure RAISES — the error NEVER carries the
        token body or the client_secret."""
        if self._provider.is_expired_or_near_expiry():
            # `HttpClient.call` (the HttpService surface `refresh_with_service`
            # drives) dials the per-call connector it is HANDED, not the client's
            # own — so the client is built only for its config; the dialing
            # connector is a SECOND fresh one off the same `thin` factory.
            var client_connector = self._mk_connector()
            var http = HttpClient[Self.C].with_defaults(client_connector^)
            var dial_connector = self._mk_connector()
            var rt = BlockingRuntime[NoopSink].new(
                NoopSink(_placeholder=UInt8(0))
            )
            ref reactor = rt.reactor()
            self._provider.refresh_with_service[
                HttpClient[Self.C], BlockingRuntime[NoopSink], Self.C
            ](http, dial_connector, reactor)
        var bearer = self._provider.credential()
        return bearer.token.copy()


# =============================================================================
# §4 — ManagedIdentityTokenSource[C] — the live Azure managed-identity source
#   over komira_azure_core's `AzureImdsProvider`.
#
# Wraps the IMDS provider with the Key Vault resource pinned (the
# `resource` field overridden off the storage default). On each `access_token()`
# it drives the provider's `refresh_with_service` over a FRESH connector +
# `BlockingRuntime`, then hands back the cached token. NO credential is stored:
# the runtime identity IS the credential. A mint failure RAISES (fail-LOUD).
# =============================================================================
struct ManagedIdentityTokenSource[C: Connector](AzureTokenSource, Movable):
    """The live Azure managed-identity `AzureTokenSource`: mints a
    Key-Vault-scoped AAD token off the Instance Metadata Service via
    `AzureImdsProvider.refresh_with_service`, with the resource pinned to
    `https://vault.azure.net` (the audience pivot off the provider's storage
    default). NO credential is stored. A mint failure RAISES (fail-LOUD — the
    error NEVER carries the token). The connector factory is a `def () thin -> C`
    fn-ptr field (a code pointer, no heap).

    Fields are that fn-ptr and the moved-in provider. No wildcard-origin field,
    no UnsafePointer field; the minted token is a value, never logged."""

    var _mk_connector: def () thin -> Self.C
    var _provider: AzureImdsProvider[SystemClock]

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
    ):
        """System-assigned managed identity. The audience is PINNED to the Key
        Vault resource (overriding the provider's storage default)."""
        self._mk_connector = mk_connector
        var provider = AzureImdsProvider.make()
        provider.resource = AZURE_KV_IMDS_RESOURCE
        self._provider = provider^

    @staticmethod
    def for_client_id(
        mk_connector: def () thin -> Self.C,
        client_id: String,
    ) -> ManagedIdentityTokenSource[Self.C]:
        """User-assigned managed identity — IMDS resolves the token for the given
        identity client_id, with the Key Vault resource pinned."""
        var src = ManagedIdentityTokenSource[Self.C](mk_connector)
        var provider = AzureImdsProvider.for_client_id(client_id)
        provider.resource = AZURE_KV_IMDS_RESOURCE
        src._provider = provider^
        return src^

    def access_token(mut self) raises -> String:
        """Mint (or re-use the cached) Key-Vault-scoped AAD token by driving the
        provider's `refresh_with_service` over a fresh connector +
        BlockingRuntime. A mint failure RAISES — the error NEVER carries the
        token body."""
        if self._provider.is_expired_or_near_expiry():
            # `HttpClient.call` dials the per-call connector it is HANDED, not the
            # client's own — so the client is built only for its config; the
            # dialing connector is a SECOND fresh one off the same `thin` factory.
            var client_connector = self._mk_connector()
            var http = HttpClient[Self.C].with_defaults(client_connector^)
            var dial_connector = self._mk_connector()
            var rt = BlockingRuntime[NoopSink].new(
                NoopSink(_placeholder=UInt8(0))
            )
            ref reactor = rt.reactor()
            self._provider.refresh_with_service[
                HttpClient[Self.C], BlockingRuntime[NoopSink], Self.C
            ](http, dial_connector, reactor)
        var bearer = self._provider.credential()
        return bearer.token.copy()
