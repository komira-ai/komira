# =============================================================================
# komira_secret_store — the secret-store SEAM and the value type it hands back.
#   "Ask something for the value behind this handle."
# =============================================================================
#
# WHAT THIS PACKAGE IS. The seam between code that USES a secret and code that
# KNOWS WHERE a secret lives. A connector, a registry or an SDK binds the
# `SecretStore` trait; the binary that assembles them plugs in one particular
# store. Keeping the seam in its own small package means a consumer can bind a
# store without depending on any store implementation.
#
#   * `SecretStore`       — a ONE-METHOD trait. `String` handle in, `SecretValue`
#                           out, `raises` on an unknown / unresolvable ref.
#   * `StaticSecretStore` — a scripted, network-free double for that trait.
#   * `SecretValue`       — an `InlineArray`-backed, move-only, redacted-`Display`
#                           plaintext holder with a zeroizing destructor.
#   * `SecretMeta`        — the catalog-facing NAMES-only record, the other half
#                           of the SecretMeta-vs-SecretValue type firewall.
#   * `MAX_SECRET_LEN`    — the inline buffer bound.
#
# NOT ONE of them names a provider, an endpoint, a tenant, a project or a
# credential. `SecretValue` in particular is a byte buffer with a `memset_s` in
# its destructor — the value-handling discipline is a property of the TYPE, and
# it has to travel with the trait, or a consumer of the seam cannot hold what
# the seam returns.
#
# The submodules `secret_get_seam`, `secret_put_seam` and `secret_reap_seam`
# carry three narrow Secret Manager seams (read a version, write a version,
# delete / list secrets, each acting as a caller-supplied bearer). They are not
# re-exported here; import them by submodule.
#
# WHAT IS NOT HERE. Every PARTICULAR store — a cloud secret manager client, a
# Vault or Conjur client, an OS-keychain reader, a token cache, an auditing or
# authorizing wrapper — and any names catalog live outside this package and
# enter through the `SecretStore` trait. The SHAPE is shared; a particular store
# is not.
#
# DEPENDENCIES. The whole dep closure is `komira_crypto` (`zeroize_inline_array`
# — the secure wipe that survives -O3). This package must not grow a dependency
# on any store implementation: that would re-create the coupling it exists to
# remove.
#
# A package that re-exports these names must do so as a RE-EXPORT, never a
# redeclaration — a redeclaration would silently split `SecretStore` into two
# nominally distinct traits and break every conformance.
# =============================================================================

from komira_secret_store.secret_value import (
    MAX_SECRET_LEN,
    SecretMeta,
    SecretValue,
)
from komira_secret_store.secret_store import (
    SecretStore,
    StaticSecretStore,
)
