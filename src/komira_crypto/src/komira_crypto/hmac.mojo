# =============================================================================
# komira_crypto/hmac.mojo — HMAC-SHA256 one-shot public surface (THIN WRAPPER)
# =============================================================================
#
# One-shot HMAC-SHA256 wrappers delegated to AWS-LC's HMAC() symbol via
# hmac_oneshot[32]. constant_time_eq_32 is native (a pure-Mojo branch-free
# OR-fold; AWS-LC's CRYPTO_memcmp would be a substitute but adds nothing).
#
# Public surface:
#   * hmac_sha256(key, data) -> InlineArray[UInt8, 32]
#   * hmac_sha256_string(key, data: String) -> InlineArray[UInt8, 32]
#   * constant_time_eq_32(a, b) -> Bool
# =============================================================================

from komira_crypto.internal.asm.hmac_ffi import hmac_oneshot


def hmac_sha256(
    key: Span[UInt8, _], data: Span[UInt8, _]
) -> Array[UInt8, 32]:
    """HMAC-SHA256(key, data) per RFC 2104 + FIPS 198-1 via AWS-LC.

    Key handling per RFC 2104 §2 (delegated to AWS-LC's HMAC_Init_ex):
      * if len(key) > 64 (block size): K' = SHA256(K)
      * if len(key) < 64:              K' = K || 0x00...
      * else:                          K' = K
    """
    return hmac_oneshot[32](key, data)


def hmac_sha256_string(
    key: Span[UInt8, _], data: String
) -> Array[UInt8, 32]:
    """Convenience: HMAC-SHA256 over the UTF-8 bytes of a `String` data."""
    return hmac_sha256(key, data.as_bytes())


def constant_time_eq_32(
    a: Array[UInt8, 32], b: Array[UInt8, 32]
) -> Bool:
    """Constant-time equality for two 32-byte buffers.

    Use this for MAC verification — comparing an attacker-controlled
    tag against a computed reference tag with `a == b` leaks timing
    information (early exit on first-byte mismatch reveals the prefix
    that matched, enabling an iterative attack).

    Implementation: OR-accumulate the XOR of every byte pair; equality
    iff the accumulator is zero. Branch-free, data-oblivious.
    """
    var diff = UInt8(0)
    for i in range(32):
        diff = diff | (a[i] ^ b[i])
    return diff == UInt8(0)
