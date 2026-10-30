# =============================================================================
# komira_crypto/hex.mojo — lowercase hex encode (signature serialization)
# =============================================================================
#
# SigV4's final signature is the HMAC-SHA256 result hex-encoded LOWERCASE —
# every AWS test vector asserts this.
# =============================================================================


@always_inline
def _hex_digit_lower(v: Int) -> String:
    """Return one lowercase hex digit (0-9, a-f) for v in [0, 16)."""
    if v < 10:
        return chr(0x30 + v)      # '0'..'9'
    return chr(0x61 + v - 10)     # 'a'..'f'


@always_inline
def _hex_digit_upper(v: Int) -> String:
    """Return one uppercase hex digit (0-9, A-F) for v in [0, 16)."""
    if v < 10:
        return chr(0x30 + v)
    return chr(0x41 + v - 10)     # 'A'..'F'


def hex_lower(bytes: Span[UInt8, _]) -> String:
    """Lowercase hex encoding of the byte span (RFC 4648-style, no
    separators). Used by SigV4's signature serialization."""
    var out = String()
    for i in range(len(bytes)):
        var v = Int(bytes[i])
        out += _hex_digit_lower(v >> 4)
        out += _hex_digit_lower(v & 0xF)
    return out^


def hex_lower_array_32(bytes: Array[UInt8, 32]) -> String:
    """Overload for the common SHA-256 / HMAC-SHA256 result."""
    var out = String()
    for i in range(32):
        var v = Int(bytes[i])
        out += _hex_digit_lower(v >> 4)
        out += _hex_digit_lower(v & 0xF)
    return out^


def hex_upper(bytes: Span[UInt8, _]) -> String:
    """Uppercase hex encoding. Used by some Azure paths."""
    var out = String()
    for i in range(len(bytes)):
        var v = Int(bytes[i])
        out += _hex_digit_upper(v >> 4)
        out += _hex_digit_upper(v & 0xF)
    return out^
