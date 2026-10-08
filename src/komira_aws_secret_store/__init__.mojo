# =============================================================================
# komira_aws_secret_store: the resolve seam over AWS Secrets Manager.
# =============================================================================
#
# `AwsSecretsManagerStore` (a `komira_secret_store.SecretStore`) resolves a
# handle with GetSecretValue, through the generated
# `komira_aws_secretsmanager.SecretsManagerClient` it is given, which carries
# the endpoint, the region, the credential source and the HTTP time budget;
# the package reads no environment and holds no credential.
#
# It holds no write verb, and nothing it depends on does: the writer,
# `AwsSecretsManagerWriter`, is kci_aws_secret_writer's, which depends on
# this package for the handle grammar. A target that resolves secrets and
# depends on this package has no writer in its closure.
#
#   * `AwsSecretsManagerStore[C, T]`   the resolve seam (aws_store.mojo).
#   * `AwsSecretRef`, `parse_aws_secret_ref`
#                                      the handle grammar: `<SecretId>` (a
#                                      name or a full ARN), or
#                                      `<SecretId>?versionStage=<label>` /
#                                      `?versionId=<id>` for a resolve
#                                      (aws_secret_ref.mojo).
#   * `AWS_STAGE_CURRENT`, `AWS_SELECTOR_VERSION_ID`,
#     `AWS_SELECTOR_VERSION_STAGE`     the grammar's words.
#
# DEPENDENCIES: komira_aws_secretsmanager (the client), komira_aws_core (the
# credential-source trait), komira_http_core (the connector trait),
# komira_secret_store, komira_crypto (the buffer wipe).
# =============================================================================

from .aws_secret_ref import (
    AWS_SELECTOR_VERSION_ID,
    AWS_SELECTOR_VERSION_STAGE,
    AWS_STAGE_CURRENT,
    AwsSecretRef,
    parse_aws_secret_ref,
)
from .aws_store import AwsSecretsManagerStore
