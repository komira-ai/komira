# =============================================================================
# komira_gcp_secret_store: the resolve seam over GCP Secret Manager.
# =============================================================================
#
# `GcpSecretManagerStore` (a `komira_secret_store.SecretStore`) resolves a
# handle with AccessSecretVersion and checks the payload's CRC32C, through
# the generated `komira_gcp_secretmanager.SecretManagerServiceClient` it is
# given, which carries the endpoint, the token source and the HTTP time
# budget; the package reads no environment and holds no credential.
#
# It holds no write verb, and nothing it depends on does: the writer,
# `GcpSecretManagerWriter`, is kci_gcp_secret_writer's, which depends on
# this package for the handle grammar and CRC32C. A target that resolves
# secrets and depends on this package has no writer in its closure.
#
#   * `GcpSecretManagerStore[C, T]`   the resolve seam (gcp_store.mojo).
#   * `GcpSecretRef`, `parse_gcp_secret_ref`, `GCP_VERSION_LATEST`
#                                     the handle grammar: a secret or version
#                                     resource name, global or regional
#                                     (gcp_secret_ref.mojo).
#   * `crc32c`                        the payload checksum.
#
# DEPENDENCIES: komira_gcp_secretmanager (the client), komira_gcp_core (the
# token-source trait), komira_async (the runtime the client's calls run
# on), komira_http_core (the connector trait), komira_secret_store,
# komira_crypto (the buffer wipe).
# =============================================================================

from .gcp_secret_ref import (
    GCP_VERSION_LATEST,
    GcpSecretRef,
    crc32c,
    parse_gcp_secret_ref,
)
from .gcp_store import GcpSecretManagerStore
