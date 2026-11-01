# =============================================================================
# komira_encoding/hex.mojo -- hex (RFC 4648 section 8, base16).
# =============================================================================
#
# Encoding emits lower case (what SigV4 and most digest renderings require).
# Decoding accepts either case, needs an even number of digits, and has no
# padding and no separators.
# =============================================================================

from .codec import SCHEME_HEX, decode, encode


def hex_encode(data: Span[UInt8, _]) -> String:
    """Lower-case hex, two digits per byte."""
    return encode(SCHEME_HEX, data, False)


def hex_decode(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Hex in either case."""
    return decode(SCHEME_HEX, data, False, True, "hex_decode")


def hex_decode(s: String) raises -> List[UInt8]:
    """`hex_decode` over the bytes of `s`."""
    return hex_decode(s.as_bytes())
