# =============================================================================
# utf8.mojo -- UTF-8 validation (RFC 3629) and byte-to-String conversion.
# =============================================================================
#
# `utf8_invalid_at` returns the offset of the first octet that does not start
# or continue a well-formed UTF-8 sequence (RFC 3629 §4: no overlong forms, no
# surrogates U+D800..U+DFFF, nothing above U+10FFFF), or -1 when every octet
# is well formed. `string_from_utf8` refuses invalid input with that offset and
# builds the String through the standard library's checked constructor.
# =============================================================================


def utf8_invalid_at(data: Span[UInt8, _]) -> Int:
    """The offset of the first ill-formed octet in `data`, or -1."""
    var n = len(data)
    var i = 0
    while i < n:
        var b0 = Int(data[i])
        if b0 < 0x80:
            i += 1
            continue
        var need: Int
        var lo = 0x80
        var hi = 0xBF
        if b0 >= 0xC2 and b0 <= 0xDF:
            need = 1
        elif b0 == 0xE0:
            need = 2
            lo = 0xA0
        elif b0 >= 0xE1 and b0 <= 0xEC:
            need = 2
        elif b0 == 0xED:
            need = 2
            hi = 0x9F
        elif b0 >= 0xEE and b0 <= 0xEF:
            need = 2
        elif b0 == 0xF0:
            need = 3
            lo = 0x90
        elif b0 >= 0xF1 and b0 <= 0xF3:
            need = 3
        elif b0 == 0xF4:
            need = 3
            hi = 0x8F
        else:
            return i
        if i + need >= n:
            return i
        var b1 = Int(data[i + 1])
        if b1 < lo or b1 > hi:
            return i
        for k in range(2, need + 1):
            var bk = Int(data[i + k])
            if bk < 0x80 or bk > 0xBF:
                return i
        i += need + 1
    return -1


def string_from_utf8(data: Span[UInt8, _]) raises -> String:
    """`data` as a String; raises `invalid UTF-8 at octet <k>` when it is not
    well-formed UTF-8."""
    var bad = utf8_invalid_at(data)
    if bad >= 0:
        raise Error(String("invalid UTF-8 at octet ") + String(bad))
    return String(StringSlice(from_utf8=data))
