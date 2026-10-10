# =============================================================================
# komira_crypto/internal/asm/ed25519_ffi.mojo
# =============================================================================
#
# Ed25519 sign + verify + keypair-from-seed + keypair-generate — FFI wrapper to
# AWS-LC's hand-tuned ED25519_sign / ED25519_verify / ED25519_keypair /
# ED25519_keypair_from_seed symbols from libcrypto.a (vendored from BoringSSL
# via AWS-LC; Apache 2.0 / OpenSSL dual licensed).
#
# # Why this exists
#
# Ed25519 is the simplest shape of the FFI-backed primitives: stateless, no
# opaque handle, no per-call alloc, no curve-param fetching — just call the
# AWS-LC symbol with raw byte buffers.
#
# # Approach: bare ED25519_sign / ED25519_verify / ED25519_keypair[_from_seed]
#
# Unlike opaque-handle primitives (AesGcmCtx / ChaCha20Poly1305Ctx /
# ECDSA_SIG + EC_KEY in P-256/P-384 / RSA + 2x BIGNUM in RSA-PSS),
# Ed25519 in AWS-LC is exposed as four free symbols that take raw byte
# buffers. Same shape as X25519 (the closest template precedent).
#
#   int ED25519_sign(uint8_t out_sig[64],
#                    const uint8_t *message, size_t message_len,
#                    const uint8_t private_key[64]);
#   int ED25519_verify(const uint8_t *message, size_t message_len,
#                      const uint8_t signature[64],
#                      const uint8_t public_key[32]);
#   void ED25519_keypair(uint8_t out_public_key[32],
#                        uint8_t out_private_key[64]);
#   void ED25519_keypair_from_seed(uint8_t out_public_key[32],
#                                  uint8_t out_private_key[64],
#                                  const uint8_t seed[32]);
#
# # AWS-LC "private key" convention (load-bearing)
#
# AWS-LC's `private_key` parameter for ED25519_sign is the 64-byte
# `SEED || PUBKEY` concatenation per RFC 8032 §5.1.5 internal layout
# (NOT the 32-byte raw seed). The raw 32-byte seed (what RFC 8032
# §7.1 test vectors call "SECRET KEY") expands to the 64-byte form via
# `ED25519_keypair_from_seed(out_pub, out_priv_64, seed_32)`. The
# 64-byte expanded form contains the seed in bytes [0:32] and the
# derived pubkey in bytes [32:64].
#
# The pure-Mojo public API in `ed25519.mojo` accepts the 32-byte seed
# (RFC 8032 convention) and performs the expansion internally via
# `ed25519_keypair_from_seed`.
#
# # Symbols verified
#
# `nm libcrypto.a | grep ED25519` confirms:
#   _ED25519_sign                       T at 0x1e4a8
#   _ED25519_verify                     T at 0x1e7e4
#   _ED25519_keypair                    T at 0x1e424
#   _ED25519_keypair_from_seed          T at 0x1e19c
# (all DEFINED in libcrypto.a text segment; no _no_self_test / FIPS
# variant indirection required — the bare names are the production path).
#
# # Build wiring
#
# The `external_call` sites below are symbol REFERENCES, resolved at the
# final link of any consumer binary against aws-lc's libcrypto (a
# dependency of this package).
#
# # Encapsulation discipline
#
# Public API:
#   * `ed25519_sign_from_seed(seed, msg, mut sig_out)` takes Span[UInt8, _]
#     + mut InlineArray[UInt8, 64] — ZERO UnsafePointer in the public
#     signature.
#   * `ed25519_verify(pubkey, msg, sig)` takes Span[UInt8, _] only —
#     ZERO UnsafePointer.
#   * `ed25519_pubkey_from_seed(seed, mut pubkey_out)` takes Span +
#     mut InlineArray — ZERO UnsafePointer.
#   * `ed25519_keypair_generate(mut seed_out, mut pubkey_out)` takes
#     mut InlineArray only — ZERO UnsafePointer.
# Internal FFI:
#   * Each `external_call[...]` site uses `UnsafePointer(to=...)` /
#     `Span.unsafe_ptr()` with INFERRED origin (NOT wildcard widening),
#     following the X25519 + SHA-256 + ECDSA precedent.
#   * NO opaque-CTX wrapper struct (no per-call alloc; no _ctx field).
#   * NO `unsafe_from_address`.
#   * NO `take_pointee`.
#   * NO ArcPointer.
#   * Each external_call site carries a multi-line `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# Public wrapper — ed25519_pubkey_from_seed.
#
# Derives the 32-byte Ed25519 public key from the 32-byte secret seed via
# AWS-LC's `ED25519_keypair_from_seed`. Internally AWS-LC writes BOTH the
# 32-byte pubkey AND the 64-byte expanded private key (SEED || PUBKEY);
# this wrapper exposes only the pubkey for the public API. The
# `ed25519_sign_from_seed` wrapper invokes `ED25519_keypair_from_seed`
# separately to obtain the 64-byte expanded private key needed by
# `ED25519_sign`.
# -----------------------------------------------------------------------------


