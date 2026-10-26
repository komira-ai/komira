# =============================================================================
# utf8_check -- a strict UTF-8 validator for bytes that become a String.
# =============================================================================
#
# `String(unsafe_from_utf8=...)` trusts its argument. Every place in this
# package that builds a `String` from bytes it did not write itself (a decoded
# manifest name, a JSON escape) checks the bytes here first, so a corrupt input
# is refused instead of becoming a String that holds invalid UTF-8.


def bytes_are_utf8[o: Origin[mut=False]](b: Span[UInt8, o]) -> Bool:
    """True iff `b` is well-formed UTF-8: shortest-form sequences only, no
    surrogates (U+D800..U+DFFF), nothing above U+10FFFF.

    Parameters:
        o: The origin of the borrowed bytes.

    Args:
        b: The bytes to check.

    Returns:
        Whether every byte belongs to a well-formed sequence.
    """
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        var need: Int
        var lo = 0x80
        var hi = 0xBF
        if c >= 0xC2 and c <= 0xDF:
            need = 1
        elif c >= 0xE0 and c <= 0xEF:
            need = 2
            if c == 0xE0:
                lo = 0xA0  # no overlong three-byte form
            elif c == 0xED:
                hi = 0x9F  # no surrogates
        elif c >= 0xF0 and c <= 0xF4:
            need = 3
            if c == 0xF0:
                lo = 0x90  # no overlong four-byte form
            elif c == 0xF4:
                hi = 0x8F  # nothing above U+10FFFF
        else:
            return False
        if i + need >= n:
            return False  # the sequence runs past the end
        var c1 = Int(b[i + 1])
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = Int(b[i + k])
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True
