# =============================================================================
# komira_secret_store/secret_value.mojo — the zeroizing, redacted secret VALUE
#   type + the catalog-facing SecretMeta value type (the SecretMeta-vs-SecretValue
#   type firewall).
# =============================================================================
#
# Nothing in this file names an org, a project, a tenant or a provider
# endpoint: it is an InlineArray of bytes, a length, a redacted `Display`, a
# scoped `Span` accessor and a zeroizing destructor. Its whole dep closure is
# `komira_crypto.zeroize_inline_array`.
#
# THE VALUE-HANDLING DISCIPLINE. The secret store owns value custody, but the
# process that resolves a ref still fetches the plaintext the
# store hands back and injects it into a connection. `SecretValue` is the type
# that briefly holds that plaintext.
#
# WHY NOT A `String`. A credential held as a `String` cannot be securely zeroed:
# `String` has no secure-zero destructor, and a plain `llvm.memset.inline` wipe
# is removed as dead code at -O3 (see `komira_crypto`'s `zeroize` module). An
# accessor returning an owned `String` copy multiplies the problem. So
# `SecretValue`:
#   * stores bytes in an `InlineArray[UInt8, MAX_SECRET_LEN]` + a `_len`,
#     NEVER a `String` (no heap-inner String/List; the bytes live inline in the
#     struct, so there is no heap allocation to leak);
#   * has an explicit destructor that calls `zeroize_inline_array` (the FFI
#     `memset_s`/`explicit_bzero` path that survives -O3);
#   * does NOT expose `reveal() -> String`. It exposes a SCOPED accessor —
#     `revealed_bytes()` (a `Span[UInt8, origin_of(self)]`) — so no owned
#     plaintext copy escapes and the bytes are wiped when `SecretValue` drops;
#   * is NOT Copyable — every move would otherwise memcpy a live secret without
#     wiping the source. Move-only (`Movable`), single-owner.
#
# The redacted `Display` (no secret in `__str__`/`Display`/`repr`) is the
# REDACTION half; the BYTE representation (InlineArray, not String) is the
# wiping half.
#
# SAFETY. ZERO UnsafePointer crosses any boundary. The one `UnsafePointer` use
# is INSIDE `zeroize_inline_array` (encapsulated in komira_crypto,
# origin-concrete, never surfaced). The scoped accessor hands out a `Span` whose
# origin is `origin_of(self)` — it cannot outlive the value, so the
# wiped-on-drop guarantee holds. NO wildcard origin; NO unsafe_from_address.
# =============================================================================

from komira_crypto import zeroize_inline_array


# The maximum secret length the inline buffer holds. Sized for the largest
# realistic single secret (a long connection string / a JWT-shaped API key /
# a PEM private key fits comfortably). Chosen as a power-of-two-ish round number;
# an over-length value RAISES at construction (fail fast and loud — never a
# silent truncation that would corrupt a credential).
comptime MAX_SECRET_LEN: Int = 4096


# =============================================================================
# §1 — SecretMeta — the CATALOG-facing value type (the type firewall).
#
# `SecretMeta` is what a catalog / listing surface sees: name handle, provider,
# reachability — and NO secret field, NO accessor. It is the only
# secret-related type such a surface should import. Distinct type from
# `SecretValue` with NO conversion between them — establishing the firewall in
# TYPES so a catalog surface can never accidentally hold a value.
# =============================================================================
@fieldwise_init
struct SecretMeta(Copyable, Movable, Deinitable, Writable):
    """The catalog-facing metadata for one secret. Carries ONLY
    NAMES/handles + the provider/reachability ordinals — NO secret field, NO
    `reveal()`/accessor, fully log- and JSON-safe. The ONLY secret-related type
    a catalog surface should hold; it has NO path to a `SecretValue`."""

    var name_handle: String
    """The opaque catalog handle. A NAME, not a value."""
    var provider_kind: Int32
    """WHICH store the value lives in (a provider ordinal)."""
    var reachability: Int32
    """Whether the value's store is reachable from the resolving process (an
    ordinal)."""

    def write_to[W: Writer](self, mut writer: W):
        """A log-safe rendering — carries NO secret (there is none to carry)."""
        writer.write(
            "SecretMeta(name_handle='",
            self.name_handle,
            "', provider_kind=",
            self.provider_kind,
            ", reachability=",
            self.reachability,
            ")",
        )


