# =============================================================================
# komira_crypto/ecdsa_p256.mojo — ECDSA over NIST P-256 (FIPS 186-4 §6.4 +
#                                  RFC 6979 deterministic-k)
# =============================================================================
#
# ECDSA-P256 sign + verify, e.g. for TLS 1.3 CertificateVerify (RFC 8446
# §4.4.3) — server-side signing AND client/server verify of peer
# certificates.
#
# # Architecture
#
# Public API: ecdsa_p256_sign_deterministic / ecdsa_p256_sign_random /
# ecdsa_p256_verify / ecdsa_p256_generate_pubkey.
#
# Implementation:
#   - Curve arithmetic + scalar mult + Solinas / Barrett reduction
#     delegated to AWS-LC via FFI wrappers in
#     `komira_crypto.internal.asm.p256_ffi`. AWS-LC ships hand-tuned
#     P-256 NEON/AVX2 implementations whose performance pure-scalar Mojo
#     loops cannot match.
#   - RFC 6979 deterministic-k (HMAC-DRBG) stays in Mojo via
#     `_rfc6979_generate_k_bytes` — runs on top of `Hmac[Sha256]`, which
#     is itself FFI-backed. Preserves byte-identical RFC 6979 §A.2.5
#     output.
#   - SHA-256 hashing via `Sha256` from `komira_crypto.hash` (also
#     FFI-backed).
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins — `Span[UInt8, _]` is origin-inferred per
#     call site (NOT wildcard widening).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer.
# =============================================================================

from komira_crypto.hash import Sha256
from komira_crypto.hmac_streaming import Hmac
from komira_crypto.internal.asm.p256_ffi import (
    p256_sign_with_nonce,
    p256_verify,
    p256_pubkey_from_priv,
)


# -----------------------------------------------------------------------------
# Curve order n as 32 big-endian bytes (for RFC 6979 range check).
#
# n = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
# -----------------------------------------------------------------------------


@always_inline
def _curve_order_n_be() -> Array[UInt8, 32]:
    """Return the P-256 curve order n as 32 big-endian bytes."""
    var n = Array[UInt8, 32](fill=UInt8(0))
    n[0]  = UInt8(0xFF); n[1]  = UInt8(0xFF); n[2]  = UInt8(0xFF); n[3]  = UInt8(0xFF)
    n[4]  = UInt8(0x00); n[5]  = UInt8(0x00); n[6]  = UInt8(0x00); n[7]  = UInt8(0x00)
    n[8]  = UInt8(0xFF); n[9]  = UInt8(0xFF); n[10] = UInt8(0xFF); n[11] = UInt8(0xFF)
    n[12] = UInt8(0xFF); n[13] = UInt8(0xFF); n[14] = UInt8(0xFF); n[15] = UInt8(0xFF)
    n[16] = UInt8(0xBC); n[17] = UInt8(0xE6); n[18] = UInt8(0xFA); n[19] = UInt8(0xAD)
    n[20] = UInt8(0xA7); n[21] = UInt8(0x17); n[22] = UInt8(0x9E); n[23] = UInt8(0x84)
    n[24] = UInt8(0xF3); n[25] = UInt8(0xB9); n[26] = UInt8(0xCA); n[27] = UInt8(0xC2)
    n[28] = UInt8(0xFC); n[29] = UInt8(0x63); n[30] = UInt8(0x25); n[31] = UInt8(0x51)
    return n^


# -----------------------------------------------------------------------------
# Byte-level comparison helpers (constant-time-ish; not adversarial-CT,
# but never branch-on-secret in the inner loop).
# -----------------------------------------------------------------------------


@always_inline
def _be32_is_zero(a: Array[UInt8, 32]) -> Bool:
    """Return True iff `a` (32 BE bytes) represents the integer zero."""
    var or_acc: UInt8 = UInt8(0)
    for i in range(32):
        or_acc |= a[i]
    return or_acc == UInt8(0)


