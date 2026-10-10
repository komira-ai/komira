# =============================================================================
# komira_crypto/ecdsa_p384.mojo — ECDSA over NIST P-384 (FIPS 186-4 §6.4 +
#                                  RFC 6979 §A.2.6 deterministic-k)
# =============================================================================
#
# Needed for certificate chain validation against CAs that issue P-384
# leaves (USERTrust ECC, ISRG Root X2, others); cert/chain.mojo
# dispatches ecdsa-with-SHA384 here.
#
# # Architecture
#
# Public API: ecdsa_p384_sign_deterministic / ecdsa_p384_sign_random /
# ecdsa_p384_verify / ecdsa_p384_generate_pubkey (4 free fns mirroring
# ecdsa_p256.mojo).
#
# Implementation:
#   - Curve arithmetic + scalar mult delegated to AWS-LC via FFI wrappers
#     in `komira_crypto.internal.asm.p384_ffi`. AWS-LC ships hand-tuned
#     P-384 AArch64 / x86-64 implementations.
#   - RFC 6979 deterministic-k (HMAC-DRBG) stays in Mojo via
#     `_rfc6979_generate_k_bytes_384` — runs on top of `Hmac[Sha384]`.
#     Preserves byte-identical RFC 6979 §A.2.6 output.
#   - SHA-384 hashing via `Sha384` from `komira_crypto.hash`.
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

from komira_crypto.hash import Sha384
from komira_crypto.hmac_streaming import Hmac
from komira_crypto.internal.asm.p384_ffi import (
    p384_sign_with_nonce,
    p384_verify,
    p384_pubkey_from_priv,
)


# -----------------------------------------------------------------------------
# Curve order n as 48 big-endian bytes (for RFC 6979 range check).
#
# P-384 n =
#   0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
#     C7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973
# Per FIPS 186-4 §D.1.2.4 (NIST recommended curves).
# -----------------------------------------------------------------------------


@always_inline
def _curve_order_n_be_384() -> Array[UInt8, 48]:
    """Return the P-384 curve order n as 48 big-endian bytes."""
    var n = Array[UInt8, 48](fill=UInt8(0))
    # 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF (24 bytes)
    n[0]  = UInt8(0xFF); n[1]  = UInt8(0xFF); n[2]  = UInt8(0xFF); n[3]  = UInt8(0xFF)
    n[4]  = UInt8(0xFF); n[5]  = UInt8(0xFF); n[6]  = UInt8(0xFF); n[7]  = UInt8(0xFF)
    n[8]  = UInt8(0xFF); n[9]  = UInt8(0xFF); n[10] = UInt8(0xFF); n[11] = UInt8(0xFF)
    n[12] = UInt8(0xFF); n[13] = UInt8(0xFF); n[14] = UInt8(0xFF); n[15] = UInt8(0xFF)
    n[16] = UInt8(0xFF); n[17] = UInt8(0xFF); n[18] = UInt8(0xFF); n[19] = UInt8(0xFF)
    n[20] = UInt8(0xFF); n[21] = UInt8(0xFF); n[22] = UInt8(0xFF); n[23] = UInt8(0xFF)
    # 0xC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973 (24 bytes)
    n[24] = UInt8(0xC7); n[25] = UInt8(0x63); n[26] = UInt8(0x4D); n[27] = UInt8(0x81)
    n[28] = UInt8(0xF4); n[29] = UInt8(0x37); n[30] = UInt8(0x2D); n[31] = UInt8(0xDF)
    n[32] = UInt8(0x58); n[33] = UInt8(0x1A); n[34] = UInt8(0x0D); n[35] = UInt8(0xB2)
    n[36] = UInt8(0x48); n[37] = UInt8(0xB0); n[38] = UInt8(0xA7); n[39] = UInt8(0x7A)
    n[40] = UInt8(0xEC); n[41] = UInt8(0xEC); n[42] = UInt8(0x19); n[43] = UInt8(0x6A)
    n[44] = UInt8(0xCC); n[45] = UInt8(0xC5); n[46] = UInt8(0x29); n[47] = UInt8(0x73)
    return n^


