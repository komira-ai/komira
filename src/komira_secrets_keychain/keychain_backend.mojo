# =============================================================================
# keychain_backend.mojo: the keychain read seam under `KeychainSecretStore`.
# =============================================================================
#
# Reading a keychain is platform-specific (macOS `security`, Linux Secret
# Service, Windows Credential Manager); the store's logic is not. The seam is
# `fetch(service, account) -> KeychainLookup`, so the store is tested with no
# keychain and a platform backend can be added without touching the store.
#
# A lookup has three outcomes, kept distinct: found (with the bytes), miss (no
# such entry) and error (the backend failed: keychain locked, `security`
# missing). The store raises on a miss and on an error, with different
# messages. The error reason is a diagnostic, never the secret.
#
# The seam is value-typed: two names in, a `KeychainLookup` out. The found bytes
# are a flat `List[UInt8]` the store copies into a `SecretValue` and wipes.
# No pointer, wildcard origin or `unsafe_from_address` appears here.
#
# For local runs only: the keychain is a developer's own credential store, not a
# production secret store.
# =============================================================================

comptime KEYCHAIN_FOUND: Int = 0
comptime KEYCHAIN_MISS: Int = 1
comptime KEYCHAIN_ERROR: Int = 2


struct KeychainLookup(Movable):
    """The result of one `KeychainBackend.fetch`. Carries EXACTLY one of:
    found+bytes, miss, or error+reason (the three outcomes stay distinct).
    The `bytes` field holds the found plaintext as a flat `List[UInt8]` POD (NOT a
    `SecretValue` — a lookup is a transient the store reads once and wipes; the
    zeroizing value is minted by the store). The `error_reason` is a NON-secret
    operator diagnostic; it NEVER carries the secret bytes. Move-only (owns a
    List)."""

    # The outcome discriminant: KEYCHAIN_FOUND / KEYCHAIN_MISS / KEYCHAIN_ERROR.
    var kind: Int
    # The found plaintext bytes — meaningful ONLY when kind == KEYCHAIN_FOUND.
    # A transient the store copies into a zeroizing `SecretValue` then wipes.
    var bytes: List[UInt8]
    # A NON-secret diagnostic — meaningful ONLY when kind == KEYCHAIN_ERROR.
    # The store folds this into its raise message; it NEVER carries the value.
    var error_reason: String

    def __init__(out self, kind: Int, var bytes: List[UInt8], var error_reason: String):
        self.kind = kind
        self.bytes = bytes^
        self.error_reason = error_reason^

    @staticmethod
    def found(var bytes: List[UInt8]) -> KeychainLookup:
        """The entry exists; `bytes` is its plaintext value."""
        return KeychainLookup(KEYCHAIN_FOUND, bytes^, String(""))

    @staticmethod
    def miss() -> KeychainLookup:
        """No such entry — the dev never stored this secret locally."""
        return KeychainLookup(KEYCHAIN_MISS, List[UInt8](), String(""))

    @staticmethod
    def error(var reason: String) -> KeychainLookup:
        """The backend itself failed; `reason` is a NON-secret diagnostic."""
        return KeychainLookup(KEYCHAIN_ERROR, List[UInt8](), reason^)

    def is_found(self) -> Bool:
        return self.kind == KEYCHAIN_FOUND

    def is_miss(self) -> Bool:
        return self.kind == KEYCHAIN_MISS

    def is_error(self) -> Bool:
        return self.kind == KEYCHAIN_ERROR


# =============================================================================
# §1 — KeychainBackend — the pluggable OS-keychain read seam.
# =============================================================================
trait KeychainBackend(Movable, Deinitable):
    """Fetch the plaintext value for a `(service, account)` pair from the OS
    keychain. Returns a `KeychainLookup` carrying exactly one of found+bytes,
    miss, or error+reason. The store maps a miss or an error to a clear RAISE
    (fail fast and loud), and lands found bytes in a zeroizing `SecretValue`.

    `service` and `account` are both NAMES (the keychain's service/label + the
    account/username), never values. No UnsafePointer crosses the boundary; no
    wildcard origin. Production binds a platform backend (the macOS `security`
    CLI through komira_supervisor; libsecret and DPAPI are not provided); a test
    binds `StaticKeychainBackend` (a scripted map, hermetic).

    LOCAL-DEV ONLY — the OS keychain is the developer's own credential store,
    the local stand-in for a cloud secret manager, NOT a production secret store."""

    def fetch(mut self, service: String, account: String) raises -> KeychainLookup:
        ...


