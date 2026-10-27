# =============================================================================
# komira_encoding/base64.mojo -- base64 (RFC 4648 section 4) and base64url
# (RFC 4648 section 5; unpadded per RFC 7515 section 2).
# =============================================================================
#
# Encoding always emits canonical output. Decoding is strict (see the package
# header): no whitespace, padding exactly where the variant says, zero unused
# bits, and constant time with respect to the data.
# =============================================================================

from .codec import SCHEME_BASE64, SCHEME_BASE64URL, decode, encode


def base64_encode(data: Span[UInt8, _]) -> String:
    """Standard base64 (alphabet `A-Z a-z 0-9 + /`), padded with `=`."""
    return encode(SCHEME_BASE64, data, True)


def base64_decode(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Standard base64. The input must be padded to a multiple of 4."""
    return decode(SCHEME_BASE64, data, True, False, "base64_decode")


def base64_decode(s: String) raises -> List[UInt8]:
    """`base64_decode` over the bytes of `s`."""
    return base64_decode(s.as_bytes())


def base64_url_encode(data: Span[UInt8, _]) -> String:
    """Base64url (alphabet `A-Z a-z 0-9 - _`), padded with `=`."""
    return encode(SCHEME_BASE64URL, data, True)


def base64_url_encode_nopad(data: Span[UInt8, _]) -> String:
    """Base64url without padding: RFC 7515 section 2 `base64url`, the
    encoding of every JWS / JWT segment."""
    return encode(SCHEME_BASE64URL, data, False)


def base64_url_decode(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Base64url, padded or unpadded. Padding, when present, must be
    complete."""
    return decode(SCHEME_BASE64URL, data, True, True, "base64_url_decode")


def base64_url_decode(s: String) raises -> List[UInt8]:
    """`base64_url_decode` over the bytes of `s`."""
    return base64_url_decode(s.as_bytes())


def base64_url_decode_nopad(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Base64url as RFC 7515 section 2 defines it: padding is rejected."""
    return decode(
        SCHEME_BASE64URL, data, False, True, "base64_url_decode_nopad"
    )


def base64_url_decode_nopad(s: String) raises -> List[UInt8]:
    """`base64_url_decode_nopad` over the bytes of `s`."""
    return base64_url_decode_nopad(s.as_bytes())
