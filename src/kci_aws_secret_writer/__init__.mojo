# =============================================================================
# kci_aws_secret_writer: the write seam over AWS Secrets Manager.
# =============================================================================
#
# `AwsSecretsManagerWriter` (a `kci_secret_writer.SecretWriter`) writes with
# PutSecretValue, creates with CreateSecret and probes with DescribeSecret,
# through the generated `komira_aws_secretsmanager.SecretsManagerClient` it
# is given, which carries the endpoint, the region, the credential source
# (the principal every write runs as) and the HTTP time budget; the package
# reads no environment and holds no credential.
#
# It is a package of its own so that the resolve seam,
# komira_aws_secret_store, has no writer in its closure: this package
# depends on that one for the handle grammar, and nothing that resolves
# needs to depend on this one.
#
#   * `AwsSecretsManagerWriter[C, T]`  the write seam (aws_writer.mojo).
#
# DEPENDENCIES: kci_secret_writer (the trait), komira_aws_secret_store (the
# handle grammar), komira_aws_secretsmanager (the client), komira_aws_core
# (the credential-source trait and the client's error codes),
# komira_http_core (the connector trait), komira_secret_store (the value).
# =============================================================================

from .aws_writer import AwsSecretsManagerWriter
