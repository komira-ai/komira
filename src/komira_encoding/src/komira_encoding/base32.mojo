# =============================================================================
# komira_encoding/base32.mojo -- base32 (RFC 4648 section 6).
# =============================================================================
#
# Alphabet `A-Z 2-7`. Encoding emits upper case, unpadded by default (the
# otpauth:// secret convention TOTP provisioning uses) or padded on request.
# Decoding accepts either case and either padded or unpadded input; padding,
# when present, must be complete. Strict otherwise (see the package header).
# =============================================================================

from .codec import SCHEME_BASE32, decode, encode


def base32_encode(data: Span[UInt8, _]) -> String:
    """Base32, upper case, padded with `=` to a multiple of 8."""
    return encode(SCHEME_BASE32, data, True)


def base32_encode_nopad(data: Span[UInt8, _]) -> String:
    """Base32, upper case, without padding."""
    return encode(SCHEME_BASE32, data, False)


def base32_decode(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Base32 in either case, padded or unpadded."""
    return decode(SCHEME_BASE32, data, True, True, "base32_decode")


def base32_decode(s: String) raises -> List[UInt8]:
    """`base32_decode` over the bytes of `s`."""
    return base32_decode(s.as_bytes())
