# =============================================================================
# komira_aws_secret_store/aws_writer.mojo: `AwsSecretsManagerWriter`, a
#   `SecretWriter` over the generated Secrets Manager client.
# =============================================================================
#
# The three verbs, each on a bare handle (a SecretId: a name or an ARN; a
# handle with a selector is refused, aws_secret_ref.mojo):
#
#   write             PutSecretValue with the value as SecretString: a new
#                     version, labelled AWSCURRENT, the one before it
#                     AWSPREVIOUS. When the secret does not exist
#                     (ResourceNotFoundException) and the handle is a name,
#                     CreateSecret with the value as its first version; when
#                     that create finds the name taken
#                     (ResourceExistsException: another writer created it in
#                     between), PutSecretValue again. Any other error raises,
#                     and so does a missing secret named by ARN (a create
#                     takes a name). The value must be UTF-8: SecretString is
#                     text, and this writer writes text only.
#   define_container  CreateSecret with no value: a secret with no version.
#                     A name already taken by a live secret
#                     (ResourceExistsException) is the no-op. A handle that is
#                     an ARN is refused (a create takes a name).
#   has_version       DescribeSecret, which answers metadata and never a
#                     value: True when a version holds AWSCURRENT (the one a
#                     bare handle resolves to), False when none does or the
#                     secret does not exist (ResourceNotFoundException). A
#                     secret scheduled for deletion raises: it can be neither
#                     read nor written until it is restored.
#
# Every other failure raises, naming the verb and the handle, with the
# generated client's error (status, code and the service's message, never a
# response body); no text holds the value. The generated client fills each
# write's ClientRequestToken and reuses it on its retries, so a retried write
# makes one version.
#
# THE DEPLOY TOKEN. Secrets Manager signs every request with the client's
# credential source (SigV4); there is no bearer token to send. A non-empty
# `deploy_token` is refused before anything is sent, rather than ignored: a
# caller that expects the write to run as the principal the token names
# would otherwise write as the client's. Build the writer's client over the
# deploy principal's credentials and pass an empty token.
#
# Custody: the value is copied out of the `SecretValue` into the request's
# SecretString (`String`, which has no secure wipe) and the client's request
# body; the `SecretValue` itself is wiped when `write` returns.
# =============================================================================

from komira_aws_core import AwsCredsSource
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerClient,
    SecretsManagerCreateSecretRequest,
    SecretsManagerDescribeSecretRequest,
    SecretsManagerDescribeSecretResponse,
    SecretsManagerPutSecretValueRequest,
)
from komira_http_core.transport.io_stream import Connector
from kci_secret_writer import SecretWriter
from komira_secret_store import SecretValue

from .aws_secret_ref import AWS_STAGE_CURRENT, _error_code, parse_aws_secret_ref

comptime _WRITER = "AwsSecretsManagerWriter: "


def _failed(verb: String, secret_ref: String, cause: String) -> Error:
    return Error(
        String(_WRITER) + verb + " of secret_ref " + secret_ref + " failed: " + cause
    )


