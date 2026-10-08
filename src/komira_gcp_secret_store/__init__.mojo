# =============================================================================
# komira_gcp_secret_store: the secret seams over GCP Secret Manager.
# =============================================================================
#
# `GcpSecretManagerStore` (a `komira_secret_store.SecretStore`) resolves a
# handle with AccessSecretVersion and checks the payload's CRC32C;
# `GcpSecretManagerWriter` (a `kci_secret_writer.SecretWriter`) writes with
# AddSecretVersion (with the CRC32C), creates with CreateSecret and probes
# with ListSecretVersions. Both send through the generated
# `komira_gcp_secretmanager.SecretManagerServiceClient` they are given, which
# carries the endpoint, the token source and the HTTP time budget; the
# package reads no environment and holds no credential.
#
# The two are separate types, as the seams are: a holder of the store has no
# write verb, and the writer has no resolve.
#
#   * `GcpSecretManagerStore[C, T]`   the resolve seam (gcp_store.mojo).
#   * `GcpSecretManagerWriter[C, T]`  the write seam (gcp_writer.mojo).
#   * `GcpSecretRef`, `parse_gcp_secret_ref`, `GCP_VERSION_LATEST`
#                                     the handle grammar: a secret or version
#                                     resource name, global or regional
#                                     (gcp_secret_ref.mojo).
#   * `GCP_ENABLED_FILTER`            the filter `has_version` lists with.
#   * `crc32c`                        the payload checksum.
#
# DEPENDENCIES: komira_gcp_secretmanager (the client), komira_gcp_core (the
# token-source trait and the status codes), komira_async (the runtime the
# client's calls run on), komira_http_core (the connector trait),
# komira_proto_codec (the generated messages' JSON), komira_secret_store,
# kci_secret_writer, komira_crypto (the buffer wipe).
# =============================================================================

from .gcp_secret_ref import (
    GCP_VERSION_LATEST,
    GcpSecretRef,
    crc32c,
    parse_gcp_secret_ref,
)
from .gcp_store import GcpSecretManagerStore
from .gcp_writer import GCP_ENABLED_FILTER, GcpSecretManagerWriter
