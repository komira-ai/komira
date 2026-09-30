# =============================================================================
# komira_crypto/ed25519.mojo — Ed25519 signature scheme (RFC 8032 §5.1)
# =============================================================================
#
# Public Ed25519 API. The implementation body delegates to AWS-LC's
# hand-tuned ED25519_sign / ED25519_verify / ED25519_keypair[_from_seed]
# symbols via `internal/asm/ed25519_ffi.mojo`.
#
# # Why this exists
#
#   * SSH key authentication (Ed25519 is the modern default for
#     newly-generated SSH keys per OpenSSH).
#   * The few CA roots that use Ed25519 (small national CAs).
#
# Ed25519 is the simplest of the FFI-backed primitives: it is stateless
# (no opaque handle), has no per-call alloc, and AWS-LC exposes a direct
# sign/verify/keypair surface.
# # Public API
#
#   fn ed25519_sign(seed, msg) -> InlineArray[UInt8, 64]
#   fn ed25519_verify(pubkey, msg, sig) -> Bool
#   fn ed25519_pubkey_from_seed(seed) -> InlineArray[UInt8, 32]
#   fn ed25519_keypair_generate() -> (InlineArray[UInt8, 32], InlineArray[UInt8, 32])
#
# Where:
#   - `seed`: 32 bytes (the RFC 8032 §5.1.5 "secret key" — random uniform).
#   - `pubkey`: 32 bytes (the RFC 8032 §5.1.5 "public key" — derived from
#               seed via SHA-512 + clamp + scalar mult by base point).
#   - `sig`: 64 bytes (R || S, 32 + 32 bytes; the RFC 8032 §5.1.6 signature
#            format).
#   - `msg`: bytes of any length including 0 (Ed25519 supports zero-length
#            messages per RFC 8032 §5.1.6).
#
# # Failure semantics — SIGN RAISES, VERIFY FAILS CLOSED
#
# `ed25519_sign` / `ed25519_pubkey_from_seed` RAISE on a seed shorter than
# 32 bytes and on an AWS-LC failure. Guarding the length with a
# `debug_assert` would not do — it is compiled out of a release binary —
# and neither would discarding `ED25519_sign`'s return code. The two
# failure shapes those produce are (a) a signature/key derived from bytes
# past the end of the caller's buffer and (b) the caller's zero-filled
# output buffer returned as an all-zero 64-byte "signature". Both are
# indistinguishable from success at the call site. `p256_ffi.mojo` /
# `p384_ffi.mojo` guard the same class one layer down; see
# `internal/asm/ed25519_ffi.mojo`.
#
# `ed25519_verify` is non-raising and returns `Bool` directly. This
# matches the cert chain dispatch pattern (`chain.mojo::_verify_signature`
# expects a `Bool` return; failure is signaled by `False` not by `raise`).
# It returns `False` — rather than reading past the buffer — for a
# pubkey under 32 bytes or a signature under 64. That length can be REMOTE
# INPUT (a token verifier decodes the signature from the token itself), so
# `False` and not a raise: a truncated signature is an invalid signature,
# and the caller's contract for an invalid signature is a rejection.
#
# # Cert chain integration
#
# `cert/chain.mojo::_verify_signature` dispatches the Ed25519 OID
# (1.3.101.112) to `ed25519_verify`.
#
# # Encapsulation discipline
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins — `Span[UInt8, _]` is origin-inferred per
#     call site (NOT wildcard widening).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * The FFI binding is in `internal/asm/ed25519_ffi.mojo` (per the
#     `internal/asm/` carve-out convention; same shape as
#     `x25519_ffi.mojo` + `sha256_compress.mojo` + `p256_ffi.mojo`).
# =============================================================================

from .internal.asm import (
    ed25519_sign_from_seed,
    ed25519_verify as _ed25519_verify_ffi,
    ed25519_pubkey_from_seed as _ed25519_pubkey_from_seed_ffi,
    ed25519_keypair_generate as _ed25519_keypair_generate_ffi,
)


# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------


