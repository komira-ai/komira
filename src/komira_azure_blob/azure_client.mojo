# =============================================================================
# komira_azure_blob/azure_client.mojo — user-facing AzureClient[C: Connector]
# =============================================================================
#
# `AzureClient[C: Connector]` is the user-facing Movable
# value bundling the long-lived dataplane primitives needed to issue
# ranged GETs against the Azure Blob REST API:
#
#   * `HttpClient[C]` — TCP/TLS connection pool + reactor binding
#   * `SasQueryLayer[HttpClient[C]]` — a SAS token appended to each
#     request's query (none when the client has no token)
#   * `SharedKeySigningLayer[<that>, StaticSharedKeyProvider]` —
#     `Authorization: SharedKey <account>:<sig>` per-request injection
#     (none when the client has no key)
#   * `AzureStore[AzureClientHttp[C]]` — endpoint + GET glue
#   * a per-client `Connector` instance (separate from the one inside
#     HttpClient — `AzureStore.get_range[RT, C](..., mut connector,
#     mut reactor)` consumes a `mut C` at call-time)
#   * a per-client `Reactor[NoopSink]`
#
# Auth model (caller-resolves-credential): the SDK NEVER performs ambient
# credential discovery. The caller supplies the AzureSharedKey explicitly
# (account name + base64 account key — pasted from the Azure portal /
# `az storage account keys list`), OR a SAS token (the SasQueryLayer
# appends it to every request), OR neither for anonymous public-container
# reads (the SharedKeySigningLayer skips signing on an empty credential).
# A key and a token together are refused. `AzureClientSpec`
# (azure_client_spec.mojo) builds a client from an `AzureCredential`. Token-based auth (managed identity / service
# principal) is provided by the AzureImdsProvider / ServicePrincipalProvider
# in komira_azure_core; those fetch an OAuth2 token, and a bearer-token
# Azure layer is not written yet: Shared Key or SAS is the read path here.
#
# Sentinel/configured pattern: the no-arg
# `__init__()` yields an empty sentinel (`is_configured() == False`) whose
# heavy primitives are Optional.None; the configured ctor populates them.
#
# # THREAD-SAFETY:
# Per-worker shape: each worker constructs its OWN
# AzureClient + AzureFs on its OWN stack frame. The HttpClient pool inside
# is per-pthread single-thread-access by design. NO cross-worker sharing;
# NO Arc; concurrent dispatch is safe BECAUSE each worker has its own
# client.
#
# No UnsafePointer in any signature, no wildcard origin, no
# unsafe_from_address, no take_pointee, no ArcPointer.
# =============================================================================

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient
from komira_http_core.transport.io_stream import Connector

from .azure import AzureBlobMeta, AzureConfig, AzureStore
from .azure_sas_query import SasQueryLayer
from .azure_signing import SharedKeySigningLayer, StaticSharedKeyProvider


# The client's HTTP stack: Shared Key signing over the SAS query layer over
# the pooled HttpClient. With a key and no token the SAS layer passes
# requests through; with a token and no key the signing layer does.
comptime AzureClientHttp[C: Connector] = SharedKeySigningLayer[
    SasQueryLayer[HttpClient[C]], StaticSharedKeyProvider
]


# -----------------------------------------------------------------------------
# _make_reactor — module-private OS-conditional Reactor factory
# -----------------------------------------------------------------------------


def _make_reactor() raises -> Reactor[NoopSink]:
    """Build a Reactor[NoopSink] using the OS-appropriate backend
    (epoll on Linux; kqueue on macOS). Same shape as the S3/GCS client
    helper."""
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


# =============================================================================
# AzureClient[C: Connector] — caller-owned bundle of Azure dataplane primitives
# =============================================================================


