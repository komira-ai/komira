# =============================================================================
# src/komira_http_core/codec/h2/hpack_huffman.mojo: the RFC 7541 Appendix B
# Huffman code, decode side
# =============================================================================
#
# Appendix B assigns a code to each of the 256 octets and to EOS (symbol 256).
# The code is canonical: sorted by (code length, symbol), each code is the
# previous one plus 1, shifted left when the length grows. So four small
# tables describe it completely, and decoding needs no tree:
#
#   _HUFFMAN_FIRST_CODE[L]  the code of the first symbol whose code is L bits
#   _HUFFMAN_COUNT[L]       how many symbols have an L-bit code
#   _HUFFMAN_OFFSET[L]      where those symbols start in _HUFFMAN_SYMBOLS
#   _HUFFMAN_SYMBOLS        all 257 symbols in canonical order
#
# The tables were generated from the Appendix B text of RFC 7541, after
# checking that every row's code equals the canonical code computed from the
# lengths alone and that the lengths fill the code space exactly (Kraft sum
# 1). Lengths run 5..30; the 30-bit codes are LF, CR, 0x16 and EOS. The
# tests in test_L2_hpack_coverage.mojo decode every octet 0x00..0xff from
# the Appendix B codes as the oracle.
#
# No pointer, no origin: the tables are compile-time constants read through
# `global_constant`.
# =============================================================================

from std.builtin.globals import global_constant


# fmt: off
comptime _HUFFMAN_FIRST_CODE: InlineArray[UInt32, 31] = [
    0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
    0x14, 0x5c, 0xf8, 0x0, 0x3f8, 0x7fa,
    0xffa, 0x1ff8, 0x3ffc, 0x7ffc, 0x0, 0x0,
    0x0, 0x7fff0, 0xfffe6, 0x1fffdc, 0x3fffd2, 0x7fffd8,
    0xffffea, 0x1ffffec, 0x3ffffe0, 0x7ffffde, 0xfffffe2, 0x0,
    0x3ffffffc,
]
comptime _HUFFMAN_COUNT: InlineArray[UInt16, 31] = [
    0, 0, 0, 0, 0, 10, 26, 32, 6, 0, 5, 3, 2, 6, 2, 3,
    0, 0, 0, 3, 8, 13, 26, 29, 12, 4, 15, 19, 29, 0, 4,
]
comptime _HUFFMAN_OFFSET: InlineArray[UInt16, 31] = [
    0, 0, 0, 0, 0, 0, 10, 36, 68, 0, 74, 79, 82, 84, 90, 92,
    0, 0, 0, 95, 98, 106, 119, 145, 174, 186, 190, 205, 224, 0, 253,
]
comptime _HUFFMAN_SYMBOLS: InlineArray[UInt16, 257] = [
    48, 49, 50, 97, 99, 101, 105, 111, 115, 116, 32, 37, 45, 46, 47, 51,
    52, 53, 54, 55, 56, 57, 61, 65, 95, 98, 100, 102, 103, 104, 108, 109,
    110, 112, 114, 117, 58, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76,
    77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 89, 106, 107, 113, 118,
    119, 120, 121, 122, 38, 42, 44, 59, 88, 90, 33, 34, 40, 41, 63, 39,
    43, 124, 35, 62, 0, 36, 64, 91, 93, 126, 94, 125, 60, 96, 123, 92,
    195, 208, 128, 130, 131, 162, 184, 194, 224, 226, 153, 161, 167, 172, 176, 177,
    179, 209, 216, 217, 227, 229, 230, 129, 132, 133, 134, 136, 146, 154, 156, 160,
    163, 164, 169, 170, 173, 178, 181, 185, 186, 187, 189, 190, 196, 198, 228, 232,
    233, 1, 135, 137, 138, 139, 140, 141, 143, 147, 149, 150, 151, 152, 155, 157,
    158, 165, 166, 168, 174, 175, 180, 182, 183, 188, 191, 197, 231, 239, 9, 142,
    144, 145, 148, 159, 171, 206, 215, 225, 236, 237, 199, 207, 234, 235, 192, 193,
    200, 201, 202, 205, 210, 213, 218, 219, 238, 240, 242, 243, 255, 203, 204, 211,
    212, 214, 221, 222, 223, 241, 244, 245, 246, 247, 248, 250, 251, 252, 253, 254,
    2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20,
    21, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127, 220, 249, 10, 13, 22,
    256,
]
# fmt: on


def huffman_decode_octets(
    buf: Span[UInt8, _],
    start: Int,
    length: Int,
) -> Tuple[List[UInt8], Bool]:
    """Decode the `length` Huffman-coded octets at `buf[start:]` (RFC 7541
    §5.2, Appendix B). Returns (octets, ok); ok is False, and the caller
    treats the string as a decoding error, when:

      * the input codes EOS ("A Huffman-encoded string literal containing
        the EOS symbol MUST be treated as a decoding error"), or
      * what is left after the last symbol is longer than 7 bits, or is not
        all 1s (the most significant bits of EOS), which §5.2 makes a
        decoding error too.

    The caller has checked that `start + length <= len(buf)`.
    """
    var out = List[UInt8](capacity=length * 8 // 5 + 1)
    var code = UInt32(0)
    var nbits = 0
    var i = start
    var end = start + length
    while i < end:
        var octet = Int(buf[i])
        var k = 7
        while k >= 0:
            code = (code << 1) | UInt32((octet >> k) & 1)
            nbits += 1
            # Every 30-bit string completes a code (the lengths fill the
            # code space), so `nbits` never passes 30 and the table index
            # stays in range. A length with no codes has count 0 and never
            # matches.
            var first = global_constant[_HUFFMAN_FIRST_CODE]()[nbits]
            var count = UInt32(Int(global_constant[_HUFFMAN_COUNT]()[nbits]))
            if code >= first and code - first < count:
                var at = Int(global_constant[_HUFFMAN_OFFSET]()[nbits]) + Int(
                    code - first
                )
                var symbol = Int(global_constant[_HUFFMAN_SYMBOLS]()[at])
                if symbol == 256:
                    return (List[UInt8](), False)
                out.append(UInt8(symbol))
                code = UInt32(0)
                nbits = 0
            k -= 1
        i += 1
    if nbits > 7:
        return (List[UInt8](), False)
    if code != (UInt32(1) << UInt32(nbits)) - UInt32(1):
        return (List[UInt8](), False)
    return (out^, True)
