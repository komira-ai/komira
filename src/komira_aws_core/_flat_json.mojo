# =============================================================================
# komira_aws_core/_flat_json.mojo -- the credential endpoints' JSON documents
# =============================================================================
#
# Package-private. The container credentials endpoint and the instance
# metadata service answer with ONE flat JSON object whose values are strings
# (and, from IMDS, nothing else that matters). This reads exactly that: an
# object of string, number, true/false/null members, no nesting. Anything else
# is refused. Errors never quote the document, which holds secrets.
# =============================================================================

from ._text import is_space, sub


struct FlatJson(Movable):
    """The string members of a flat JSON object."""

    var keys: List[String]
    var values: List[String]

    def __init__(out self):
        self.keys = List[String]()
        self.values = List[String]()

    def has(self, key: String) -> Bool:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return True
        return False

    def get(self, key: String) -> String:
        """The member's string value, "" when absent or not a string."""
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return self.values[i]
        return String("")


def _skip(b: Span[UInt8, _], mut i: Int):
    while i < len(b) and is_space(b[i]):
        i += 1


def _hexv(c: UInt8) raises -> Int:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return Int(c) - 0x30
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return Int(c) - 0x61 + 10
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return Int(c) - 0x41 + 10
    raise Error("bad \\u escape")


def _put_utf8(mut out: List[UInt8], cp: Int):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _string(b: Span[UInt8, _], mut i: Int) raises -> String:
    """A JSON string starting at the opening quote at `i`."""
    i += 1
    var out = List[UInt8]()
    while True:
        if i >= len(b):
            raise Error("unterminated string")
        var c = b[i]
        if c == UInt8(0x22):
            i += 1
            break
        if c < UInt8(0x20):
            raise Error("control byte in a string")
        if c != UInt8(0x5C):
            out.append(c)
            i += 1
            continue
        if i + 1 >= len(b):
            raise Error("unterminated escape")
        var e = b[i + 1]
        i += 2
        if e == UInt8(0x22) or e == UInt8(0x5C) or e == UInt8(0x2F):
            out.append(e)
        elif e == UInt8(0x62):
            out.append(UInt8(0x08))
        elif e == UInt8(0x66):
            out.append(UInt8(0x0C))
        elif e == UInt8(0x6E):
            out.append(UInt8(0x0A))
        elif e == UInt8(0x72):
            out.append(UInt8(0x0D))
        elif e == UInt8(0x74):
            out.append(UInt8(0x09))
        elif e == UInt8(0x75):
            if i + 4 > len(b):
                raise Error("short \\u escape")
            var cp = 0
            for k in range(4):
                cp = cp * 16 + _hexv(b[i + k])
            i += 4
            if cp >= 0xD800 and cp < 0xDC00:
                if (
                    i + 6 > len(b)
                    or b[i] != UInt8(0x5C)
                    or b[i + 1] != UInt8(0x75)
                ):
                    raise Error("unpaired surrogate")
                var lo = 0
                for k in range(4):
                    lo = lo * 16 + _hexv(b[i + 2 + k])
                if lo < 0xDC00 or lo >= 0xE000:
                    raise Error("unpaired surrogate")
                i += 6
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            elif cp >= 0xDC00 and cp < 0xE000:
                raise Error("unpaired surrogate")
            _put_utf8(out, cp)
        else:
            raise Error("bad escape")
    return String(unsafe_from_utf8=Span(out))


def _scalar(b: Span[UInt8, _], mut i: Int) raises:
    """Skips a number or true/false/null."""
    var start = i
    while i < len(b):
        var c = b[i]
        if (
            (c >= UInt8(0x30) and c <= UInt8(0x39))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or c == UInt8(0x2D)
            or c == UInt8(0x2B)
            or c == UInt8(0x2E)
            or c == UInt8(0x45)
        ):
            i += 1
        else:
            break
    if i == start:
        raise Error("expected a value")


def parse_flat_json(doc: String) raises -> FlatJson:
    """Parses one flat JSON object. Refuses nesting and trailing text."""
    var b = doc.as_bytes()
    var i = 0
    var out = FlatJson()
    try:
        _skip(b, i)
        if i >= len(b) or b[i] != UInt8(0x7B):
            raise Error("expected '{'")
        i += 1
        _skip(b, i)
        if i < len(b) and b[i] == UInt8(0x7D):
            i += 1
        else:
            while True:
                _skip(b, i)
                if i >= len(b) or b[i] != UInt8(0x22):
                    raise Error("expected a member name")
                var key = _string(b, i)
                _skip(b, i)
                if i >= len(b) or b[i] != UInt8(0x3A):
                    raise Error("expected ':'")
                i += 1
                _skip(b, i)
                if i >= len(b):
                    raise Error("expected a value")
                if b[i] == UInt8(0x22):
                    out.keys.append(key)
                    out.values.append(_string(b, i))
                elif b[i] == UInt8(0x7B) or b[i] == UInt8(0x5B):
                    raise Error("nested value")
                else:
                    _scalar(b, i)
                _skip(b, i)
                if i < len(b) and b[i] == UInt8(0x2C):
                    i += 1
                    continue
                if i < len(b) and b[i] == UInt8(0x7D):
                    i += 1
                    break
                raise Error("expected ',' or '}'")
        _skip(b, i)
        if i != len(b):
            raise Error("text after the object")
    except e:
        raise Error("not a flat JSON object (" + String(e) + ")")
    return out^


def _skip_nested(b: Span[UInt8, _], mut i: Int) raises:
    """Skips one nested object or array starting at `b[i]`, strings
    included. Errors name a position, never the text."""
    var depth = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(0x22):
            _ = _string(b, i)
            continue
        if c == UInt8(0x7B) or c == UInt8(0x5B):
            depth += 1
        elif c == UInt8(0x7D) or c == UInt8(0x5D):
            depth -= 1
            if depth == 0:
                i += 1
                return
        i += 1
    raise Error("unterminated nested value")


def parse_top_level_strings(doc: String) raises -> FlatJson:
    """The top-level string members of one JSON object, skipping nested
    objects and arrays (an AWS error body can carry structured members next
    to `__type` and `message`). Refuses anything that is not one object."""
    var b = doc.as_bytes()
    var i = 0
    var out = FlatJson()
    try:
        _skip(b, i)
        if i >= len(b) or b[i] != UInt8(0x7B):
            raise Error("expected '{'")
        i += 1
        _skip(b, i)
        if i < len(b) and b[i] == UInt8(0x7D):
            i += 1
        else:
            while True:
                _skip(b, i)
                if i >= len(b) or b[i] != UInt8(0x22):
                    raise Error("expected a member name")
                var key = _string(b, i)
                _skip(b, i)
                if i >= len(b) or b[i] != UInt8(0x3A):
                    raise Error("expected ':'")
                i += 1
                _skip(b, i)
                if i >= len(b):
                    raise Error("expected a value")
                if b[i] == UInt8(0x22):
                    out.keys.append(key)
                    out.values.append(_string(b, i))
                elif b[i] == UInt8(0x7B) or b[i] == UInt8(0x5B):
                    _skip_nested(b, i)
                else:
                    _scalar(b, i)
                _skip(b, i)
                if i < len(b) and b[i] == UInt8(0x2C):
                    i += 1
                    continue
                if i < len(b) and b[i] == UInt8(0x7D):
                    i += 1
                    break
                raise Error("expected ',' or '}'")
        _skip(b, i)
        if i != len(b):
            raise Error("text after the object")
    except e:
        raise Error("not a JSON object (" + String(e) + ")")
    return out^