# =============================================================================
# §2 — SecretValue — the zeroizing, redacted, NOT-Copyable plaintext holder.
# =============================================================================
struct SecretValue(Movable, Deinitable, Writable):
    """The plaintext secret value a resolving process briefly holds.
    InlineArray-backed (NOT a `String`), zeroized on drop via
    `zeroize_inline_array`, redacted `Display`, scoped read-only accessors, and
    NOT Copyable (move-only, single-owner — a copy would memcpy a live secret
    without wiping the source).

    Lifetime: constructed by a `SecretStore` adapter from the bytes the secret
    store hands back, read exactly once through a scoped accessor at the
    point-of-use connector shim, then dropped — at which point its backing bytes
    are securely zeroed (the -O3-surviving FFI memset)."""

    # The inline secret bytes. Lives inline in the struct, no heap
    # allocation, so a `List[SecretValue]` accumulation (were it Copyable — it is
    # not) has no heap-inner to leak. The trailing `_len` bytes past the secret
    # are unused (and also zeroed on drop, since we wipe the whole array).
    var _buf: Array[UInt8, MAX_SECRET_LEN]
    # The secret's true length (<= MAX_SECRET_LEN). Bounds every read.
    var _len: Int

    # -------------------------------------------------------------------------
    # Construction — from a byte span the secret store handed back.
    # -------------------------------------------------------------------------
    def __init__(out self, data: Span[UInt8, _]) raises:
        """Construct from the plaintext bytes the secret store returned. An
        over-length value (`> MAX_SECRET_LEN`) RAISES — fail fast and loud, never
        a silent truncation that would corrupt a credential. The source `data`
        is copied byte-for-byte into the inline buffer; the caller is expected to
        wipe its own transient source (the adapter's fetch buffer)."""
        var n = len(data)
        if n > MAX_SECRET_LEN:
            raise Error(
                String(
                    "SecretValue: value exceeds MAX_SECRET_LEN (got "
                )
                + String(n)
                + String(" bytes)")
            )
        self._buf = Array[UInt8, MAX_SECRET_LEN](fill=UInt8(0))
        for i in range(n):
            self._buf[i] = data[i]
        self._len = n

    @staticmethod
    def from_string(s: String) raises -> SecretValue:
        """Construct from a `String`'s bytes (the common adapter path — the
        secret store's HTTP/gRPC client decodes the value to a `String`, then
        moves it straight into a `SecretValue`). The caller's transient `String`
        remains the caller's responsibility to drop; this copies its bytes in."""
        return SecretValue(s.as_bytes())

    # -------------------------------------------------------------------------
    # The SOLE readers — scoped, no escaping owned copy. NO `reveal() -> String`.
    # -------------------------------------------------------------------------
    def len(self) -> Int:
        """The secret's byte length. Non-secret (a length is not the value)."""
        return self._len

    def is_empty(self) -> Bool:
        return self._len == 0

    def revealed_bytes(ref self) -> Span[UInt8, origin_of(self._buf)]:
        """The SCOPED sole reader. A read-only view of
        EXACTLY the secret bytes, origin-bound to `self`. The span CANNOT outlive
        `self` (the compiler ties its origin to the inline buffer), so the
        wipe-on-drop guarantee holds — there is no owned copy to leak. This is
        the byte-oriented sole reader a connector shim uses to open a
        connection, and the single entry point an audit hook would wrap. NEVER
        call this in a log / format / error context — the redacted `Display` is
        what those paths must hit.

        A scoped-CLOSURE accessor (`with_revealed[f]`) would be an alternative
        shape; it is not provided, because the lifetime of a `SecretValue`
        borrowed across a closure is not settled. `revealed_bytes()` is the
        sole reader."""
        return Span[UInt8, origin_of(self._buf)](self._buf)[: self._len]

    # -------------------------------------------------------------------------
    # Redacted Display — the secret NEVER appears.
    # -------------------------------------------------------------------------
    def write_to[W: Writer](self, mut writer: W):
        """REDACTED — the secret bytes NEVER appear. An accidental `print(sv)` /
        log line / error-format is a no-op, not a leak (the type makes the safe
        thing the default thing).
        Carries only the (non-secret) byte length for diagnostics."""
        writer.write("SecretValue(<redacted:", self._len, "B>)")

    # -------------------------------------------------------------------------
    # Zeroizing destructor — the -O3-surviving secure wipe.
    # -------------------------------------------------------------------------
    def __deinit__(deinit self):
        """Securely zero the ENTIRE backing buffer on drop via the FFI
        `memset_s`/`explicit_bzero` path that survives -O3 DCE.
        We wipe the whole `MAX_SECRET_LEN` array (not just `_len`) so no stale
        prefix of a previously-longer value can linger in the reused slot.
        The `_len` scalar carries no secret."""
        zeroize_inline_array(self._buf)
        # `_len` is a plain Int (no secret material) and is consumed by the
        # `deinit self` drop; no explicit wipe needed (a length is not a secret).
        _ = self._len
