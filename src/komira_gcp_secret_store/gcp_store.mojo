# =============================================================================
# komira_gcp_secret_store/gcp_store.mojo: `GcpSecretManagerStore`, a
#   `SecretStore` over the generated Secret Manager client.
# =============================================================================
#
# `resolve(secret_ref)` parses the handle (gcp_secret_ref.mojo) and sends one
# AccessSecretVersion for the version it names, `latest` when it names the
# secret. The payload's bytes become the `SecretValue`. When the answer
# carries a `dataCrc32c` (the service sends one for every version written
# with one), the bytes' CRC32C must equal it, or the resolve raises: a value
# damaged on the way is never handed to a connector. An answer with no
# payload raises.
#
# Every failure raises: a handle outside the grammar (not quoted), an error
# answer (NOT_FOUND for a missing secret or version, PERMISSION_DENIED,
# UNAUTHENTICATED, ...), a transport failure, a value over
# `MAX_SECRET_LEN`, a checksum mismatch. The text names the handle and
# carries the generated client's error (komira_gcp_core's
# `gcp_status_error`: the verb, the method, the status and its code, never
# the body); no text holds the value.
#
# The store owns a `BlockingRuntime` for the client's calls, so a resolve
# blocks its thread until the answer, or the client's own deadline (the
# `HttpClientConfig` the caller built it with).
#
# Custody: the adapter wipes the payload buffer it reads the value from
# (`zeroize_list`) once the `SecretValue` holds it. The client's response
# text and transport buffers are not wiped.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_crypto import zeroize_list
from komira_gcp_core import GcpTokenSource
from komira_gcp_secretmanager.service import (
    AccessSecretVersionRequest,
    AccessSecretVersionResponse,
    SecretManagerServiceClient,
)
from komira_http_core.transport.io_stream import Connector
from komira_secret_store import SecretStore, SecretValue

from .gcp_secret_ref import GcpSecretRef, crc32c, parse_gcp_secret_ref

comptime _STORE = "GcpSecretManagerStore: "


struct GcpSecretManagerStore[C: Connector, T: GcpTokenSource](
    SecretStore, Movable, Deinitable
):
    """A `SecretStore` whose handle is a Secret Manager secret or version
    name (module header). It owns the generated client it sends through; the
    client carries the endpoint, the token source and the HTTP time
    budget."""

    var _client: SecretManagerServiceClient[Self.C, Self.T]
    var _rt: BlockingRuntime[NoopSink]

    def __init__(
        out self, var client: SecretManagerServiceClient[Self.C, Self.T]
    ) raises:
        self._client = client^
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """The value of the version `secret_ref` names (`latest` for a
        secret). Raises as the module header says."""
        var parsed: GcpSecretRef
        try:
            parsed = parse_gcp_secret_ref(secret_ref)
        except e:
            raise Error(String(_STORE) + String(e))
        var got: AccessSecretVersionResponse
        try:
            ref reactor = self._rt.reactor()
            got = self._client.access_secret_version[BlockingRuntime[NoopSink]](
                AccessSecretVersionRequest(parsed.version_name()), reactor
            )
        except e:
            raise Error(
                String(_STORE)
                + "resolve of secret_ref "
                + secret_ref
                + " failed: "
                + String(e)
            )
        if not got.payload:
            raise Error(
                String(_STORE)
                + "resolve of secret_ref "
                + secret_ref
                + " failed: the answer has no payload"
            )
        ref payload = got.payload.value()
        if payload.data_crc32c:
            var want = payload.data_crc32c.value()
            if Int64(Int(crc32c(Span(payload.data)))) != want:
                zeroize_list(payload.data)
                raise Error(
                    String(_STORE)
                    + "resolve of secret_ref "
                    + secret_ref
                    + " failed: the payload's CRC32C is not the dataCrc32c the"
                    " answer carries"
                )
        try:
            var value = SecretValue(Span(payload.data))
            zeroize_list(payload.data)
            return value^
        except e:
            zeroize_list(payload.data)
            raise Error(
                String(_STORE)
                + "resolve of secret_ref "
                + secret_ref
                + " failed: "
                + String(e)
            )
