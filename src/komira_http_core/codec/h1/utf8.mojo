# =============================================================================
# src/komira_http_core/codec/h1/utf8.mojo — UTF-8 well-formedness check
# =============================================================================
#
# The h1 parser stores a header field value as the exact octets the client
# sent (RFC 9110 §5.5: obs-text is opaque data) when it can. The header map
# holds `String`s, and a `String` must be well-formed UTF-8, so the parser
# checks a value with `utf8_error_offset` before it builds the `String` from
# its bytes. A value that fails is still served, re-encoded one code point per
# octet.
# =============================================================================


def utf8_error_offset(buf: Span[UInt8, _], start: Int, end_excl: Int) -> Int:
    """Offset of the first byte of the first ill-formed UTF-8 sequence in
    `buf[start:end_excl]`, or -1 if the range is well-formed.

    Well-formed sequences are those of the Unicode Standard, Table 3-7:

        00..7F
        C2..DF  80..BF
        E0      A0..BF  80..BF
        E1..EC  80..BF  80..BF
        ED      80..9F  80..BF
        EE..EF  80..BF  80..BF
        F0      90..BF  80..BF  80..BF
        F1..F3  80..BF  80..BF  80..BF
        F4      80..8F  80..BF  80..BF

    A sequence cut short by `end_excl` is ill-formed: no byte at or past
    `end_excl` is read.
    """
    var i = start
    while i < end_excl:
        var b0 = Int(buf[i])
        if b0 < 0x80:
            i = i + 1
            continue
        var trail = 0
        var lo = 0x80
        var hi = 0xBF
        if b0 >= 0xC2 and b0 <= 0xDF:
            trail = 1
        elif b0 >= 0xE0 and b0 <= 0xEF:
            trail = 2
            if b0 == 0xE0:
                lo = 0xA0
            elif b0 == 0xED:
                hi = 0x9F
        elif b0 >= 0xF0 and b0 <= 0xF4:
            trail = 3
            if b0 == 0xF0:
                lo = 0x90
            elif b0 == 0xF4:
                hi = 0x8F
        else:
            # 80..C1 (a continuation byte or an overlong lead) or F5..FF.
            return i
        if i + trail >= end_excl:
            return i
        var b1 = Int(buf[i + 1])
        if b1 < lo or b1 > hi:
            return i
        var k = 2
        while k <= trail:
            var c = Int(buf[i + k])
            if c < 0x80 or c > 0xBF:
                return i
            k = k + 1
        i = i + trail + 1
    return -1
