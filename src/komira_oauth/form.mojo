# =============================================================================
# komira_oauth/form.mojo: `application/x-www-form-urlencoded` bodies, the
#   encoding of an OAuth token request (RFC 6749 section 4.4.2, appendix B).
# =============================================================================
#
# `FormParams` is a list of name and value pairs in order.
#
# `encode()` writes `name=value` pairs joined by `&`, every byte of a name or
# value kept when it is an RFC 3986 unreserved byte (`A-Z a-z 0-9 - . _ ~`)
# and written `%XX` (upper-case hex) otherwise; a space is `%20`.
#
# `parse_form(body)` reads such a body strictly. It refuses, with a fixed
# `OAuthError: ...` text that holds no byte of the body:
#   * a body longer than `OAUTH_FORM_MAX_BYTES`;
#   * an empty pair (`a=1&&b=2`, or a leading or trailing `&`), a pair with
#     no `=`, an empty name;
#   * a `%` not followed by two hex digits;
#   * a decoded byte outside printable ASCII (0x20 to 0x7E): every value of
#     an OAuth token request (a grant type, a URN, a compact JWS, a URI, a
#     scope) is printable ASCII, so a control byte or UTF-8 is malformed;
#   * a name given twice (RFC 6749 section 3.2: a parameter is sent at most
#     once).
# `+` decodes to a space. The empty body has no pairs.
#
# ENCAPSULATION: `String` in and out. No pointer crosses this file's API.
# =============================================================================

from komira_oauth._text import _refuse


# The longest form body `parse_form` reads, in bytes.
comptime OAUTH_FORM_MAX_BYTES: Int = 65536


def _is_unreserved(c: UInt8) -> Bool:
    return (
        (c >= 0x41 and c <= 0x5A)  # A-Z
        or (c >= 0x61 and c <= 0x7A)  # a-z
        or (c >= 0x30 and c <= 0x39)  # 0-9
        or c == 0x2D  # -
        or c == 0x2E  # .
        or c == 0x5F  # _
        or c == 0x7E  # ~
    )


def _hex_upper(n: UInt8) -> UInt8:
    if n < 10:
        return 0x30 + n
    return 0x41 + n - 10


def _hex_value(c: UInt8) -> Int:
    if c >= 0x30 and c <= 0x39:
        return Int(c) - 0x30
    if c >= 0x41 and c <= 0x46:
        return Int(c) - 0x41 + 10
    if c >= 0x61 and c <= 0x66:
        return Int(c) - 0x61 + 10
    return -1


def _encode_into(mut buf: List[UInt8], s: String):
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if _is_unreserved(c):
            buf.append(c)
        else:
            buf.append(0x25)  # '%'
            buf.append(_hex_upper(c >> 4))
            buf.append(_hex_upper(c & 0x0F))


def form_encode_value(s: String) -> String:
    """`s` percent-encoded as `encode()` writes a name or a value."""
    var buf = List[UInt8]()
    _encode_into(buf, s)
    return String(unsafe_from_utf8=Span(buf))


def _decode(b: Span[UInt8, _], start: Int, end: Int) raises -> String:
    var out = List[UInt8]()
    var i = start
    while i < end:
        var c = b[i]
        if c == 0x25:  # '%'
            if i + 2 >= end:
                _refuse("the form has a % without two hex digits")
            var hi = _hex_value(b[i + 1])
            var lo = _hex_value(b[i + 2])
            if hi < 0 or lo < 0:
                _refuse("the form has a % without two hex digits")
            c = UInt8(hi * 16 + lo)
            i += 3
        elif c == 0x2B:  # '+'
            c = 0x20
            i += 1
        else:
            i += 1
        if c < 0x20 or c > 0x7E:
            _refuse("the form holds a byte that is not printable ASCII")
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


struct FormParams(Copyable, Movable, Sized):
    """Form parameters in order (see the file header)."""

    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()

    def __len__(self) -> Int:
        return len(self.names)

    def add(mut self, name: String, value: String):
        """Append one pair."""
        self.names.append(name.copy())
        self.values.append(value.copy())

    def get(self, name: String) -> Optional[String]:
        """The value of the first pair named `name`, if any."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return Optional[String](self.values[i].copy())
        return Optional[String]()

    def encode(self) -> String:
        """The `application/x-www-form-urlencoded` body (see the file
        header)."""
        var buf = List[UInt8]()
        for i in range(len(self.names)):
            if i > 0:
                buf.append(0x26)  # '&'
            _encode_into(buf, self.names[i])
            buf.append(0x3D)  # '='
            _encode_into(buf, self.values[i])
        return String(unsafe_from_utf8=Span(buf))


def parse_form(body: String) raises -> FormParams:
    """Read a form body strictly (see the file header). Raises
    `OAuthError: ...`."""
    var b = body.as_bytes()
    var n = len(b)
    if n > OAUTH_FORM_MAX_BYTES:
        _refuse("the form is longer than 65536 bytes")
    var out = FormParams()
    if n == 0:
        return out^
    var start = 0
    while start <= n:
        var end = start
        while end < n and b[end] != 0x26:  # '&'
            end += 1
        if end == start:
            _refuse("the form has an empty pair")
        var eq = start
        while eq < end and b[eq] != 0x3D:  # '='
            eq += 1
        if eq == end:
            _refuse("the form has a pair without =")
        if eq == start:
            _refuse("the form has a pair with an empty name")
        var name = _decode(b, start, eq)
        var value = _decode(b, eq + 1, end)
        if out.get(name):
            _refuse("the form names a parameter twice")
        out.add(name, value)
        start = end + 1
    return out^