def ed25519_sign(
    seed: Span[UInt8, _],
    msg: Span[UInt8, _],
) raises -> Array[UInt8, 64]:
    """Sign `msg` with Ed25519 per RFC 8032 §5.1.6 using the 32-byte secret seed.

    Args:
        seed: 32-byte secret seed (caller-owned; must be ≥32 bytes;
            per RFC 8032 §5.1.5 the seed IS the secret key).
        msg: Message bytes (caller-owned; any length including 0).

    Returns:
        64-byte Ed25519 signature R || S (32 + 32 bytes).

    RAISES on a seed shorter than 32 bytes, and if AWS-LC's `ED25519_sign`
    reports failure. It never returns the unwritten output buffer — that
    shape is an all-zero 64-byte signature presented as success, which is
    exactly the failure shape the ECDSA wrappers also refuse.

    Determinism: Ed25519 is DETERMINISTIC by construction per RFC 8032 §5.1.6
    — the same `(seed, msg)` always produces the same signature. The
    nonce derivation uses SHA-512 over (prefix || msg) where the prefix
    is bytes [32:64] of the SHA-512 hash of the seed; no random source.
    This is the defining property of Ed25519 vs ECDSA.

    # Encapsulation
    Public API takes `Span[UInt8, _]` (origin-inferred). No UnsafePointer.
    No wildcard origins.

    # Constant-time
    AWS-LC's ED25519_sign is constant-time per FIPS 140-3 design (used in
    AWS-LC's FIPS-validated module). The scalar mult uses a constant-time
    table lookup over the comb-encoded base point precomputation.

    # Performance
    Matches AWS-LC's ED25519_sign byte-identically (this IS the AWS-LC
    implementation called via FFI). Per-call overhead vs a
    direct external_call: a few nanoseconds (Mojo's FFI dispatch +
    InlineArray init). Per-sign cost includes one seed-expansion
    (one SHA-512 hash + scalar clamp) since AWS-LC's ED25519_sign ABI
    requires the 64-byte expanded private key — see
    `internal/asm/ed25519_ffi.mojo` for the rationale.
    """
    var out = Array[UInt8, 64](fill=UInt8(0))
    ed25519_sign_from_seed(seed, msg, out)
    return out^


def ed25519_verify(
    pubkey: Span[UInt8, _],
    msg: Span[UInt8, _],
    sig: Span[UInt8, _],
) -> Bool:
    """Verify Ed25519 signature `sig` over `msg` against `pubkey` per RFC 8032 §5.1.7.

    Args:
        pubkey: 32-byte Ed25519 public key (caller-owned; must be ≥32 bytes).
        msg: Message bytes (caller-owned; any length including 0).
        sig: 64-byte Ed25519 signature R || S (caller-owned; must be ≥64 bytes).

    Returns:
        True iff the signature is valid; False on any failure (invalid
        signature, malformed pubkey, malformed sig bytes, point not on
        curve, etc. — AWS-LC's ED25519_verify is fail-closed on all
        verification-side errors).

        A pubkey under 32 bytes or a signature under 64 returns False. Both
        lengths are checked HERE rather than assumed: this call receives
        remote input on the token-verification path, where the signature length is
        whatever `base64_url_decode` produced from the token.

    # Cert chain dispatch (load-bearing)
    `cert/chain.mojo::_verify_signature` invokes this fn
    on certs with `signature_algo_oid == 1.3.101.112` (Ed25519). The
    pubkey is the issuer's 32-byte BIT STRING value from the SPKI; the
    msg is the subject cert's tbs_raw; the sig is the subject cert's
    signature_value (the raw R || S BIT STRING value).

    # Constant-time vs not
    Verify path is NOT required to be constant-time (all inputs are
    public per RFC 8032 §5.1.7). AWS-LC's ED25519_verify uses variable-
    time double-scalar mult (faster than fixed-time).

    # Performance
    Matches AWS-LC's ED25519_verify byte-identically.
    """
    return _ed25519_verify_ffi(pubkey, msg, sig)


def ed25519_pubkey_from_seed(
    seed: Span[UInt8, _],
) raises -> Array[UInt8, 32]:
    """Derive the 32-byte Ed25519 public key from the 32-byte secret seed.

    Args:
        seed: 32-byte secret seed (caller-owned; must be ≥32 bytes).

    Returns:
        32-byte Ed25519 public key.

    Per RFC 8032 §5.1.5, the pubkey is fully determined by the seed via:
        1. SHA-512(seed) -> 64 bytes
        2. h_lo = bytes [0:32]; clamp per RFC 8032 §5.1.5 to scalar A
        3. pubkey = A * B (where B is the Ed25519 base point)

    AWS-LC's `ED25519_keypair_from_seed` performs steps 1-3 internally.

    # Used by
    Cert chain SPKI extraction (where the SPKI BIT STRING for Ed25519
    is the raw 32-byte pubkey — no further encoding); test fixtures;
    keypair-from-seed flows (SSH key derivation).
    """
    var pubkey_out = Array[UInt8, 32](fill=UInt8(0))
    _ed25519_pubkey_from_seed_ffi(seed, pubkey_out)
    return pubkey_out^


def ed25519_keypair_generate() -> Tuple[Array[UInt8, 32], Array[UInt8, 32]]:
    """Generate a fresh Ed25519 keypair (seed + pubkey).

    Returns:
        Tuple of (seed, pubkey), each 32 bytes:
            - seed: random 32-byte secret seed sourced from OS entropy
              (via AWS-LC's CSPRNG → getrandom/getentropy under the hood).
            - pubkey: derived public key.

    The pubkey is fully determined by the seed per RFC 8032 §5.1.5; if a
    caller needs to re-derive the pubkey from a stored seed they should
    use `ed25519_pubkey_from_seed(seed)` instead of regenerating the pair.
    """
    var seed = Array[UInt8, 32](fill=UInt8(0))
    var pubkey = Array[UInt8, 32](fill=UInt8(0))
    _ed25519_keypair_generate_ffi(seed, pubkey)
    return (seed^, pubkey^)
