# =============================================================================
# src/kci_pkg_upload/wire.mojo — byte helpers the registry clients
#   share: building a body, searching one, and decoding a response as UTF-8
#   only after checking that it is.
# =============================================================================
#
# Encapsulation: owned values and `Span` views; no pointer, no
# wildcard origin.
# =============================================================================


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    out.extend(s.as_bytes())
    return out^


def append_str(mut out: List[UInt8], s: String):
    out.extend(s.as_bytes())


def bytes_find(hay: Span[UInt8, _], needle: String, start: Int = 0) -> Int:
    """The first offset >= `start` of `needle` in `hay`, or -1."""
    var nb = needle.as_bytes()
    var m = len(nb)
    var n = len(hay)
    if m == 0:
        return start if start <= n else -1
    var first = nb[0]
    var i = start
    while i + m <= n:
        if hay[i] == first:
            var ok = True
            for j in range(1, m):
                if hay[i + j] != nb[j]:
                    ok = False
                    break
            if ok:
                return i
        i += 1
    return -1


def bytes_contain(hay: Span[UInt8, _], needle: String) -> Bool:
    return bytes_find(hay, needle) >= 0


def is_valid_utf8(b: Span[UInt8, _]) -> Bool:
    """RFC 3629 well-formedness: no overlong forms, no surrogates, nothing
    above U+10FFFF, no truncated sequence."""
    var i = 0
    var n = len(b)
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        if c < 0xC2 or c > 0xF4:
            return False  # a continuation byte, an overlong lead, or > U+10FFFF
        var need = 1
        var lo = 0x80
        var hi = 0xBF
        if c == 0xE0:
            need = 2
            lo = 0xA0
        elif c == 0xED:
            need = 2
            hi = 0x9F  # no UTF-16 surrogates
        elif c >= 0xE1 and c <= 0xEF:
            need = 2
        elif c == 0xF0:
            need = 3
            lo = 0x90
        elif c == 0xF4:
            need = 3
            hi = 0x8F
        elif c >= 0xF1 and c <= 0xF3:
            need = 3
        if i + need >= n:  # the sequence needs bytes i+1 .. i+need
            return False
        var c1 = Int(b[i + 1])
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = Int(b[i + k])
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def decode_utf8(b: Span[UInt8, _], what: String) raises -> String:
    """`b` as a String, or RAISE naming `what` when it is not UTF-8."""
    if not is_valid_utf8(b):
        raise Error(what + String(" is not valid UTF-8"))
    return String(unsafe_from_utf8=b)
