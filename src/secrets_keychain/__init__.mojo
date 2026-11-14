# =============================================================================
# secrets_keychain: a `SecretStore` over the operating system's keychain,
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
#                               supervisor. On any other platform its
#                               `fetch` answers an error and starts no process.
#     The exit-code mapping and stdout parsing are `map_security_result`, which
#     compiles and is tested on every platform.
#   * `StaticKeychainBackend`   the hermetic, recording test double.
#   * `parse_keychain_ref`, `build_security_argv`  pure helpers.
#
# DEPENDENCIES: secret_store, supervisor (and its async_rt),
# crypto.
# =============================================================================

from secrets_keychain.keychain_backend import (
    KEYCHAIN_ERROR,
    KEYCHAIN_FOUND,
    KEYCHAIN_MISS,
    KeychainBackend,
    KeychainLookup,
    StaticKeychainBackend,
)
from secrets_keychain.keychain_secret_store import (
    KEYCHAIN_REF_SEP,
    KeychainRef,
    KeychainSecretStore,
    parse_keychain_ref,
)
from secrets_keychain.macos_security_backend import (
    SECURITY_BIN,
    SECURITY_NOT_FOUND_EXIT,
    MacosSecurityKeychainBackend,
    build_security_argv,
    map_security_result,
)