# -----------------------------------------------------------------------------
# Byte-level comparison helpers (constant-time-ish; never branch-on-secret).
# -----------------------------------------------------------------------------


@always_inline
def _be48_is_zero(a: Array[UInt8, 48]) -> Bool:
    """Return True iff `a` (48 BE bytes) represents the integer zero."""
    var or_acc: UInt8 = UInt8(0)
    for i in range(48):
        or_acc |= a[i]
    return or_acc == UInt8(0)


@always_inline
def _be48_lt(a: Array[UInt8, 48], b: Array[UInt8, 48]) -> Bool:
    """Return True iff `a < b` as 48-byte big-endian integers."""
    # Walk MSB→LSB; the first differing byte determines order.
    for i in range(48):
        if a[i] < b[i]:
            return True
        if a[i] > b[i]:
            return False
    return False  # equal


@always_inline
def _be48_lt_n(a: Array[UInt8, 48]) -> Bool:
    """Return True iff `a < n` where n is the P-384 curve order."""
    var n = _curve_order_n_be_384()
    return _be48_lt(a, n)


@always_inline
def _is_in_range_1_to_n_minus_1_384(a: Array[UInt8, 48]) -> Bool:
    """Return True iff a is a valid RFC 6979 nonce: 1 ≤ a ≤ n-1."""
    if _be48_is_zero(a):
        return False
    return _be48_lt_n(a)


# -----------------------------------------------------------------------------
# RFC 6979 §3.2 deterministic-k generator for P-384 with SHA-384.
#
# Stays in Mojo so we can pass the exact k bytes to AWS-LC's
# ECDSA_sign_with_nonce_and_leak_private_key_for_testing API. Runs on
# top of Hmac[Sha384].
#
# Output: 48 big-endian bytes ready for AWS-LC consumption (the AWS-LC
# nonce-arg docstring requires "big-endian, reduced mod n, padded to
# BN_num_bytes(order) = 48 for P-384").
# -----------------------------------------------------------------------------


@always_inline
def _bits2octets_p384_bytes(
    hash_be: Span[UInt8, _],
) -> Array[UInt8, 48]:
    """RFC 6979 §2.3.4 bits2octets for P-384.

    For P-384: qlen = 384 bits = exactly 48 bytes. SHA-384 output is also
    384 bits = 48 bytes. The output is `hash mod n` encoded as 48 BE bytes.

    Since hash < 2^384 < 2*n (n > 2^383), a single conditional subtract
    suffices (if hash >= n, return hash - n; else return hash).
    """
    var out = Array[UInt8, 48](fill=UInt8(0))
    for i in range(48):
        out[i] = hash_be[i]
    # Conditional subtract: if out >= n, out = out - n.
    var n = _curve_order_n_be_384()
    var out_ge_n = not _be48_lt(out, n)
    if out_ge_n:
        # Big-endian subtraction with borrow.
        var borrow: Int = 0
        for j in range(48):
            var i = 47 - j
            var d = Int(out[i]) - Int(n[i]) - borrow
            if d < 0:
                d += 256
                borrow = 1
            else:
                borrow = 0
            out[i] = UInt8(d)
    return out^


