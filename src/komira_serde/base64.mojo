# =============================================================================
# base64.mojo — RFC 4648 §4 standard base64 (with padding).
# =============================================================================
#
# The proto3 canonical-JSON mapping serializes a `bytes` field as a base64
# string. This is the STANDARD base64 alphabet with `=` padding
# (RFC 4648 §4) — NOT base64url (`+` and `/`, not `-` and `_`). A small,
# self-contained codec, so this package needs no dependency for it.
#
# Encapsulation: pure scalar arithmetic over owned `List[UInt8]` / `String`;
# no pointers, no allocations beyond the owned result.
# =============================================================================


# The standard base64 alphabet (RFC 4648 Table 1).
comptime _B64_ALPHABET = String(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
)
comptime _B64_PAD: UInt8 = 0x3D  # '='


@always_inline
def _b64_char(idx: Int) -> UInt8:
    """The base64 alphabet byte for a 6-bit index `[0, 64)`."""
    return UInt8(ord(_B64_ALPHABET[byte=idx]))


def _b64_decode_char(c: UInt8) raises -> Int:
    """The 6-bit value of a base64 alphabet byte; raises on a non-alphabet
    byte. Padding `=` is handled by the caller (never reaches here)."""
    # 'A'..'Z' -> 0..25
    if c >= 0x41 and c <= 0x5A:
        return Int(c) - 0x41
    # 'a'..'z' -> 26..51
    if c >= 0x61 and c <= 0x7A:
        return Int(c) - 0x61 + 26
    # '0'..'9' -> 52..61
    if c >= 0x30 and c <= 0x39:
        return Int(c) - 0x30 + 52
    if c == 0x2B:  # '+'
        return 62
    if c == 0x2F:  # '/'
        return 63
    raise Error("Base64Error: invalid base64 character")


def base64_encode(data: List[UInt8]) -> String:
    """Encode `data` as a standard-alphabet, `=`-padded base64 string.

    Three input bytes map to four output characters; the final group is
    `=`-padded when the input length is not a multiple of three.
    """
    var out = List[UInt8]()
    var n = len(data)
    var i = 0
    while i + 3 <= n:
        var b0 = Int(data[i])
        var b1 = Int(data[i + 1])
        var b2 = Int(data[i + 2])
        out.append(_b64_char((b0 >> 2) & 0x3F))
        out.append(_b64_char(((b0 << 4) | (b1 >> 4)) & 0x3F))
        out.append(_b64_char(((b1 << 2) | (b2 >> 6)) & 0x3F))
        out.append(_b64_char(b2 & 0x3F))
        i += 3
    var rem = n - i
    if rem == 1:
        var b0 = Int(data[i])
        out.append(_b64_char((b0 >> 2) & 0x3F))
        out.append(_b64_char((b0 << 4) & 0x3F))
        out.append(_B64_PAD)
        out.append(_B64_PAD)
    elif rem == 2:
        var b0 = Int(data[i])
        var b1 = Int(data[i + 1])
        out.append(_b64_char((b0 >> 2) & 0x3F))
        out.append(_b64_char(((b0 << 4) | (b1 >> 4)) & 0x3F))
        out.append(_b64_char((b1 << 2) & 0x3F))
        out.append(_B64_PAD)
    return String(unsafe_from_utf8=Span(out))


def base64_decode(s: String) raises -> List[UInt8]:
    """Decode a standard-alphabet base64 string into owned bytes.

    Raises on a non-alphabet character or an input length that is not a
    multiple of four. An empty string decodes to an empty `List`.
    """
    var out = List[UInt8]()
    var n = s.byte_length()
    if n == 0:
        return out^
    if n % 4 != 0:
        raise Error("Base64Error: input length not a multiple of 4")
    var i = 0
    while i < n:
        var c0 = UInt8(ord(s[byte=i]))
        var c1 = UInt8(ord(s[byte=i + 1]))
        var c2 = UInt8(ord(s[byte=i + 2]))
        var c3 = UInt8(ord(s[byte=i + 3]))
        var v0 = _b64_decode_char(c0)
        var v1 = _b64_decode_char(c1)
        # First output byte is always present.
        out.append(UInt8(((v0 << 2) | (v1 >> 4)) & 0xFF))
        if c2 == _B64_PAD:
            # `XY==` — one output byte; c3 must also be padding.
            if c3 != _B64_PAD:
                raise Error("Base64Error: malformed padding")
        else:
            var v2 = _b64_decode_char(c2)
            out.append(UInt8(((v1 << 4) | (v2 >> 2)) & 0xFF))
            if c3 == _B64_PAD:
                # `XYZ=` — two output bytes.
                pass
            else:
                var v3 = _b64_decode_char(c3)
                out.append(UInt8(((v2 << 6) | v3) & 0xFF))
        i += 4
    return out^