@always_inline
def ed25519_pubkey_from_seed(
    seed: Span[UInt8, _],
    mut pubkey_out: Array[UInt8, 32],
) raises:
    """Derive the 32-byte Ed25519 public key from the 32-byte secret seed.

    Args:
        seed: 32-byte secret seed (caller-owned; MUST be ≥32 bytes).
        pubkey_out: 32-byte output buffer; filled with the derived
            public key on return.

    Performance: matches AWS-LC's own `ED25519_keypair_from_seed`
    byte-identically — this IS the AWS-LC implementation. Per-call
    overhead vs a direct external_call: a few
    nanoseconds (Mojo's FFI dispatch + InlineArray init).
    """
    # ⚠ A REAL CHECK, NOT `debug_assert` — `debug_assert` is COMPILED OUT of the
    # shipped binary, and AWS-LC reads exactly 32 bytes from `seed` regardless of
    # the Span's length. A short seed would derive a key from bytes past the
    # end of the caller's buffer and return it as a normal success. A signing
    # key feeds a PUBLISHED JWKS, where a wrong key
    # rejects every token minted against it, forever, with no other signal.
    if len(seed) < 32:
        raise Error(
            String(
                "ed25519_pubkey_from_seed: seed must be >= 32 bytes (got "
            )
            + String(len(seed))
            + String(
                "). Refusing to derive a public key from bytes past the end of"
                " the caller's buffer."
            )
        )

    # Scratch buffer for the 64-byte expanded private key (SEED || PUBKEY
    # internal form). We discard it; the pubkey is the load-bearing output.
    var expanded_priv = Array[UInt8, 64](fill=UInt8(0))

    # SAFETY: AWS-LC's `ED25519_keypair_from_seed` reads exactly 32 bytes
    # from `seed`, writes exactly 32 bytes to `out_public_key` (pubkey_out)
    # and exactly 64 bytes to `out_private_key` (expanded_priv). All three
    # buffers are caller-owned for the duration of this synchronous call;
    # AWS-LC retains no pointer past the call.
    #
    # Pointers are constructed via `UnsafePointer(to=x).bitcast[UInt8]()`
    # following the X25519 precedent. Origin is INFERRED from the locals
    # `pubkey_out` (mut InlineArray) + `expanded_priv` (mut local InlineArray)
    # and the `seed` span — NOT a wildcard widening. The local pointers do
    # not escape this function body.
    external_call["komira_awslc_ED25519_keypair_from_seed", NoneType](
        UnsafePointer(to=pubkey_out[0]).bitcast[UInt8](),
        UnsafePointer(to=expanded_priv[0]).bitcast[UInt8](),
        seed.unsafe_ptr().bitcast[UInt8](),
    )


# -----------------------------------------------------------------------------
# Public wrapper — ed25519_sign_from_seed.
#
# Signs `msg` with the secret key derived from `seed`. Internally AWS-LC's
# `ED25519_sign` requires the 64-byte expanded private key (SEED || PUBKEY
# form per RFC 8032 §5.1.5), so this wrapper first expands the 32-byte
# seed via `ED25519_keypair_from_seed`, then invokes `ED25519_sign`.
# -----------------------------------------------------------------------------