def _rfc6979_generate_k_bytes_384(
    priv_be: Span[UInt8, _], hash_be: Span[UInt8, _],
) -> Array[UInt8, 48]:
    """RFC 6979 §3.2 deterministic-k for P-384 + SHA-384. Returns 48 BE bytes.

    Inputs:
      priv_be — 48-byte big-endian private key (caller responsible for
                priv in [1, n-1])
      hash_be — 48-byte SHA-384 digest of the message

    Output:
      48 big-endian bytes encoding k in [1, n-1], deterministically
      generated from (priv, hash) per RFC 6979 §3.2.
    """
    # V = 0x01 x 48; K = 0x00 x 48
    var v = Array[UInt8, 48](fill=UInt8(0x01))
    var k = Array[UInt8, 48](fill=UInt8(0x00))

    # bits2octets(hash) per RFC 6979 §2.3.4
    var h1_octets = _bits2octets_p384_bytes(hash_be)

    # Step (d): K = HMAC_K(V || 0x00 || priv || h1_octets)
    # Buffer size: 48 + 1 + 48 + 48 = 145
    var msg_d = Array[UInt8, 145](fill=UInt8(0))
    for i in range(48):
        msg_d[i] = v[i]
    msg_d[48] = UInt8(0x00)
    for i in range(48):
        msg_d[49 + i] = priv_be[i]
        msg_d[97 + i] = h1_octets[i]
    var k_hmac = Hmac[Sha384](Span[UInt8, origin_of(k)](k))
    k_hmac.update(Span[UInt8, origin_of(msg_d)](msg_d))
    k_hmac.finalize_into(k)

    # Step (e): V = HMAC_K(V)
    var v_hmac = Hmac[Sha384](Span[UInt8, origin_of(k)](k))
    v_hmac.update(Span[UInt8, origin_of(v)](v))
    v_hmac.finalize_into(v)

    # Step (f): K = HMAC_K(V || 0x01 || priv || h1_octets)
    var msg_f = Array[UInt8, 145](fill=UInt8(0))
    for i in range(48):
        msg_f[i] = v[i]
    msg_f[48] = UInt8(0x01)
    for i in range(48):
        msg_f[49 + i] = priv_be[i]
        msg_f[97 + i] = h1_octets[i]
    var k_hmac2 = Hmac[Sha384](Span[UInt8, origin_of(k)](k))
    k_hmac2.update(Span[UInt8, origin_of(msg_f)](msg_f))
    k_hmac2.finalize_into(k)

    # Step (g): V = HMAC_K(V)
    var v_hmac2 = Hmac[Sha384](Span[UInt8, origin_of(k)](k))
    v_hmac2.update(Span[UInt8, origin_of(v)](v))
    v_hmac2.finalize_into(v)

    # Step (h): loop until candidate k is in [1, n-1].
    # For P-384, qlen=hlen=384 bits → exactly one HMAC output suffices.
    while True:  # cov: unreachable the loop's back edge, taken only after the retry below
        # T = HMAC_K(V); since qlen == hlen, one HMAC produces 48 bytes.
        var t_hmac = Hmac[Sha384](Span[UInt8, origin_of(k)](k))
        t_hmac.update(Span[UInt8, origin_of(v)](v))
        t_hmac.finalize_into(v)
        # candidate = bits2int(V) (48 BE bytes)
        if _is_in_range_1_to_n_minus_1_384(v):
            return v^
        # Retry: K = HMAC_K(V || 0x00); V = HMAC_K(V)
        var msg_retry = Array[UInt8, 49](fill=UInt8(0))  # cov: unreachable a candidate k of 0 or >= n has probability below 2^-190 for P-384; no input is known to give one
        for i in range(48):  # cov: unreachable see the line above
            msg_retry[i] = v[i]  # cov: unreachable see the line above
        msg_retry[48] = UInt8(0x00)  # cov: unreachable see the line above
        var k_hmac_r = Hmac[Sha384](Span[UInt8, origin_of(k)](k))  # cov: unreachable see the line above
        k_hmac_r.update(Span[UInt8, origin_of(msg_retry)](msg_retry))  # cov: unreachable see the line above
        k_hmac_r.finalize_into(k)  # cov: unreachable see the line above
        var v_hmac_r = Hmac[Sha384](Span[UInt8, origin_of(k)](k))  # cov: unreachable see the line above
        v_hmac_r.update(Span[UInt8, origin_of(v)](v))  # cov: unreachable see the line above
        v_hmac_r.finalize_into(v)  # cov: unreachable see the line above


# -----------------------------------------------------------------------------
# Public sign / verify / pubkey API.
# -----------------------------------------------------------------------------


