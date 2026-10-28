# =============================================================================
# komira_secrets -- the names-only secret catalog and the write side of the
#   secret-store seam.
# =============================================================================
#
# Komira holds HANDLES, never secret VALUES. A customer's own secret store holds
# the values; `SecretStore` (komira_secret_store) resolves a handle to a value at
# point of use. This package adds:
#
#   * `SecretManager`          -- the names-only catalog row (every column is a
#                                 name; there is no value, key, token or
#                                 ciphertext column).
#   * `SecretManagerStore[DB]` -- register / get / list_for_org / set_status /
#                                 update_secret_ref over the backend-neutral
#                                 `komira_db.Database`.
#   * `secret_migrations`      -- the SQL schema chain for the catalog.
#   * `SecretWriteStore`       -- the WRITE adapter trait (value in, opaque
#                                 handle out), with `InMemorySecretWriteStore`.
#   * `SharedMemorySecretStore` -- an in-memory store that is both a
#                                 `SecretStore` and a `SecretWriteStore`.
#
# `SecretStore`, `StaticSecretStore`, `SecretValue`, `SecretMeta` and
# `MAX_SECRET_LEN` live in komira_secret_store; import them from there.
# =============================================================================

from .secret_manager import (
    PROVIDER_AWS_SECRETS_MANAGER,
    PROVIDER_AZURE_KEY_VAULT,
    PROVIDER_CONJUR,
    PROVIDER_GCP_SECRET_MANAGER,
    PROVIDER_KIND_COUNT,
    PROVIDER_LOCAL_KEYCHAIN,
    PROVIDER_VAULT_KV,
    REACHABILITY_CENTRAL_REACHABLE,
    REACHABILITY_CUSTOMER_BOUNDARY_ONLY,
    SECRET_STATUS_FAILED,
    SECRET_STATUS_PENDING,
    SECRET_STATUS_READY,
    SECRET_STATUS_UNSPECIFIED,
    SecretManager,
    provider_kind_str,
    secret_status_str,
)
from .secret_manager_store import SecretManagerStore
from .secret_write_store import (
    InMemorySecretWriteStore,
    SecretWriteStore,
)
from .shared_memory_secret_store import SharedMemorySecretStore
from .secret_migration import (
    SECRET_SCHEMA_V1,
    SECRET_SCHEMA_V2,
    secret_migrations,
)
