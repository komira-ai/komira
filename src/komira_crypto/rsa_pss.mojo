# =============================================================================
# komira_crypto/rsa_pss.mojo — RSA-PSS verify-only (RFC 4055 + RFC 8017)
# =============================================================================
#
# Public API for RSA-PSS verify-only (TLS 1.3 cert chain validation +
# X.509 leaf/intermediate certs that use the `rsassaPss` SignatureAlgorithm).
#
# # Architecture
#
# The PSS verify body is delegated to AWS-LC via
# `komira_crypto.internal.asm.rsa_ffi`: a pure-Mojo bigint + modexp +
# EMSA-PSS-VERIFY + MGF1 is correct but orders of magnitude slower than
# AWS-LC's hand-tuned bignum implementation.
#
# Public API:
#   - `RsaPublicKey[N_LIMBS: Int]` — public-key state (modulus + exponent
#     + bit_len). Its field layout is what `cert/chain.mojo` consumes.
#   - `rsa_public_key_from_bytes[N_LIMBS]` — constructor from big-endian
#     modulus bytes + UInt64 exponent.
#   - `rsa_pss_verify[N_LIMBS, H]` — verify entrypoint; hashes message
#     via H internally, then forwards to AWS-LC's RSA_verify_pss_mgf1.
#
# Implementation:
#   - SHA-256 / SHA-384 / SHA-512 hashing via `komira_crypto.hash` (also
#     FFI-backed).
#   - RSA modexp + MGF1 + EMSA-PSS-DECODE + salt-length check + hash
#     compare delegated to AWS-LC's `RSA_verify_pss_mgf1` (single FFI
#     call). See `internal/asm/rsa_ffi.mojo` for the FFI wrapper.
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins in public API (`Span[UInt8, _]` is
#     origin-inferred per call site — NOT wildcard widening).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer.
# =============================================================================

from komira_crypto.hash import Sha256, Sha384, Sha512
from komira_crypto.traits import Hash
from komira_crypto.internal.asm.rsa_ffi import (
    rsa_pss_verify_ffi,
    MD_SHA256,
    MD_SHA384,
    MD_SHA512,
)


# -----------------------------------------------------------------------------
# RsaPublicKey[N_LIMBS] — public-key state
#
# Field layout PRESERVED for ABI compat with `cert/chain.mojo` consumers.
# Limbs are 64-bit little-endian (n_limbs[0] is least-significant);
# `rsa_public_key_from_bytes` is the canonical constructor.
# -----------------------------------------------------------------------------


struct RsaPublicKey[N_LIMBS: Int](Copyable, Movable, Deinitable):
    """RSA public key: modulus n (N_LIMBS limbs) + public exponent e.

    Limbs are 64-bit little-endian (n_limbs[0] is least-significant).
    Public exponent e fits in a UInt64 (typically 65537 per RFC 4055).
    `bit_len` is the actual bit-length of n (2048 / 3072 / 4096 for
    common TLS cert sizes).

    # Why NOT `ImplicitlyCopyable` (Mojo 1.0.0)
    Under 1.0.0 `InlineArray` is no longer `ImplicitlyCopyable`, so a struct
    holding one CANNOT be either -- and the conformance cannot be hand-written
    around. MEASURED: `__copyinit__`, `__copy__`, a `copy()` method and a
    `__init__(out self, other: Self)` were each tried, and all four failed with
    the identical "cannot synthesize implicit copy constructor because field
    'n_limbs' has non-implicitly-copyable type" -- 1.0.0 SYNTHESIZES implicit
    copy and never dispatches to a user hook, so the trait is unsatisfiable
    here by construction.

    `Copyable` is retained and still synthesizes, so copying a key is
    `pk.copy()` -- explicit, which is the right default for a 256-512 byte
    value on the TLS handshake path. The field layout is fixed (see
    §"Round-trip" below).
    """

    var n_limbs: Array[UInt64, Self.N_LIMBS]
    """Modulus n, little-endian 64-bit limbs."""

    var e: UInt64
    """Public exponent. Typically 65537."""

    var bit_len: Int
    """Actual bit-length of n. For 2048-bit RSA = 2048; used to validate
    signature length matches modulus length per RFC 8017 §8.1.2."""

    def __init__(out self):
        """Default constructor: all-zero modulus, e=0, bit_len=0.

        Construct real keys via `rsa_public_key_from_bytes`.
        """
        self.n_limbs = Array[UInt64, Self.N_LIMBS](fill=UInt64(0))
        self.e = UInt64(0)
        self.bit_len = 0


# -----------------------------------------------------------------------------
# Byte / limb helpers (small; no bigint arithmetic)
# -----------------------------------------------------------------------------


@always_inline
def _u64_from_be_bytes(b: Span[UInt8, _], off: Int) -> UInt64:
    """Read an 8-byte big-endian unsigned 64-bit integer from b[off:off+8]."""
    return (
        (UInt64(b[off]) << UInt64(56))
        | (UInt64(b[off + 1]) << UInt64(48))
        | (UInt64(b[off + 2]) << UInt64(40))
        | (UInt64(b[off + 3]) << UInt64(32))
        | (UInt64(b[off + 4]) << UInt64(24))
        | (UInt64(b[off + 5]) << UInt64(16))
        | (UInt64(b[off + 6]) << UInt64(8))
        | UInt64(b[off + 7])
    )


@always_inline
def _u64_to_be_bytes(v: UInt64, mut out: Array[UInt8, 8]):
    """Write a UInt64 as 8 big-endian bytes."""
    out[0] = UInt8((v >> UInt64(56)) & UInt64(0xFF))
    out[1] = UInt8((v >> UInt64(48)) & UInt64(0xFF))
    out[2] = UInt8((v >> UInt64(40)) & UInt64(0xFF))
    out[3] = UInt8((v >> UInt64(32)) & UInt64(0xFF))
    out[4] = UInt8((v >> UInt64(24)) & UInt64(0xFF))
    out[5] = UInt8((v >> UInt64(16)) & UInt64(0xFF))
    out[6] = UInt8((v >> UInt64(8)) & UInt64(0xFF))
    out[7] = UInt8(v & UInt64(0xFF))


@always_inline
def _byte_bit_length(b: UInt8) -> Int:
    """Return the bit-position of the highest set bit of b (0 if b=0;
    1 for b=1; 8 for b=0x80..0xFF)."""
    if b == UInt8(0):
        return 0  # cov: unreachable the only caller passes the first non-zero byte of the modulus
    var bl = 0
    var y = b
    while y > UInt8(0):
        bl += 1
        y = y >> UInt8(1)
    return bl


# -----------------------------------------------------------------------------
# RsaPublicKey construction from big-endian modulus bytes
# -----------------------------------------------------------------------------


def rsa_public_key_from_bytes[N_LIMBS: Int](
    n_be: Span[UInt8, _], e: UInt64
) raises -> RsaPublicKey[N_LIMBS]:
    """Construct an RsaPublicKey from big-endian modulus bytes + UInt64 exponent.

    `n_be` MUST have length exactly `N_LIMBS * 8` bytes. The bytes are
    interpreted big-endian (most-significant byte first, per X.509
    convention).

    Raises Error if n_be has wrong length.
    """
    var expected_len = N_LIMBS * 8
    if len(n_be) != expected_len:
        raise Error("rsa_public_key_from_bytes: n_be length mismatch")

    var pk = RsaPublicKey[N_LIMBS]()
    # Big-endian bytes -> little-endian limbs:
    # n_be[0..7]    is the most-significant 8 bytes -> limbs[N_LIMBS-1]
    # n_be[8..15]   -> limbs[N_LIMBS-2]
    # ...
    # n_be[(N-1)*8 .. N*8 - 1]  -> limbs[0]
    for i in range(N_LIMBS):
        var off = (N_LIMBS - 1 - i) * 8
        pk.n_limbs[i] = _u64_from_be_bytes(n_be, off)

    pk.e = e

    # Compute actual bit-length of n by scanning n_be from MSB until first
    # nonzero byte, then bit-position within that byte.
    var bl = 0
    for i in range(expected_len):
        if n_be[i] != UInt8(0):
            # Byte at offset i is the most-significant nonzero byte.
            # bit_len = 8 * (bytes_remaining - 1) + bit_length(n_be[i])
            #         = 8 * (expected_len - 1 - i) + bit_length(n_be[i])
            bl = 8 * (expected_len - 1 - i) + _byte_bit_length(n_be[i])
            break
    pk.bit_len = bl

    return pk^


# -----------------------------------------------------------------------------
# Round-trip: limbs -> BE bytes (for FFI call into RSA_set0_key)
#
# Round-trip cost is negligible at 256-512 bytes vs ~0.5-15 ms RSA verify
# body. Alternative considered + REJECTED: store BE bytes directly in
# RsaPublicKey — REJECTED because that's a public ABI change for zero
# performance benefit.
#
# Mojo's InlineArray[T, N] requires N at type level, and `@parameter if`
# branches inside a function parametric on a separate N don't narrow the
# parametric N to the literal in the branch. So we keep the loop body
# inline at each `if N_LIMBS == K:` branch site rather than factoring it
# into a generic helper.
# -----------------------------------------------------------------------------


@always_inline
def _write_limb_be(mut out: Array[UInt8, _], be_off: Int, limb: UInt64):
    """Write a UInt64 as 8 big-endian bytes into out[be_off:be_off+8].

    BYTE_LEN of `out` is opaque (inferred from caller); the helper just
    needs ≥ be_off+8 bytes of writable space at the offset.
    """
    out[be_off + 0] = UInt8((limb >> UInt64(56)) & UInt64(0xFF))
    out[be_off + 1] = UInt8((limb >> UInt64(48)) & UInt64(0xFF))
    out[be_off + 2] = UInt8((limb >> UInt64(40)) & UInt64(0xFF))
    out[be_off + 3] = UInt8((limb >> UInt64(32)) & UInt64(0xFF))
    out[be_off + 4] = UInt8((limb >> UInt64(24)) & UInt64(0xFF))
    out[be_off + 5] = UInt8((limb >> UInt64(16)) & UInt64(0xFF))
    out[be_off + 6] = UInt8((limb >> UInt64(8)) & UInt64(0xFF))
    out[be_off + 7] = UInt8(limb & UInt64(0xFF))


# -----------------------------------------------------------------------------
# Hash kind dispatch — comptime branching on the H: Hash trait param
# -----------------------------------------------------------------------------


@always_inline
def _md_kind_for_hash[H: Hash]() -> Int32:
    """Map the H: Hash trait param to the rsa_ffi.MD_* enum.

    Branches on H.OUTPUT_SIZE — the standard hash output sizes are
    unique discriminators (32 = SHA-256, 48 = SHA-384, 64 = SHA-512).
    """
    comptime if H.OUTPUT_SIZE == 32:
        return MD_SHA256
    elif H.OUTPUT_SIZE == 48:
        return MD_SHA384
    elif H.OUTPUT_SIZE == 64:
        return MD_SHA512
    else:
        # Unknown hash; rsa_ffi will reject via md_kind range check.
        return Int32(-1)


# -----------------------------------------------------------------------------
# Public: rsa_pss_verify
# -----------------------------------------------------------------------------


def rsa_pss_verify[N_LIMBS: Int, H: Hash](
    pubkey: RsaPublicKey[N_LIMBS],
    message: Span[UInt8, _],
    signature: Span[UInt8, _],
    s_len: Int,
) -> Bool:
    """RSA-PSS verify per RFC 8017 §8.1.2.

    Returns True iff `signature` is a valid RSA-PSS signature of
    `message` under `pubkey`, with salt of length `s_len` bytes. Does
    NOT raise; structural errors (wrong-length signature, malformed
    encoded message, OOM in the FFI layer) all collapse to False.

    `s_len` is the expected salt length. The TLS 1.3 cert profile
    typically uses `s_len = H.OUTPUT_SIZE` (hash-length-equal salt).
    The caller chooses the salt-length policy.

    Algorithm (delegated to AWS-LC RSA_verify_pss_mgf1):
      1. Hash message via H to get the digest.
      2. Construct AWS-LC RSA handle from (modulus, exponent).
      3. Call RSA_verify_pss_mgf1(rsa, digest, md, mgf1_md=md,
         salt_len, sig).
      4. Return rc == 1.
    """
    var em_len = N_LIMBS * 8
    # RFC 8017 §8.1.2 step 1: signature length MUST equal modulus length.
    if len(signature) != em_len:
        return False

    # Step 1: hash the message.
    var digest = Array[UInt8, H.OUTPUT_SIZE](fill=UInt8(0))
    var hasher = H()
    hasher.update(message)
    hasher.finalize_into(Span[UInt8, origin_of(digest)](digest))

    # md_kind dispatch.
    var md_kind = _md_kind_for_hash[H]()

    # Encode modulus -> BE bytes inline at each N_LIMBS branch (Mojo's
    # InlineArray requires the size at type level, and `@parameter if`
    # branches inside a function parametric on a separate N don't narrow
    # the parametric N to the literal in the branch — so we cannot
    # factor the encode loop into a helper that takes `n_limbs:
    # InlineArray[UInt64, K]` from inside an `if N_LIMBS == K:` branch).
    comptime if N_LIMBS == 32:
        var n_be = Array[UInt8, 256](fill=UInt8(0))
        for i in range(32):
            _write_limb_be(n_be, (32 - 1 - i) * 8, pubkey.n_limbs[i])
        return rsa_pss_verify_ffi(
            Span[UInt8, origin_of(n_be)](n_be),
            pubkey.e,
            Span[UInt8, origin_of(digest)](digest),
            md_kind,
            Int32(s_len),
            signature,
        )
    elif N_LIMBS == 48:
        var n_be = Array[UInt8, 384](fill=UInt8(0))
        for i in range(48):
            _write_limb_be(n_be, (48 - 1 - i) * 8, pubkey.n_limbs[i])
        return rsa_pss_verify_ffi(
            Span[UInt8, origin_of(n_be)](n_be),
            pubkey.e,
            Span[UInt8, origin_of(digest)](digest),
            md_kind,
            Int32(s_len),
            signature,
        )
    elif N_LIMBS == 64:
        var n_be = Array[UInt8, 512](fill=UInt8(0))
        for i in range(64):
            _write_limb_be(n_be, (64 - 1 - i) * 8, pubkey.n_limbs[i])
        return rsa_pss_verify_ffi(
            Span[UInt8, origin_of(n_be)](n_be),
            pubkey.e,
            Span[UInt8, origin_of(digest)](digest),
            md_kind,
            Int32(s_len),
            signature,
        )
    else:
        # Unsupported N_LIMBS — only 32/48/64 (=2048/3072/4096-bit) are
        # in the public RSA cert chain profile. Add another branch here
        # if a future workload needs a different size.
        return False