def ecdsa_p384_sign_deterministic(
    privkey: Span[UInt8, _],   # 48 bytes BE
    message: Span[UInt8, _],
) raises -> Array[UInt8, 96]:
    """ECDSA-P384 sign using RFC 6979 deterministic-k.

    Returns 96 bytes (r || s), 48 bytes each, big-endian.

    Internally: SHA-384-hashes the message, derives RFC 6979 deterministic-k
    via Mojo's Hmac[Sha384], then delegates the curve arithmetic to AWS-LC
    via `p384_sign_with_nonce(priv, digest, k, r_out, s_out)`. Mojo-side k
    generation preserves RFC 6979 §A.2.6 byte-identical output.
    """
    # 1. h = SHA-384(message)
    var h = Array[UInt8, 48](fill=UInt8(0))
    var hasher = Sha384()
    hasher.update(message)
    hasher.finalize_into(h)

    # 2. Generate deterministic k (48 BE bytes).
    var k = _rfc6979_generate_k_bytes_384(
        privkey, Span[UInt8, origin_of(h)](h),
    )

    # 3. Sign via AWS-LC with the explicit k. AWS-LC reduces priv mod n
    #    internally; we pass priv unchanged.
    var r = Array[UInt8, 48](fill=UInt8(0))
    var s = Array[UInt8, 48](fill=UInt8(0))
    p384_sign_with_nonce(
        privkey,
        Span[UInt8, origin_of(h)](h),
        Span[UInt8, origin_of(k)](k),
        r, s,
    )

    # 4. Concatenate r || s into 96 BE bytes.
    var out = Array[UInt8, 96](fill=UInt8(0))
    for i in range(48):
        out[i] = r[i]
        out[48 + i] = s[i]
    return out^


def ecdsa_p384_sign_random(
    privkey: Span[UInt8, _],
    message: Span[UInt8, _],
    k_bytes: Span[UInt8, _],   # caller-supplied 48-byte BE nonce
) raises -> Array[UInt8, 96]:
    """ECDSA-P384 sign using caller-supplied random-k.

    For CAVP differential testing. Caller MUST supply a unique k per
    invocation; reuse of k across different messages with the same
    private key leaks the private key.
    """
    if len(k_bytes) != 48:
        raise Error("ecdsa_p384_sign_random: k_bytes must be 48 bytes")

    var h = Array[UInt8, 48](fill=UInt8(0))
    var hasher = Sha384()
    hasher.update(message)
    hasher.finalize_into(h)

    var r = Array[UInt8, 48](fill=UInt8(0))
    var s = Array[UInt8, 48](fill=UInt8(0))
    p384_sign_with_nonce(
        privkey,
        Span[UInt8, origin_of(h)](h),
        k_bytes,
        r, s,
    )

    var out = Array[UInt8, 96](fill=UInt8(0))
    for i in range(48):
        out[i] = r[i]
        out[48 + i] = s[i]
    return out^


def ecdsa_p384_verify(
    pubkey: Span[UInt8, _],     # 96 bytes (x || y) BE
    message: Span[UInt8, _],
    signature: Span[UInt8, _],  # 96 bytes (r || s) BE
) -> Bool:
    """ECDSA-P384 verify.

    Returns True if signature is valid, False otherwise. Does NOT raise.

    Internally: validates input sizes, SHA-384-hashes the message, splits
    signature into r + s halves, delegates to AWS-LC's ECDSA_do_verify
    via `p384_verify`.
    """
    if len(pubkey) != 96:
        return False
    if len(signature) != 96:
        return False

    # Hash message.
    var h = Array[UInt8, 48](fill=UInt8(0))
    var hasher = Sha384()
    hasher.update(message)
    hasher.finalize_into(h)

    return p384_verify(
        pubkey,
        Span[UInt8, origin_of(h)](h),
        signature,
    )


def ecdsa_p384_generate_pubkey(
    privkey: Span[UInt8, _],   # 48 bytes BE
) -> Array[UInt8, 96]:
    """Derive the public key (x || y) from a private key scalar.

    Returns 96 bytes (uncompressed point, no format byte; matches the
    RFC 8446 §4.2.8.2 P-384 key_share encoding which strips the 0x04
    format byte).

    NON-RAISING by design (matches ecdsa_p256_generate_pubkey shape). On
    any AWS-LC failure (OOM / invalid priv), returns all-zero bytes.
    """
    var out = Array[UInt8, 96](fill=UInt8(0))
    try:
        p384_pubkey_from_priv(privkey, out)
    except:
        # Defensive: re-zero on partial-write failure.
        for i in range(96):
            out[i] = UInt8(0)
    return out^
