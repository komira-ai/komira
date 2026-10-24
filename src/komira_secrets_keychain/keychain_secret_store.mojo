# =============================================================================
# keychain_secret_store.mojo: `KeychainSecretStore`, the `SecretStore` over a
#   keychain.
# =============================================================================
#
# `resolve(secret_ref)` parses the handle (`service[/account]`), fetches the
# entry through the backend `B`, and returns the bytes in a zeroizing
# `SecretValue`. The backend's transient buffer is wiped before the call
# returns, so no owned plaintext copy outlives the `SecretValue`.
#
# The handle grammar: `service/account` splits on the FIRST '/'; `service`
# alone means an empty account (the keychain then matches on service). A service
# that contains '/' must use the two-part form.
#
# A miss raises with how to store the entry; a backend error raises with the
# backend's reason; an empty service raises before any fetch. No error carries
# the secret. The store's one field is the moved-in backend; the resolved value
# is built in the frame and returned, never held in a field.
#
# For local runs only: the keychain is a developer's own credential store.
# =============================================================================

from komira_secret_store.secret_store import SecretStore
from komira_secret_store.secret_value import SecretValue

from komira_secrets_keychain.keychain_backend import KeychainBackend, KeychainLookup


# =============================================================================
# §0 — the secret_ref grammar separator.
# =============================================================================
# The `secret_ref` encodes `service[/account]`; the FIRST '/' separates service
# from account. A service containing a literal '/' must use the two-part form.
comptime KEYCHAIN_REF_SEP: String = "/"


# =============================================================================
# §0.5 — KeychainRef + the pure parser (testable without a backend).
# =============================================================================
@fieldwise_init
struct KeychainRef(Copyable, Movable):
    """The parsed `(service, account)` of a keychain `secret_ref`. `account` is
    the empty string when the ref carried only a service. A value POD — both
    fields are NAMES, never the secret value."""

    var service: String
    var account: String


def parse_keychain_ref(secret_ref: String) raises -> KeychainRef:
    """Parse `secret_ref` (`service[/account]`) into its `(service, account)`.
    Splits on the FIRST '/': everything before is the service, everything after
    is the account (which may itself contain '/'). A ref with no '/' is a
    service-only ref (empty account). An EMPTY service (a leading '/' or an empty
    ref) RAISES — fail fast and loud, never query the keychain with no service.
    Pure — no backend."""
    var sb = secret_ref.as_bytes()
    var n = len(sb)
    # Find the FIRST '/'.
    var slash = -1
    for i in range(n):
        if sb[i] == UInt8(ord("/")):
            slash = i
            break

    # The split is at an ASCII '/', so both halves are UTF-8 boundaries and a
    # non-ASCII service or account is kept byte for byte.
    var service = String("")
    var account = String("")
    if slash < 0:
        # Service-only ref.
        service = String(secret_ref)
    else:
        service = String(secret_ref[byte=0:slash])
        account = String(secret_ref[byte=slash + 1 : n])

    if len(service.as_bytes()) == 0:
        raise Error(
            String(
                "KeychainSecretStore: secret_ref '"
            )
            + secret_ref
            + String(
                "' has an empty service (expected 'service[/account]')"
            )
        )
    return KeychainRef(service^, account^)


# =============================================================================
# §1 — KeychainSecretStore[B] — the SecretStore conformer.
# =============================================================================
struct KeychainSecretStore[B: KeychainBackend](
    SecretStore, Movable, Deinitable
):
    """The local-dev OS-keychain `SecretStore` conformer.
    `resolve(secret_ref)` parses `secret_ref` (`service[/account]`), fetches the
    value from the OS keychain via the backend `B`, and lands the bytes in a
    zeroizing `SecretValue`. A backend MISS (no such entry) or ERROR (keychain
    locked / CLI failed) RAISES (fail fast and loud). Parametric over the backend
    `B` (the `security` CLI in production, scripted in test).

    LOCAL-DEV ONLY — the developer's own keychain, the local stand-in for a
    cloud secret manager. NOT a production secret store; NEVER bind this in a
    deployed plane.

    Its one field is the moved-in backend `B`. No wildcard-origin field, no
    UnsafePointer field, and no secret is ever a struct field (the resolved
    value is built in the frame and returned)."""

    # The OS-keychain read backend (moved in). Production owns the subprocess
    # supervisor per fetch; a test owns the scripted map.
    var _backend: Self.B

    def __init__(out self, var backend: Self.B):
        """Construct with the (moved-in) keychain backend."""
        self._backend = backend^

    # -------------------------------------------------------------------------
    # The SecretStore trait method — handle in, zeroizing value out.
    # -------------------------------------------------------------------------
    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        """Resolve `secret_ref` (`service[/account]`) to its value by fetching the
        OS keychain via the backend. A backend MISS RAISES (with guidance to
        store the secret locally); a backend ERROR RAISES (with the backend's
        NON-secret reason); an empty service RAISES. NEVER a silent stale / empty
        value. The backend's transient lookup buffer is WIPED before return; the
        bytes land in a zeroizing `SecretValue`. The error NEVER carries the
        secret bytes."""
        # --- 1. Parse service[/account] (an empty service raises here). ---
        var ref_parts = parse_keychain_ref(secret_ref)

        # --- 2. Fetch from the keychain via the backend seam. ---
        var lookup = self._backend.fetch(ref_parts.service, ref_parts.account)

        # --- 3. A MISS RAISES with how-to-store guidance (fail fast and loud). -
        if lookup.is_miss():
            _wipe_lookup(lookup)
            raise Error(
                String("KeychainSecretStore: no keychain entry for secret_ref '")
                + secret_ref
                + String(
                    "' (store it with `security add-generic-password -s "
                )
                + ref_parts.service
                + String(" -a ")
                + ref_parts.account
                + String(" -w`)")
            )

        # --- 4. A backend ERROR RAISES with the NON-secret reason. ---
        if lookup.is_error():
            var reason = lookup.error_reason.copy()
            _wipe_lookup(lookup)
            raise Error(
                String("KeychainSecretStore: keychain backend failed for ")
                + String("secret_ref '")
                + secret_ref
                + String("': ")
                + reason^
            )

        # --- 5. FOUND -> mint the zeroizing SecretValue, wipe the transient. ---
        var value = SecretValue(
            Span[UInt8, origin_of(lookup.bytes)](lookup.bytes)
        )
        _wipe_lookup(lookup)
        return value^


# =============================================================================
# §2 — best-effort transient scrub for the lookup's byte buffer.
# =============================================================================
def _wipe_lookup(mut lookup: KeychainLookup):
    """Best-effort overwrite-then-clear of the lookup's `bytes` buffer (which held
    the secret on the found path). Defense-in-depth: the AUTHORITATIVE secure wipe
    is on the `SecretValue` (InlineArray + the -O3-surviving FFI `zeroize_inline_
    array`); the lookup holds the bytes only for the few instructions between the
    fetch and the `SecretValue` copy. (A plain loop may be DCE-eligible at -O3,
    which is why the load-bearing wipe lives on the InlineArray-backed value.)"""
    for i in range(len(lookup.bytes)):
        lookup.bytes[i] = UInt8(0)
    lookup.bytes.clear()
