# =============================================================================
# komira_secrets_keychain: a `SecretStore` over the operating system's keychain,
#   for local runs.
# =============================================================================
#
#   * `KeychainSecretStore[B]`  the store: `resolve("service[/account]")` fetches
#                               the entry through the backend `B` and returns a
#                               zeroizing `SecretValue`.
#   * `KeychainBackend`         the fetch seam; `KeychainLookup` is its
#                               three-outcome result (found, miss, error).
#   * `MacosSecurityKeychainBackend`  macOS: runs `/usr/bin/security
#                               find-generic-password ... -w` through
#                               komira_supervisor. On any other platform its
#                               `fetch` answers an error and starts no process.
#   * `StaticKeychainBackend`   the hermetic, recording test double.
#   * `parse_keychain_ref`, `build_security_argv`  pure helpers.
#
# DEPENDENCIES: komira_secret_store, komira_supervisor (and its komira_async),
# komira_crypto.
# =============================================================================

from komira_secrets_keychain.keychain_backend import (
    KEYCHAIN_ERROR,
    KEYCHAIN_FOUND,
    KEYCHAIN_MISS,
    KeychainBackend,
    KeychainLookup,
    StaticKeychainBackend,
)
from komira_secrets_keychain.keychain_secret_store import (
    KEYCHAIN_REF_SEP,
    KeychainRef,
    KeychainSecretStore,
    parse_keychain_ref,
)
from komira_secrets_keychain.macos_security_backend import (
    SECURITY_BIN,
    SECURITY_NOT_FOUND_EXIT,
    MacosSecurityKeychainBackend,
    build_security_argv,
)
