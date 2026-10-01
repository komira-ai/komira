# =============================================================================
# komira_encoding/codec.mojo -- the one bit-packing engine every scheme uses.
# =============================================================================
#
# An encoding of width `w` (6 for base64, 5 for base32, 4 for hex) packs the
# input bytes MSB-first into a bitstream and maps each `w`-bit group to one
# symbol; decoding runs the same stream backwards.
#
# CONSTANT TIME. Symbol <-> value mapping is arithmetic (constant_time.mojo):
# there is no alphabet table to index, so no memory address depends on the
# data. The decode loop runs over every symbol whatever it holds; an invalid
# byte is not a branch but a bit that is OR-ed into an accumulator, together
# with the position of the first one (selected by mask). The single branch on
# the result comes after the loop. Branches that remain depend only on PUBLIC
# facts: the input length, the scheme, and how many trailing `=` the input
# carries (for valid input that is fixed by the length, and the decoded
# length is visible to the caller anyway). Whether the input was valid, and
# where its first bad byte is, is reported (and therefore not secret).
# =============================================================================

from .constant_time import (
    ct_eq,
    ct_in_range,
    ct_lt,
    ct_select,
    ct_select_u64,
)
from .errors import (
    INVALID_CHARACTER,
    INVALID_LENGTH,
    INVALID_PADDING,
    NON_CANONICAL,
    encoding_error,
)

comptime SCHEME_BASE64 = 0
comptime SCHEME_BASE64URL = 1
comptime SCHEME_BASE32 = 2
comptime SCHEME_HEX = 3

comptime _PAD = UInt8(ord("="))
comptime _INVALID = UInt32(0x100)


@always_inline
def _width(scheme: Int) -> Int:
    if scheme == SCHEME_HEX:
        return 4
    if scheme == SCHEME_BASE32:
        return 5
    return 6


@always_inline
def _block(scheme: Int) -> Int:
    """Symbols per padded block."""
    if scheme == SCHEME_HEX:
        return 2
    if scheme == SCHEME_BASE32:
        return 8
    return 4


@always_inline
def _sym62(scheme: Int) -> UInt32:
    return UInt32(ord("+")) if scheme == SCHEME_BASE64 else UInt32(ord("-"))


@always_inline
def _sym63(scheme: Int) -> UInt32:
    return UInt32(ord("/")) if scheme == SCHEME_BASE64 else UInt32(ord("_"))


@always_inline
def symbol_of(scheme: Int, v: UInt32) -> UInt8:
    """The symbol for value `v` (`0 <= v < 2^width`), computed without a
    table lookup or a data-dependent branch."""
    if scheme == SCHEME_HEX:
        return UInt8(ct_select(ct_lt(v, 10), v + 48, v + 87))  # 0-9, a-f
    if scheme == SCHEME_BASE32:
        return UInt8(ct_select(ct_lt(v, 26), v + 65, v + 24))  # A-Z, 2-7
    var r = ct_select(ct_eq(v, 62), _sym62(scheme), _sym63(scheme))
    r = ct_select(ct_lt(v, 62), v - 4, r)  # 0-9
    r = ct_select(ct_lt(v, 52), v + 71, r)  # a-z
    r = ct_select(ct_lt(v, 26), v + 65, r)  # A-Z
    return UInt8(r)


@always_inline
def value_of(scheme: Int, c: UInt8) -> UInt32:
    """The value of symbol `c`, with bit 8 set when `c` is not in the
    alphabet; computed without a table lookup or a data-dependent branch."""
    var x = UInt32(c)
    var v = _INVALID
    if scheme == SCHEME_HEX:
        v = ct_select(ct_in_range(x, 48, 57), x - 48, v)  # 0-9
        v = ct_select(ct_in_range(x, 97, 102), x - 87, v)  # a-f
        v = ct_select(ct_in_range(x, 65, 70), x - 55, v)  # A-F
    elif scheme == SCHEME_BASE32:
        v = ct_select(ct_in_range(x, 65, 90), x - 65, v)  # A-Z
        v = ct_select(ct_in_range(x, 97, 122), x - 97, v)  # a-z
        v = ct_select(ct_in_range(x, 50, 55), x - 24, v)  # 2-7
    else:
        v = ct_select(ct_in_range(x, 65, 90), x - 65, v)  # A-Z
        v = ct_select(ct_in_range(x, 97, 122), x - 71, v)  # a-z
        v = ct_select(ct_in_range(x, 48, 57), x + 4, v)  # 0-9
        v = ct_select(ct_eq(x, _sym62(scheme)), 62, v)
        v = ct_select(ct_eq(x, _sym63(scheme)), 63, v)
    return v