struct AzureClient[C: Connector](Movable, Deinitable):
    """User-facing Azure Blob client. Construct ONCE PER WORKER; share
    across reads on that worker's stack frame via borrowed-Pointer
    `AzureFs[C, dispatch_o]` construction (caller-creates-fs pattern,
    mirrors S3Client / GcsClient).

    Layered HTTP stack (`AzureClientHttp[C]`):
      HttpClient[C]
        -> SasQueryLayer[HttpClient[C]]
        -> SharedKeySigningLayer[<that>, StaticSharedKeyProvider]
        -> AzureStore[AzureClientHttp[C]]

    Typical instantiation is `AzureClient[KernelTcpConnector]` for
    production TCP and `AzureClient[ScriptedConnector]` for unit-test
    fixtures.

    Auth: a caller-resolved AzureSharedKey, or a SAS token
    (`sas_query`). Pass an empty account+key and no token for anonymous
    public-container reads — the SharedKeySigningLayer skips signing on an
    empty credential.
    """

    var _inner_store: Optional[
        AzureStore[AzureClientHttp[Self.C]]
    ]
    var _inner_connector: Optional[Self.C]
    var _inner_reactor: Optional[Reactor[NoopSink]]
    var _account: String
    var _is_configured: Bool

    # ---- Default (sentinel) ctor ----

    def __init__(out self):
        """Default-construct an EMPTY sentinel AzureClient[C]. NEVER
        dereferenced; gated by `is_configured()`."""
        self._inner_store = Optional[
            AzureStore[AzureClientHttp[Self.C]]
        ]()
        self._inner_connector = Optional[Self.C]()
        self._inner_reactor = Optional[Reactor[NoopSink]]()
        self._account = String("")
        self._is_configured = False

    # ---- Configured ctor ----

    def __init__(
        out self,
        var account: String,
        var key_b64: String,
        var connector: Self.C,
        var call_connector: Self.C,
        var config: AzureConfig,
        sas_query: String = String(""),
    ) raises:
        """Construct a configured AzureClient[C].

        Args:
            account: Azure storage account name (e.g. "mystoraccount").
            key_b64: `base64`-encoded account key (caller-resolved; pass an
                empty String for anonymous public-container reads — the
                SharedKeySigningLayer then skips signing).
            connector: Connector moved into the embedded HttpClient[C]
                (consumed by `HttpClient.with_defaults`). Required because
                Mojo 1.0.0b1's `Connector` trait does NOT mandate a no-arg
                ctor.
            call_connector: Connector kept by AzureClient for per-call
                `AzureStore.get_range[RT, C](...)` dispatch.
            config: AzureConfig (use `AzureConfig.azure(account)` for real
                Azure or `AzureConfig.azurite(account)` for the emulator).
            sas_query: a SAS token appended to every request's query ("",
                the default, for none), checked by
                `azure_sas_query_normalize`.

        Raises `AzureClient: a shared key and a SAS token were both given;
        a request is authorized by one` when `key_b64` and `sas_query` are
        both non-empty.
        """
        if key_b64.byte_length() > 0 and sas_query.byte_length() > 0:
            raise Error(
                "AzureClient: a shared key and a SAS token were both given;"
                " a request is authorized by one"
            )
        var http = HttpClient[Self.C].with_defaults(connector^)
        var sas = SasQueryLayer[HttpClient[Self.C]].wrap(http^, sas_query)
        # No key: the provider's credential is empty, so the signing layer
        # passes requests through unsigned (a SAS token, or anonymous).
        var signer_account = account if key_b64.byte_length() > 0 else String("")
        var provider = StaticSharedKeyProvider.make(signer_account, key_b64)
        var layer = AzureClientHttp[Self.C].wrap(sas^, provider^)
        var account_name = String(config.account)
        var store = AzureStore[AzureClientHttp[Self.C]].new(config^, layer^)

        var call_reactor = _make_reactor()

        self._inner_store = Optional[
            AzureStore[AzureClientHttp[Self.C]]
        ](store^)
        self._inner_connector = Optional[Self.C](call_connector^)
        self._inner_reactor = Optional[Reactor[NoopSink]](call_reactor^)
        self._account = account_name^
        self._is_configured = True
        _ = account^
        _ = key_b64^

    # ---- Read-only public accessors ----

    @always_inline
    def is_configured(self) -> Bool:
        """True for the configured form; False for the sentinel."""
        return self._is_configured

    @always_inline
    def account(self) -> String:
        """The configured Azure storage account name. Empty on the
        sentinel form."""
        return self._account

    # ---- Internal mut-borrows used by AzureFs.read_at ----

    def _store_mut(
        mut self,
    ) -> ref [self._inner_store] Optional[
        AzureStore[AzureClientHttp[Self.C]]
    ]:
        """INTERNAL: ref to the Optional holding the AzureStore. Caller
        (AzureFs.read_at) accesses `.value()` after confirming the client
        is configured.

        # THREAD-SAFETY: per-worker — each worker borrows its OWN
        AzureClient through its OWN AzureFs (borrowed-Pointer with the
        worker's stack-frame origin). No cross-worker sharing."""
        return self._inner_store

    def _connector_mut(
        mut self,
    ) -> ref [self._inner_connector] Optional[Self.C]:
        """INTERNAL: ref to the per-call Connector Optional."""
        return self._inner_connector

    def _reactor_mut(
        mut self,
    ) -> ref [self._inner_reactor] Optional[Reactor[NoopSink]]:
        """INTERNAL: ref to the per-call Reactor Optional."""
        return self._inner_reactor

    # ---- High-level convenience verbs ----

    @always_inline
    def _require_configured(self, method: String) raises:
        if not self._is_configured:
            raise Error(
                String("AzureClient.") + method
                + String(
                    ": not configured (sentinel form). Construct with"
                    " AzureClient[C](account=..., key_b64=...,"
                    " connector=..., call_connector=..., config=...)"
                    " before invoking high-level methods."
                )
            )

    def head_blob(
        mut self,
        container: String,
        blob: String,
    ) raises -> AzureBlobMeta:
        """HEAD an Azure blob, returning size + ETag."""
        self._require_configured(String("head_blob"))
        ref store_opt = self._inner_store
        ref connector_opt = self._inner_connector
        ref reactor_opt = self._inner_reactor
        return store_opt.value().head[PerCoreAsyncRuntime[NoopSink], Self.C](
            container, blob, connector_opt.value(), reactor_opt.value(),
        )

    def get_blob_range(
        mut self,
        container: String,
        blob: String,
        start: Int64,
        end_inclusive: Int64,
    ) raises -> List[UInt8]:
        """GET a byte-range from an Azure blob."""
        self._require_configured(String("get_blob_range"))
        ref store_opt = self._inner_store
        ref connector_opt = self._inner_connector
        ref reactor_opt = self._inner_reactor
        return store_opt.value().get_range[
            PerCoreAsyncRuntime[NoopSink], Self.C
        ](
            container, blob, start, end_inclusive,
            connector_opt.value(), reactor_opt.value(),
        )
