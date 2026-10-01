# =============================================================================
# komira_gcp_core/utf8.mojo — body bytes to a String, without trusting them.
# =============================================================================
#
# A response body is untrusted bytes. `String(unsafe_from_utf8=...)` is only
# sound for valid UTF-8, so every body is checked first (RFC 3629: no overlong
# forms, no surrogates, nothing above U+10FFFF).
# =============================================================================


def is_valid_utf8(b: List[UInt8]) -> Bool:
    """Whether `b` is well-formed UTF-8 (RFC 3629 §4)."""
    var i = 0
    var n = len(b)
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
                lo = 0xA0
            elif c == 0xED:
                hi = 0x9F
        elif c >= 0xF0 and c <= 0xF4:
            need = 3
            if c == 0xF0:
                lo = 0x90
            elif c == 0xF4:
                hi = 0x8F
        else:
            return False
        if i + need >= n:
            return False
        var first = Int(b[i + 1])
        if first < lo or first > hi:
            return False
        for k in range(2, need + 1):
            var cc = Int(b[i + k])
            if cc < 0x80 or cc > 0xBF:
                return False
        i += need + 1
    return True


def utf8_string(b: List[UInt8]) raises -> String:
    """`b` as a String; raises (naming only the byte count) if it is not
    valid UTF-8."""
    if not is_valid_utf8(b):
        raise Error(String("a ") + String(len(b)) + "-byte body is not valid UTF-8")
    return String(unsafe_from_utf8=Span(b))