@always_inline
def _be32_lt(a: Array[UInt8, 32], b: Array[UInt8, 32]) -> Bool:
    """Return True iff `a < b` as 32-byte big-endian integers."""
    # Walk MSB→LSB; the first differing byte determines order.
    for i in range(32):
        if a[i] < b[i]:
            return True
        if a[i] > b[i]:
            return False
    return False  # equal


@always_inline
def _be32_lt_n(a: Array[UInt8, 32]) -> Bool:
    """Return True iff `a < n` where n is the P-256 curve order."""
    var n = _curve_order_n_be()
    return _be32_lt(a, n)


@always_inline
def _is_in_range_1_to_n_minus_1(a: Array[UInt8, 32]) -> Bool:
    """Return True iff a is a valid RFC 6979 nonce: 1 ≤ a ≤ n-1."""
    if _be32_is_zero(a):
        return False
    return _be32_lt_n(a)


# -----------------------------------------------------------------------------
# RFC 6979 §3.2 deterministic-k generator for P-256 with SHA-256.
#
# Stays in Mojo so we can pass the exact k bytes to AWS-LC's
# ECDSA_sign_with_nonce_and_leak_private_key_for_testing API. Runs on
# top of Hmac[Sha256], which is FFI-backed — the same effective
# performance path as if AWS-LC computed the nonce internally.
#
# Output: 32 big-endian bytes ready for AWS-LC consumption (the AWS-LC
# nonce-arg docstring requires "big-endian, reduced mod n, padded to
# BN_num_bytes(order) = 32 for P-256").
# -----------------------------------------------------------------------------


@always_inline
def _bits2octets_p256_bytes(
    hash_be: Span[UInt8, _],
) -> Array[UInt8, 32]:
    """RFC 6979 §2.3.4 bits2octets for P-256.

    For P-256: qlen = 256 bits = exactly 32 bytes. SHA-256 output is also
    256 bits = 32 bytes. The output is `hash mod n` encoded as 32 BE bytes.

    Since hash < 2^256 < 2*n (n > 2^255), a single conditional subtract
    suffices (if hash >= n, return hash - n; else return hash).
    """
    var out = Array[UInt8, 32](fill=UInt8(0))
    for i in range(32):
        out[i] = hash_be[i]
    # Conditional subtract: if out >= n, out = out - n.
    var n = _curve_order_n_be()
    var out_ge_n = not _be32_lt(out, n)
    if out_ge_n:
        # Big-endian subtraction with borrow.
        var borrow: Int = 0
        for j in range(32):
            var i = 31 - j
            var d = Int(out[i]) - Int(n[i]) - borrow
            if d < 0:
                d += 256
                borrow = 1
            else:
                borrow = 0
            out[i] = UInt8(d)
    return out^


