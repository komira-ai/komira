# =============================================================================
# komira_aws_secret_store: the secret seams over AWS Secrets Manager.
# =============================================================================
#
# `AwsSecretsManagerStore` (a `komira_secret_store.SecretStore`) resolves a
# handle with GetSecretValue; `AwsSecretsManagerWriter` (a
# `kci_secret_writer.SecretWriter`) writes with PutSecretValue, creates with
# CreateSecret and probes with DescribeSecret. Both send through the
# generated `komira_aws_secretsmanager.SecretsManagerClient` they are given,
# which carries the endpoint, the region, the credential source and the HTTP
# time budget; the package reads no environment and holds no credential.
#
# The two are separate types, as the seams are: a holder of the store has no
# write verb, and the writer has no resolve.
#
#   * `AwsSecretsManagerStore[C, T]`   the resolve seam (aws_store.mojo).
#   * `AwsSecretsManagerWriter[C, T]`  the write seam (aws_writer.mojo).
#   * `AwsSecretRef`, `parse_aws_secret_ref`
#                                      the handle grammar: `<SecretId>`, or
#                                      `<SecretId>?versionStage=<label>` /
#                                      `?versionId=<id>` for a resolve
#                                      (aws_secret_ref.mojo).
#   * `AWS_STAGE_CURRENT`, `AWS_SELECTOR_VERSION_ID`,
#     `AWS_SELECTOR_VERSION_STAGE`     the grammar's words.
#
# DEPENDENCIES: komira_aws_secretsmanager (the client), komira_aws_core (the
# credential-source trait), komira_http_core (the connector trait),
# komira_secret_store, kci_secret_writer, komira_crypto (the buffer wipe).
# =============================================================================

from .aws_secret_ref import (
    AWS_SELECTOR_VERSION_ID,
    AWS_SELECTOR_VERSION_STAGE,
    AWS_STAGE_CURRENT,
    AwsSecretRef,
    parse_aws_secret_ref,
)
from .aws_store import AwsSecretsManagerStore
from .aws_writer import AwsSecretsManagerWriter
