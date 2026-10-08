# =============================================================================
# komira_gcp_secret_store/gcp_writer.mojo: `GcpSecretManagerWriter`, a
#   `SecretWriter` over the generated Secret Manager client.
# =============================================================================
#
# The three verbs, each on a handle that names a secret (a handle naming a
# version is refused, gcp_secret_ref.mojo):
#
#   write             AddSecretVersion with the value as the payload and its
#                     CRC32C as `dataCrc32c` (the service refuses a payload
#                     that does not match it): a new version, which `latest`
#                     then names. When the secret does not exist (NOT_FOUND),
#                     CreateSecret (automatic replication for a global
#                     secret; none for a regional one, which takes none) and
#                     AddSecretVersion again; when that create finds the id
#                     taken (ALREADY_EXISTS: another writer created it in
#                     between), AddSecretVersion again. Any other error
#                     raises. Secret Manager has no request id: a retried
#                     AddSecretVersion would add a second version, so the
#                     writer sends each one once.
#   define_container  CreateSecret: a secret with no version. ALREADY_EXISTS
#                     is the no-op.
#   has_version       ListSecretVersions, filtered to `state:ENABLED`, one
#                     per page: metadata only (a SecretVersion has no
#                     payload), so the probe needs `versions.list` and never
#                     `versions.access`. True when an enabled version exists,
#                     False when none does or the secret does not exist
#                     (NOT_FOUND).
#
# Every other failure raises, naming the verb and the handle, with the
# generated client's error (the verb, the method, the status and its code,
# never a body); no text holds the value.
#
# THE DEPLOY TOKEN. Each request's bearer token comes from the client's
# token source. A non-empty `deploy_token` is refused before anything is
# sent, rather than ignored, so a write never runs as a principal other
# than the one the caller meant; a caller holding the deploy principal's
# token builds the client over a token source that gives it
# (komira_gcp_core's `StaticTokenSource`) and passes an empty token.
#
# Custody: the payload bytes are copied out of the `SecretValue` into the
# request, which the client encodes as base64 JSON; the adapter wipes the
# request's payload buffer after the send. The client's encoded body and
# transport buffers are not wiped.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_crypto import zeroize_list
from komira_gcp_core import (
    CODE_ALREADY_EXISTS,
    CODE_NOT_FOUND,
    GcpTokenSource,
    gcp_status_error_code,
)
from komira_gcp_secretmanager.resources import Secret, SecretPayload
from komira_gcp_secretmanager.service import (
    AddSecretVersionRequest,
    CreateSecretRequest,
    ListSecretVersionsRequest,
    ListSecretVersionsResponse,
    SecretManagerServiceClient,
)
from komira_http_core.transport.io_stream import Connector
from komira_proto_codec.codec import decode_json
from kci_secret_writer import SecretWriter
from komira_secret_store import SecretValue

from .gcp_secret_ref import GcpSecretRef, crc32c, parse_gcp_secret_ref

comptime _WRITER = "GcpSecretManagerWriter: "
comptime _RT = BlockingRuntime[NoopSink]
# The filter has_version lists with (the Secret Manager list filter syntax).
comptime GCP_ENABLED_FILTER = "state:ENABLED"


def _failed(verb: String, secret_ref: String, cause: String) -> Error:
    return Error(
        String(_WRITER) + verb + " of secret_ref " + secret_ref + " failed: " + cause
    )