struct AwsSecretsManagerWriter[C: Connector, T: AwsCredsSource](
    SecretWriter, Movable, Deinitable
):
    """A `SecretWriter` into Secrets Manager (module header). It owns the
    generated client it sends through; the client carries the endpoint, the
    region, the credential source (the principal every write runs as) and
    the HTTP time budget."""

    var _client: SecretsManagerClient[Self.C, Self.T]

    def __init__(out self, var client: SecretsManagerClient[Self.C, Self.T]):
        self._client = client^

    def _secret_id(
        self, verb: String, secret_ref: String, deploy_token: String
    ) raises -> String:
        """The SecretId of a bare handle; raises, before anything is sent,
        for a deploy token, a handle outside the grammar and one with a
        selector."""
        if deploy_token.byte_length() > 0:
            raise Error(
                String(_WRITER)
                + verb
                + " refused: a deploy token was given, and Secrets Manager"
                " signs each request with the client's credential source; build"
                " the client over the deploy principal's credentials and pass an"
                " empty token"
            )
        try:
            var parsed = parse_aws_secret_ref(secret_ref)
            if not parsed.is_plain():
                raise Error(
                    "the handle pins a version, and a writer's handle names"
                    " the secret only"
                )
            return parsed.secret_id.copy()
        except e:
            raise Error(String(_WRITER) + verb + " refused: " + String(e))

    def _put(mut self, secret_id: String, text: String) raises:
        var put = SecretsManagerPutSecretValueRequest(secret_id.copy())
        put.secret_string = Optional[String](text.copy())
        _ = self._client.put_secret_value(put)

    def write(
        mut self,
        secret_ref: String,
        var value: SecretValue,
        deploy_token: String,
    ) raises:
        """Make `value` the AWSCURRENT version of the secret `secret_ref`
        names, creating the secret when it does not exist (module header)."""
        var secret_id = self._secret_id(String("write"), secret_ref, deploy_token)
        var text: String
        try:
            text = String(StringSlice(from_utf8=value.revealed_bytes()))
        except:
            raise Error(
                String(_WRITER)
                + "write of secret_ref "
                + secret_ref
                + " refused: the value is not UTF-8, and this writer writes"
                " SecretString text only"
            )
        try:
            self._put(secret_id, text)
            return
        except e:
            var cause = String(e)
            if (
                _error_code(String("PutSecretValue"), cause)
                != "ResourceNotFoundException"
                or secret_id.startswith("arn:")
            ):
                raise _failed(String("write"), secret_ref, cause)
        try:
            var create = SecretsManagerCreateSecretRequest(secret_id.copy())
            create.secret_string = Optional[String](text.copy())
            _ = self._client.create_secret(create)
            return
        except e:
            var cause = String(e)
            if _error_code(String("CreateSecret"), cause) != "ResourceExistsException":
                raise _failed(String("write"), secret_ref, cause)
        try:
            self._put(secret_id, text)
        except e:
            raise _failed(String("write"), secret_ref, String(e))

    def define_container(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises:
        """Create the secret `secret_ref` names with no version; a live
        secret of that name is the no-op (module header)."""
        var secret_id = self._secret_id(
            String("define_container"), secret_ref, deploy_token
        )
        if secret_id.startswith("arn:"):
            raise Error(
                String(_WRITER)
                + "define_container refused: the handle is an ARN, and a"
                " secret is created by name"
            )
        try:
            _ = self._client.create_secret(
                SecretsManagerCreateSecretRequest(secret_id^)
            )
        except e:
            var cause = String(e)
            if _error_code(String("CreateSecret"), cause) != "ResourceExistsException":
                raise _failed(String("define_container"), secret_ref, cause)

    def has_version(
        mut self,
        secret_ref: String,
        deploy_token: String,
    ) raises -> Bool:
        """Whether a version of the secret `secret_ref` names holds
        AWSCURRENT, read from DescribeSecret (module header)."""
        var secret_id = self._secret_id(
            String("has_version"), secret_ref, deploy_token
        )
        var described: SecretsManagerDescribeSecretResponse
        try:
            described = self._client.describe_secret(
                SecretsManagerDescribeSecretRequest(secret_id^)
            )
        except e:
            var cause = String(e)
            if _error_code(String("DescribeSecret"), cause) == "ResourceNotFoundException":
                return False
            raise _failed(String("has_version"), secret_ref, cause)
        if described.deleted_date:
            raise _failed(
                String("has_version"),
                secret_ref,
                String(
                    "the secret is scheduled for deletion: restore it"
                    " (RestoreSecret) or wait for the deletion before writing"
                ),
            )
        if not described.version_ids_to_stages:
            return False
        for ref entry in described.version_ids_to_stages.value().items():
            for i in range(len(entry.value)):
                if entry.value[i] == AWS_STAGE_CURRENT:
                    return True
        return False