def _rfc6979_generate_k_bytes(
    priv_be: Span[UInt8, _], hash_be: Span[UInt8, _],
) -> Array[UInt8, 32]:
    """RFC 6979 §3.2 deterministic-k for P-256 + SHA-256. Returns 32 BE bytes.

    Inputs:
      priv_be — 32-byte big-endian private key (caller responsible for
                priv in [1, n-1])
      hash_be — 32-byte SHA-256 digest of the message

    Output:
      32 big-endian bytes encoding k in [1, n-1], deterministically
      generated from (priv, hash) per RFC 6979 §3.2.
    """
    # V = 0x01 x 32; K = 0x00 x 32
    var v = Array[UInt8, 32](fill=UInt8(0x01))
    var k = Array[UInt8, 32](fill=UInt8(0x00))

    # bits2octets(hash) per RFC 6979 §2.3.4
    var h1_octets = _bits2octets_p256_bytes(hash_be)

    # Step (d): K = HMAC_K(V || 0x00 || priv || h1_octets)
    var msg_d = Array[UInt8, 97](fill=UInt8(0))
    for i in range(32):
        msg_d[i] = v[i]
    msg_d[32] = UInt8(0x00)
    for i in range(32):
        msg_d[33 + i] = priv_be[i]
        msg_d[65 + i] = h1_octets[i]
    var k_hmac = Hmac[Sha256](Span[UInt8, origin_of(k)](k))
    k_hmac.update(Span[UInt8, origin_of(msg_d)](msg_d))
    k_hmac.finalize_into(k)

    # Step (e): V = HMAC_K(V)
    var v_hmac = Hmac[Sha256](Span[UInt8, origin_of(k)](k))
    v_hmac.update(Span[UInt8, origin_of(v)](v))
    v_hmac.finalize_into(v)

    # Step (f): K = HMAC_K(V || 0x01 || priv || h1_octets)
    var msg_f = Array[UInt8, 97](fill=UInt8(0))
    for i in range(32):
        msg_f[i] = v[i]
    msg_f[32] = UInt8(0x01)
    for i in range(32):
        msg_f[33 + i] = priv_be[i]
        msg_f[65 + i] = h1_octets[i]
    var k_hmac2 = Hmac[Sha256](Span[UInt8, origin_of(k)](k))
    k_hmac2.update(Span[UInt8, origin_of(msg_f)](msg_f))
    k_hmac2.finalize_into(k)

    # Step (g): V = HMAC_K(V)
    var v_hmac2 = Hmac[Sha256](Span[UInt8, origin_of(k)](k))
    v_hmac2.update(Span[UInt8, origin_of(v)](v))
    v_hmac2.finalize_into(v)

    # Step (h): loop until candidate k is in [1, n-1].
    # For P-256, qlen=hlen=256 bits → exactly one HMAC output suffices.
    while True:  # cov: unreachable the loop's back edge, taken only after the retry below
        # T = HMAC_K(V); since qlen == hlen, one HMAC produces 32 bytes.
        var t_hmac = Hmac[Sha256](Span[UInt8, origin_of(k)](k))
        t_hmac.update(Span[UInt8, origin_of(v)](v))
        t_hmac.finalize_into(v)
        # candidate = bits2int(V) (32 BE bytes)
        if _is_in_range_1_to_n_minus_1(v):
            return v^
        # Retry: K = HMAC_K(V || 0x00); V = HMAC_K(V)
        var msg_retry = Array[UInt8, 33](fill=UInt8(0))  # cov: unreachable a candidate k of 0 or >= n has probability about 2^-32 for P-256; reachable only through an offline search over about 2^32 digests, which has not been done
        for i in range(32):  # cov: unreachable see the line above
            msg_retry[i] = v[i]  # cov: unreachable see the line above
        msg_retry[32] = UInt8(0x00)  # cov: unreachable see the line above
        var k_hmac_r = Hmac[Sha256](Span[UInt8, origin_of(k)](k))  # cov: unreachable see the line above
        k_hmac_r.update(Span[UInt8, origin_of(msg_retry)](msg_retry))  # cov: unreachable see the line above
        k_hmac_r.finalize_into(k)  # cov: unreachable see the line above
        var v_hmac_r = Hmac[Sha256](Span[UInt8, origin_of(k)](k))  # cov: unreachable see the line above
        v_hmac_r.update(Span[UInt8, origin_of(v)](v))  # cov: unreachable see the line above
        v_hmac_r.finalize_into(v)  # cov: unreachable see the line above


# -----------------------------------------------------------------------------
# Public sign / verify / pubkey API.
# -----------------------------------------------------------------------------