@always_inline
def ed25519_sign_from_seed(
    seed: Span[UInt8, _],
    msg: Span[UInt8, _],
    mut sig_out: Array[UInt8, 64],
) raises:
    """Sign `msg` with Ed25519 using the 32-byte secret seed.

    Args:
        seed: 32-byte secret seed (caller-owned; MUST be ≥32 bytes;
            per RFC 8032 §5.1.5 the seed is the secret key input).
        msg: Message bytes (caller-owned; any length including 0).
        sig_out: 64-byte output buffer; filled with the Ed25519
            signature (R || S, 32 + 32 bytes) on return.

    Performance: matches AWS-LC's own `ED25519_sign` byte-identically —
    this IS the AWS-LC implementation. Per-call overhead is the seed
    expansion (one SHA-512 hash + scalar clamp) + the actual ED25519_sign
    body (one SHA-512 over R || A || msg + a scalar mult + a scalar
    multiply-add). At steady state the ratio vs a direct
    external_call should be ~1.000x.

    The seed expansion via `ED25519_keypair_from_seed` adds a constant
    ~few-microseconds overhead per sign call (one extra SHA-512). This
    is the canonical RFC 8032 §5.1.5 layout; pre-computing and storing
    the 64-byte expanded private key in user state would be a perf
    micro-optimization (~10% sign cost), worth doing only if a benchmark
    shows it matters.
    """
    # ⚠ A REAL CHECK, NOT `debug_assert` — see `ed25519_pubkey_from_seed` above
    # for the mechanism. A short seed here signed with 32 bytes the caller does
    # not own, producing a signature indistinguishable from a legitimate one.
    if len(seed) < 32:
        raise Error(
            String("ed25519_sign_from_seed: seed must be >= 32 bytes (got ")
            + String(len(seed))
            + String(
                "). Refusing to sign with bytes past the end of the caller's"
                " buffer."
            )
        )

    # Expand seed -> 64-byte private key (SEED || PUBKEY) per AWS-LC's
    # ED25519_sign ABI. Scratch buffers for the expansion outputs.
    var pubkey_scratch = Array[UInt8, 32](fill=UInt8(0))
    var expanded_priv = Array[UInt8, 64](fill=UInt8(0))

    # SAFETY: see ed25519_pubkey_from_seed for the keypair_from_seed
    # safety argument (same FFI signature, same buffer ownership).
    external_call["komira_awslc_ED25519_keypair_from_seed", NoneType](
        UnsafePointer(to=pubkey_scratch[0]).bitcast[UInt8](),
        UnsafePointer(to=expanded_priv[0]).bitcast[UInt8](),
        seed.unsafe_ptr().bitcast[UInt8](),
    )

    # SAFETY: AWS-LC's `ED25519_sign` writes exactly 64 bytes to
    # `out_sig` (sig_out), reads `message_len` bytes from `message` (msg),
    # reads exactly 64 bytes from `private_key` (expanded_priv). All
    # buffers are caller-owned for the duration of this synchronous
    # call; AWS-LC retains no pointer past the call. Message length is
    # passed as `Int` (Mojo's `Int` matches the host's `size_t` ABI
    # on both LP64 macOS-arm64 and LP64 linux-x86_64).
    var rc = external_call["komira_awslc_ED25519_sign", Int32](
        UnsafePointer(to=sig_out[0]).bitcast[UInt8](),
        msg.unsafe_ptr().bitcast[UInt8](),
        Int(len(msg)),
        UnsafePointer(to=expanded_priv[0]).bitcast[UInt8](),
    )
    # ED25519_sign returns 1 on success, 0 on failure (AWS-LC fails it only on
    # a SHA-512 self-test failure — a FIPS health check that a non-FIPS build
    # does not exercise). CHECKED ANYWAY, and this is not defensive padding:
    # discarding it is precisely the defect `p256_ffi.mojo` / `p384_ffi.mojo`
    # guard against, where a failing sign returns SUCCESS with the caller's
    # zero-filled buffer as a 64-byte all-zero "signature".
    if Int(rc) != 1:
        raise Error(  # cov: unreachable ED25519_sign fails only on a FIPS self-test failure, which this non-FIPS build does not run
            String(  # cov: unreachable see the line above
                "ed25519_sign_from_seed: AWS-LC ED25519_sign failed (returned"
                " "
            )
            + String(Int(rc))  # cov: unreachable see the line above
            + String(  # cov: unreachable see the line above
                "). Refusing to return the unwritten output buffer, which would"
                " be an all-zero 64-byte signature presented as success."
            )
        )


# -----------------------------------------------------------------------------
# Public wrapper — ed25519_verify.
#
# Verifies signature `sig` over `msg` against `pubkey`. Returns True iff
# the signature is valid. AWS-LC's ED25519_verify returns 1 on valid /
# 0 on invalid (including any parse failure on the signature bytes).
# -----------------------------------------------------------------------------


