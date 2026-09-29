# =============================================================================
# komira_crypto/base64.mojo — base64 (std + URL-safe + no-pad) via AWS-LC FFI
# =============================================================================
#
# Thin re-exports of the FFI shims in internal/asm/base64_ffi.mojo.
#
# Public surface:
# Public surface preserved:
#   * base64_encode(data) -> String                  (RFC 4648 §4, padded)
#   * base64_url_encode(data) -> String              (RFC 4648 §5, padded)
#   * base64_url_encode_nopad(data) -> String        (RFC 7515 §2 base64url)
#   * base64_decode(s) raises -> List[UInt8]         (RFC 4648 §4)
#   * base64_url_decode(s) raises -> List[UInt8]     (RFC 4648 §5, tolerates no-pad)
# =============================================================================

from komira_crypto.internal.asm.base64_ffi import (
    base64_encode_std_ffi,
    base64_encode_url_ffi,
    base64_decode_std_ffi,
    base64_decode_url_ffi,
)


def base64_encode(data: Span[UInt8, _]) -> String:
    """RFC 4648 §4 standard base64 encoding, padded."""
    return base64_encode_std_ffi(data)


def base64_url_encode(data: Span[UInt8, _]) -> String:
    """RFC 4648 §5 URL-safe base64, padded (`-` / `_` substituted)."""
    return base64_encode_url_ffi(data, True)


def base64_url_encode_nopad(data: Span[UInt8, _]) -> String:
    """RFC 7515 §2 `base64url` — URL-safe base64 WITHOUT padding.

    The canonical JWT encoding (e.g. the header / claims / signature
    segments of a GCS OAuth service-account JWT).
    """
    return base64_encode_url_ffi(data, False)


def base64_decode(s: String) raises -> List[UInt8]:
    """RFC 4648 §4 standard base64 decode. Raises on malformed input."""
    return base64_decode_std_ffi(s)


def base64_url_decode(s: String) raises -> List[UInt8]:
    """RFC 4648 §5 URL-safe base64 decode. Tolerates absent padding
    (RFC 7515 §2 base64url-nopad)."""
    return base64_decode_url_ffi(s)
