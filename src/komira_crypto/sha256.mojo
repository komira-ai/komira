# =============================================================================
# komira_crypto/sha256.mojo — SHA-256 one-shot public surface (THIN WRAPPER)
# =============================================================================
#
# One-shot SHA-256 free function delegated to AWS-LC's SHA256() symbol via
# sha2_oneshot[32].
#
# Public surface:
#   * sha256(data) -> InlineArray[UInt8, 32]
#   * sha256_string(s) -> InlineArray[UInt8, 32]
# =============================================================================

from komira_crypto.internal.asm.sha256_ffi import sha2_oneshot


def sha256(data: Span[UInt8, _]) -> Array[UInt8, 32]:
    """SHA-256 digest of `data` via AWS-LC's SHA256() symbol.

    Empty input yields the well-known `e3b0c4...7852b855` constant
    (load-bearing for the SigV4 read-path payload-hash placeholder).
    """
    return sha2_oneshot[32](data)


def sha256_string(s: String) -> Array[UInt8, 32]:
    """Convenience: SHA-256 over the UTF-8 bytes of `s`."""
    return sha256(s.as_bytes())