def encode(scheme: Int, data: Span[UInt8, _], pad: Bool) -> String:
    """Encode `data`; with `pad`, append `=` to a whole block."""
    var w = _width(scheme)
    var n = len(data)
    var symbols = (n * 8 + w - 1) // w
    var total = symbols
    if pad:
        var blk = _block(scheme)
        total = (symbols + blk - 1) // blk * blk
    var out = List[UInt8](capacity=total)
    var mask = UInt32((1 << w) - 1)
    var buf: UInt32 = 0
    var nb = 0
    for i in range(n):
        buf = ((buf << 8) | UInt32(data[i])) & UInt32(0xFFFF)
        nb += 8
        while nb >= w:
            nb -= w
            out.append(symbol_of(scheme, (buf >> UInt32(nb)) & mask))
    if nb > 0:
        out.append(symbol_of(scheme, (buf << UInt32(w - nb)) & mask))
    while len(out) < total:
        out.append(_PAD)
    return String(unsafe_from_utf8=Span(out))


def decode(
    scheme: Int,
    src: Span[UInt8, _],
    allow_padded: Bool,
    allow_unpadded: Bool,
    function: StaticString,
) raises -> List[UInt8]:
    """Decode `src`, strictly. See the package header for the rules."""
    var n = len(src)
    var w = _width(scheme)
    var blk = _block(scheme)

    # Trailing padding. Hex has none, so `=` there is an ordinary bad byte.
    var t = 0
    if scheme != SCHEME_HEX:
        while t < n and src[n - 1 - t] == _PAD:
            t += 1
    var body = n - t

    var out = List[UInt8](capacity=body * w // 8)
    var mask = UInt32((1 << w) - 1)
    var buf: UInt32 = 0
    var nb = 0
    var bad_any: UInt64 = 0
    var first_bad: UInt64 = 0
    for i in range(body):
        var r = value_of(scheme, src[i])
        var bad = UInt64(0) - UInt64((r >> 8) & 1)
        first_bad = ct_select_u64(bad & ~bad_any, UInt64(i), first_bad)
        bad_any |= bad
        buf = ((buf << UInt32(w)) | (r & mask)) & UInt32(0xFFFF)
        nb += w
        if nb >= 8:
            nb -= 8
            out.append(UInt8((buf >> UInt32(nb)) & 0xFF))
    # RFC 4648 section 3.5: the unused low bits of the last symbol must be 0.
    var tail_nonzero = ~ct_eq(buf & UInt32((1 << nb) - 1), 0)

    # The branches on the data are the two verdicts: every byte in the
    # alphabet (here), and zero unused bits (last). Bad bytes come first
    # so that a stray byte (a newline, say) is reported
    # as itself rather than as the length it happens to produce.
    if bad_any != 0:
        raise encoding_error(
            INVALID_CHARACTER,
            function,
            "byte is not in the alphabet",
            Int(first_bad),
        )

    # Length and padding: public facts.
    var leftover = (body * w) % 8  # bits of the last symbol that are unused
    if t > 0:
        if not allow_padded:
            raise encoding_error(
                INVALID_PADDING, function, "padding is not allowed", body
            )
        if n % blk != 0 or t >= blk or leftover >= w:
            raise encoding_error(
                INVALID_PADDING, function, "padding has the wrong length", body
            )
    else:
        if leftover >= w:
            raise encoding_error(
                INVALID_LENGTH,
                function,
                "no input encodes to this many symbols",
                n,
            )
        if not allow_unpadded and n % blk != 0:
            raise encoding_error(
                INVALID_PADDING, function, "padding is missing", n
            )

    if tail_nonzero != 0:
        raise encoding_error(
            NON_CANONICAL,
            function,
            "unused bits of the last symbol are not zero",
            body - 1,
        )
    return out^