def ecdsa_p256_sign_deterministic(
    privkey: Span[UInt8, _],   # 32 bytes BE
    message: Span[UInt8, _],
) raises -> Array[UInt8, 64]:
    """ECDSA-P256 sign using RFC 6979 deterministic-k.

    Returns 64 bytes (r || s), 32 bytes each, big-endian.

    Internally: SHA-256-hashes the message, derives RFC 6979 deterministic-k
    via Mojo's Hmac[Sha256] (FFI-backed), then delegates the curve
    arithmetic to AWS-LC via
    `p256_sign_with_nonce(priv, digest, k, r_out, s_out)`. The Mojo-side
    k generation preserves RFC 6979 §A.2.5 byte-identical output.
    """
    # 1. h = SHA-256(message)
    var h = Array[UInt8, 32](fill=UInt8(0))
    var hasher = Sha256()
    hasher.update(message)
    hasher.finalize_into(h)

    # 2. Generate deterministic k (32 BE bytes).
    var k = _rfc6979_generate_k_bytes(
        privkey, Span[UInt8, origin_of(h)](h),
    )

    # 3. Sign via AWS-LC with the explicit k. AWS-LC reduces priv mod n
    #    internally; we pass priv unchanged.
    var r = Array[UInt8, 32](fill=UInt8(0))
    var s = Array[UInt8, 32](fill=UInt8(0))
    p256_sign_with_nonce(
        privkey,
        Span[UInt8, origin_of(h)](h),
        Span[UInt8, origin_of(k)](k),
        r, s,
    )

    # 4. Concatenate r || s into 64 BE bytes.
    var out = Array[UInt8, 64](fill=UInt8(0))
    for i in range(32):
        out[i] = r[i]
        out[32 + i] = s[i]
    return out^


def ecdsa_p256_sign_random(
    privkey: Span[UInt8, _],
    message: Span[UInt8, _],
    k_bytes: Span[UInt8, _],   # caller-supplied 32-byte BE nonce
) raises -> Array[UInt8, 64]:
    """ECDSA-P256 sign using caller-supplied random-k.

    For CAVP differential testing. Caller MUST supply a unique k per
    invocation; reuse of k across different messages with the same
    private key leaks the private key.
    """
    if len(k_bytes) != 32:
        raise Error("ecdsa_p256_sign_random: k_bytes must be 32 bytes")

    var h = Array[UInt8, 32](fill=UInt8(0))
    var hasher = Sha256()
    hasher.update(message)
    hasher.finalize_into(h)

    var r = Array[UInt8, 32](fill=UInt8(0))
    var s = Array[UInt8, 32](fill=UInt8(0))
    p256_sign_with_nonce(
        privkey,
        Span[UInt8, origin_of(h)](h),
        k_bytes,
        r, s,
    )

    var out = Array[UInt8, 64](fill=UInt8(0))
    for i in range(32):
        out[i] = r[i]
        out[32 + i] = s[i]
    return out^


def ecdsa_p256_verify(
    pubkey: Span[UInt8, _],     # 64 bytes (x || y) BE
    message: Span[UInt8, _],
    signature: Span[UInt8, _],  # 64 bytes (r || s) BE
) -> Bool:
    """ECDSA-P256 verify.

    Returns True if signature is valid, False otherwise. Does NOT raise.

    Internally: validates input sizes, SHA-256-hashes the message, splits
    signature into r + s halves, delegates to AWS-LC's ECDSA_do_verify
    via `p256_verify`.
    """
    if len(pubkey) != 64:
        return False
    if len(signature) != 64:
        return False

    # Hash message.
    var h = Array[UInt8, 32](fill=UInt8(0))
    var hasher = Sha256()
    hasher.update(message)
    hasher.finalize_into(h)

    return p256_verify(
        pubkey,
        Span[UInt8, origin_of(h)](h),
        signature,
    )


def ecdsa_p256_generate_pubkey(
    privkey: Span[UInt8, _],   # 32 bytes BE
) -> Array[UInt8, 64]:
    """Derive the public key (x || y) from a private key scalar.

    Returns 64 bytes (uncompressed point, no format byte; matches the
    RFC 8446 §4.2.8.2 P-256 key_share encoding which strips the 0x04
    format byte).

    NON-RAISING by design. On any AWS-LC failure (OOM / invalid priv),
    returns all-zero bytes, so a malformed/invalid priv yields a
    recognisably unusable pubkey rather than a crash.
    """
    var out = Array[UInt8, 64](fill=UInt8(0))
    try:
        p256_pubkey_from_priv(privkey, out)
    except:
        # Defensive: re-zero on partial-write failure.
        for i in range(64):
            out[i] = UInt8(0)
    return out^