struct GcpSecretManagerWriter[C: Connector, T: GcpTokenSource](
    SecretWriter, Movable, Deinitable
):
    """A `SecretWriter` into Secret Manager (module header). It owns the
    generated client it sends through; the client carries the endpoint, the
    token source (the principal every write runs as) and the HTTP time
    budget."""

    var _client: SecretManagerServiceClient[Self.C, Self.T]
    var _rt: BlockingRuntime[NoopSink]

    def __init__(
        out self, var client: SecretManagerServiceClient[Self.C, Self.T]
    ) raises:
        self._client = client^
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def _secret(
        self, verb: String, secret_ref: String, deploy_token: String
    ) raises -> GcpSecretRef:
        """The parsed handle of a secret; raises, before anything is sent,
        for a deploy token, a handle outside the grammar and one naming a
        version."""
        if deploy_token.byte_length() > 0:
            raise Error(
                String(_WRITER)
                + verb
                + " refused: a deploy token was given, and each request's"
                " bearer token comes from the client's token source; build the"
                " client over the deploy principal's token source and pass an"
                " empty token"
            )
        try:
            var parsed = parse_gcp_secret_ref(secret_ref)
            if parsed.names_version():
                raise Error(
                    "the handle names a version, and a writer's handle names"
                    " the secret only"
                )
            return parsed^
        except e:
            raise Error(String(_WRITER) + verb + " refused: " + String(e))

    def _create(mut self, secret: GcpSecretRef) raises:
        # A global secret needs a replication policy; a regional one takes
        # none. The body holds no value, so it is spelled as JSON.
        var body = String("{}") if secret.is_regional() else String(
            '{"replication":{"automatic":{}}}'
        )
        var req = CreateSecretRequest(
            secret.parent(),
            secret.secret_id.copy(),
            Optional[Secret](decode_json[Secret](body)),
        )
        ref reactor = self._rt.reactor()
        _ = self._client.create_secret[_RT](req, reactor)

    def _add(mut self, secret: GcpSecretRef, data: Span[UInt8, _]) raises:
        var bytes = List[UInt8]()
        bytes.extend(data)
        var crc = Int64(Int(crc32c(data)))
        var req = AddSecretVersionRequest(
            secret.secret_name(),
            Optional[SecretPayload](SecretPayload(bytes^, Optional[Int64](crc))),
        )
        try:
            ref reactor = self._rt.reactor()
            _ = self._client.add_secret_version[_RT](req, reactor)
        finally:
            zeroize_list(req.payload.value().data)

    def write(
        mut self,
        secret_ref: String,
        var value: SecretValue,
        deploy_token: String,
    ) raises:
        """Add `value` as the newest version of the secret `secret_ref`
        names, creating the secret when it does not exist (module header)."""
        var secret = self._secret(String("write"), secret_ref, deploy_token)
        try:
            self._add(secret, value.revealed_bytes())
            return
        except e:
            var cause = String(e)
            if (
                gcp_status_error_code(String("POST"), String("AddSecretVersion"), cause)
                != CODE_NOT_FOUND
            ):
                raise _failed(String("write"), secret_ref, cause)
        try:
            self._create(secret)
        except e:
            var cause = String(e)
            if (
                gcp_status_error_code(String("POST"), String("CreateSecret"), cause)
                != CODE_ALREADY_EXISTS
            ):
                raise _failed(String("write"), secret_ref, cause)
        try:
            self._add(secret, value.revealed_bytes())
        except e:
            raise _failed(String("write"), secret_ref, String(e))

    def define_container(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises:
        """Create the secret `secret_ref` names with no version; an existing
        one is the no-op (module header)."""
        var secret = self._secret(String("define_container"), secret_ref, deploy_token)
        try:
            self._create(secret)
        except e:
            var cause = String(e)
            if (
                gcp_status_error_code(String("POST"), String("CreateSecret"), cause)
                != CODE_ALREADY_EXISTS
            ):
                raise _failed(String("define_container"), secret_ref, cause)

    def has_version(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises -> Bool:
        """Whether the secret `secret_ref` names has an enabled version, read
        from ListSecretVersions (module header)."""
        var secret = self._secret(String("has_version"), secret_ref, deploy_token)
        var listed: ListSecretVersionsResponse
        try:
            ref reactor = self._rt.reactor()
            listed = self._client.list_secret_versions[_RT](
                ListSecretVersionsRequest(
                    secret.secret_name(),
                    Int32(1),
                    String(""),
                    String(GCP_ENABLED_FILTER),
                ),
                reactor,
            )
        except e:
            var cause = String(e)
            if (
                gcp_status_error_code(String("GET"), String("ListSecretVersions"), cause)
                == CODE_NOT_FOUND
            ):
                return False
            raise _failed(String("has_version"), secret_ref, cause)
        return len(listed.versions) > 0