# =============================================================================
# §2 — StaticKeychainBackend — a scripted, in-memory backend (the TEST DOUBLE).
#
# Lets the store test run with ZERO real keychain: a known `(service, account)`
# resolves to its scripted bytes (found); an un-scripted pair returns a MISS; a
# pair the test marks as failing returns an ERROR. It also RECORDS the last
# `(service, account)` it was queried with (and a query count) so a test can
# assert the store PARSED the `secret_ref` and queried the backend with the
# expected service/account — the "the backend was queried with the parsed
# service/account" gate. A live backend never holds the plaintext at rest like
# this; it reads per-fetch from the OS keychain.
# =============================================================================
struct StaticKeychainBackend(KeychainBackend, Movable):
    """An in-memory, scripted `KeychainBackend` (the TEST DOUBLE). Scripts
    `(service, account) -> bytes` for the found path, a set of `(service,
    account)` pairs that return ERROR, and treats every other pair as a MISS.
    Records the LAST queried `(service, account)` + a `query_count` (the
    parse-and-query proof the store gate relies on). No subprocess, no keychain."""

    # The scripted found entries, keyed by the composite `service\x00account`.
    var _found: Dict[String, List[UInt8]]
    # The pairs (same composite key) that should return a backend ERROR.
    var _errors: Dict[String, String]
    # The last `(service, account)` queried — the parse-and-query proof.
    var _last_service: String
    var _last_account: String
    var _query_count: Int

    def __init__(out self):
        self._found = Dict[String, List[UInt8]]()
        self._errors = Dict[String, String]()
        self._last_service = String("")
        self._last_account = String("")
        self._query_count = 0

    @staticmethod
    def _key(service: String, account: String) -> String:
        """The composite map key for a `(service, account)` pair. Uses a NUL
        separator (neither a service nor an account contains a NUL) so distinct
        pairs cannot collide."""
        return service + String(chr(0)) + account

    def put(mut self, service: String, account: String, value: String):
        """Script a found entry: `(service, account) -> value`. Held as raw bytes;
        the backend returns a fresh `KeychainLookup.found` from it. Re-`put`ting
        the same pair overwrites (models the dev rotating the local secret)."""
        var bytes = List[UInt8]()
        var src = value.as_bytes()
        for i in range(len(src)):
            bytes.append(src[i])
        self._found[StaticKeychainBackend._key(service, account)] = bytes^

    def put_error(mut self, service: String, account: String, reason: String):
        """Script a backend ERROR for `(service, account)` — models the keychain
        being locked / the `security` binary failing. The next `fetch` of this
        pair returns `KeychainLookup.error(reason)`."""
        self._errors[StaticKeychainBackend._key(service, account)] = reason

    def last_service(self) -> String:
        """The `service` of the most recent `fetch` (the parse proof)."""
        return self._last_service

    def last_account(self) -> String:
        """The `account` of the most recent `fetch` (the parse proof)."""
        return self._last_account

    def query_count(self) -> Int:
        """How many times `fetch` was called (the query proof)."""
        return self._query_count

    def fetch(mut self, service: String, account: String) raises -> KeychainLookup:
        """Record the queried `(service, account)`, then return the scripted
        outcome: a found entry's bytes, a scripted error, else a miss."""
        self._query_count += 1
        self._last_service = service
        self._last_account = account
        var key = StaticKeychainBackend._key(service, account)
        if self._errors.__contains__(key):
            return KeychainLookup.error(self._errors[key].copy())
        if self._found.__contains__(key):
            ref bytes = self._found[key]
            var out = List[UInt8]()
            for i in range(len(bytes)):
                out.append(bytes[i])
            return KeychainLookup.found(out^)
        return KeychainLookup.miss()
