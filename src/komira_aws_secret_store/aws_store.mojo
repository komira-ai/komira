# =============================================================================
# komira_aws_secret_store/aws_store.mojo: `AwsSecretsManagerStore`, a
#   `SecretStore` over the generated Secrets Manager client.
# =============================================================================
#
# `resolve(secret_ref)` parses the handle (aws_secret_ref.mojo) and sends one
# GetSecretValue for its SecretId, with its VersionId or VersionStage when
# the handle pins one (none: the service answers the AWSCURRENT version). The
# answer's SecretString bytes, or its SecretBinary bytes when it has no
# SecretString, become the `SecretValue`; an answer with neither raises.
#
# Every failure raises: a handle outside the grammar (not quoted), a request
# the client refuses, an error answer (`ResourceNotFoundException` for a
# missing secret or version, `InvalidRequestException` for one scheduled for
# deletion, `AccessDeniedException`, ...), a transport failure, a value over
# `MAX_SECRET_LEN`. The text names the handle and carries the generated
# client's error, which holds the status, the code and the service's message
# and never the response body; no text holds the value.
#
# Custody. The generated response holds the value as a `String` (or a
# `List[UInt8]`) the adapter cannot reach before it is parsed; the adapter
# copies it into the zeroizing `SecretValue`, wipes a SecretBinary buffer it
# owns, and lets the response drop. The response's `String` is not wiped
# (`String` has no secure wipe), and neither are the client's transport
# buffers.
# =============================================================================

from komira_aws_core import AwsCredsSource
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerClient,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerGetSecretValueResponse,
)
from komira_crypto import zeroize_list
from komira_http_core.transport.io_stream import Connector
from komira_secret_store import SecretStore, SecretValue

from .aws_secret_ref import AwsSecretRef, parse_aws_secret_ref


struct AwsSecretsManagerStore[C: Connector, T: AwsCredsSource](
    SecretStore, Movable, Deinitable
):
    """A `SecretStore` whose handle names a Secrets Manager secret, and
    optionally a version of it (module header). It owns the generated client
    it sends through; the client carries the endpoint, the region, the
    credential source and the HTTP time budget."""

    var _client: SecretsManagerClient[Self.C, Self.T]

    def __init__(out self, var client: SecretsManagerClient[Self.C, Self.T]):
        self._client = client^

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """The value of the version `secret_ref` names. Raises as the module
        header says."""
        var parsed: AwsSecretRef
        try:
            parsed = parse_aws_secret_ref(secret_ref)
        except e:
            raise Error(String("AwsSecretsManagerStore: ") + String(e))
        var req = SecretsManagerGetSecretValueRequest(parsed.secret_id.copy())
        req.version_id = parsed.version_id.copy()
        req.version_stage = parsed.version_stage.copy()
        var got: SecretsManagerGetSecretValueResponse
        try:
            got = self._client.get_secret_value(req)
        except e:
            raise Error(
                String("AwsSecretsManagerStore: resolve of secret_ref ")
                + secret_ref
                + " failed: "
                + String(e)
            )
        try:
            if got.secret_string:
                return SecretValue(got.secret_string.value().as_bytes())
            if got.secret_binary:
                var value = SecretValue(Span(got.secret_binary.value()))
                zeroize_list(got.secret_binary.value())
                return value^
        except e:
            if got.secret_binary:
                zeroize_list(got.secret_binary.value())
            raise Error(
                String("AwsSecretsManagerStore: resolve of secret_ref ")
                + secret_ref
                + " failed: "
                + String(e)
            )
        raise Error(
            String("AwsSecretsManagerStore: resolve of secret_ref ")
            + secret_ref
            + " failed: the answer holds neither a SecretString nor a"
            " SecretBinary"
        )