@always_inline
def ed25519_verify(
    pubkey: Span[UInt8, _],
    msg: Span[UInt8, _],
    sig: Span[UInt8, _],
) -> Bool:
    """Verify Ed25519 signature `sig` over `msg` against `pubkey`.

    Args:
        pubkey: 32-byte Ed25519 public key (caller-owned;
            MUST be ≥32 bytes).
        msg: Message bytes (caller-owned; any length including 0).
        sig: 64-byte Ed25519 signature R || S (caller-owned;
            MUST be ≥64 bytes; AWS-LC checks length internally).

    Returns:
        True iff the signature is valid; False on any failure
        (invalid signature, malformed pubkey, malformed sig bytes).

    Performance: matches AWS-LC's own `ED25519_verify` byte-identically —
    this IS the AWS-LC implementation. Per-call overhead vs a direct
    external_call: a few nanoseconds (Mojo's FFI
    dispatch).
    """
    # ⚠⚠ REAL CHECKS, NOT `debug_assert`, AND THE MOST LOAD-BEARING ONES IN THIS
    # FILE. `debug_assert` is COMPILED OUT of the shipped binary; AWS-LC's
    # `ED25519_verify` then reads exactly 64 bytes from `sig` and exactly 32 from
    # `pubkey` no matter what the Spans' lengths say.
    #
    # This call takes REMOTE, UNAUTHENTICATED input: a token-verifying request
    # middleware decodes `sig` from the token's signature segment
    # (`base64_url_decode(seg_sig)`) and may check only that the segment is
    # non-EMPTY — the decoded length is chosen by whoever sent the token.
    # Without these checks a one-byte signature segment would cause a 64-byte
    # read off a one-byte heap buffer, and if the bytes behind it happened to
    # complete a valid signature the truncated token would VERIFY.
    #
    # FAIL-CLOSED (`False`), DELIBERATELY NOT A RAISE: a truncated signature IS an
    # invalid signature, and a verifier's contract for that is a rejection. Raising
    # here would convert malformed input into an exception on a request path whose
    # whole design is to answer "rejected" — a worse posture, and a behaviour change
    # for every caller. The two SIGNING entry points above raise instead, because
    # there is no "invalid signature" value for them to return.
    if len(pubkey) < 32:
        return False
    if len(sig) < 64:
        return False

    # SAFETY: AWS-LC's `ED25519_verify` reads `message_len` bytes from
    # `message` (msg), exactly 64 bytes from `signature` (sig), exactly
    # 32 bytes from `public_key` (pubkey). All buffers are caller-owned
    # for the duration of this synchronous call; AWS-LC retains no
    # pointer past the call.
    #
    # Origin is INFERRED from the input spans — NOT wildcard widening.
    # Message length is passed as `Int` (matches `size_t` ABI on both
    # macOS-arm64 LP64 + linux-x86_64 LP64).
    var rc = external_call["komira_awslc_ED25519_verify", Int32](
        msg.unsafe_ptr().bitcast[UInt8](),
        Int(len(msg)),
        sig.unsafe_ptr().bitcast[UInt8](),
        pubkey.unsafe_ptr().bitcast[UInt8](),
    )
    return Int(rc) == 1


# -----------------------------------------------------------------------------
# Public wrapper — ed25519_keypair_generate.
#
# Generates a fresh Ed25519 keypair using AWS-LC's CSPRNG (which seeds
# from the OS entropy source — getrandom on Linux, getentropy on macOS).
# Writes the 32-byte secret seed to `seed_out` and the 32-byte public
# key to `pubkey_out`.
# -----------------------------------------------------------------------------


@always_inline
def ed25519_keypair_generate(
    mut seed_out: Array[UInt8, 32],
    mut pubkey_out: Array[UInt8, 32],
):
    """Generate a fresh Ed25519 keypair (seed + pubkey).

    Args:
        seed_out: 32-byte output buffer; filled with the secret seed
            on return.
        pubkey_out: 32-byte output buffer; filled with the derived
            public key on return.

    The seed is sourced from AWS-LC's CSPRNG, which seeds from the OS
    entropy source (getrandom / getentropy). Per RFC 8032 §5.1.5 the
    pubkey is fully determined by the seed.

    Performance: dominated by the CSPRNG draw + one ED25519_keypair_from_seed
    body (one SHA-512 over the seed + a scalar mult to derive the pubkey).
    """
    # AWS-LC's `ED25519_keypair` writes the 32-byte pubkey + 64-byte
    # expanded private key (SEED || PUBKEY). We extract the 32-byte
    # seed from bytes [0:32] of the expanded private key and discard
    # bytes [32:64] (which duplicate the pubkey already written).
    var expanded_priv = Array[UInt8, 64](fill=UInt8(0))

    # SAFETY: AWS-LC's `ED25519_keypair` writes exactly 32 bytes to
    # `out_public_key` (pubkey_out) and exactly 64 bytes to
    # `out_private_key` (expanded_priv). Both buffers are caller-owned
    # for the duration of this synchronous call; AWS-LC retains no
    # pointer past the call. The CSPRNG side-effect is internal to
    # AWS-LC (mutation of a thread-local DRBG state); no caller-visible
    # state escapes.
    external_call["komira_awslc_ED25519_keypair", NoneType](
        UnsafePointer(to=pubkey_out[0]).bitcast[UInt8](),
        UnsafePointer(to=expanded_priv[0]).bitcast[UInt8](),
    )

    # Extract the 32-byte seed from the expanded private key (bytes [0:32]
    # per the RFC 8032 §5.1.5 layout that AWS-LC's `ED25519_keypair_from_seed`
    # also produces).
    for i in range(32):
        seed_out[i] = expanded_priv[i]
