# =============================================================================
# kci_gcp_secret_writer: the write seam over GCP Secret Manager.
# =============================================================================
#
# `GcpSecretManagerWriter` (a `kci_secret_writer.SecretWriter`) writes with
# AddSecretVersion (with the payload's CRC32C), creates with CreateSecret
# and probes with GetSecretVersion of `latest`, through the generated
# `komira_gcp_secretmanager.SecretManagerServiceClient` it is given, which
# carries the endpoint, the token source (the principal every write runs
# as) and the HTTP time budget; the package reads no environment and holds
# no credential.
#
# It is a package of its own so that the resolve seam,
# komira_gcp_secret_store, has no writer in its closure: this package
# depends on that one for the handle grammar and CRC32C, and nothing that
# resolves needs to depend on this one.
#
#   * `GcpSecretManagerWriter[C, T]`  the write seam (gcp_writer.mojo).
#
# DEPENDENCIES: kci_secret_writer (the trait), komira_gcp_secret_store (the
# handle grammar and CRC32C), komira_gcp_secretmanager (the client),
# komira_gcp_core (the token-source trait and the status codes),
# komira_async (the runtime the client's calls run on), komira_http_core
# (the connector trait), komira_proto_codec (the create body's JSON),
# komira_secret_store (the value), komira_crypto (the buffer wipe).
# =============================================================================

from .gcp_writer import GcpSecretManagerWriter
