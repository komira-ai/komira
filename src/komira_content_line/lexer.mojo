# =============================================================================
# lexer.mojo -- one unfolded content line to (group, name, params, value),
# and back (RFC 6350 §3.3, RFC 5545 §3.1; parameter values per RFC 6868).
# =============================================================================
#
#     contentline = [group "."] name *(";" param) ":" value
#     param       = param-name ["=" param-value *("," param-value)]
#     param-value = *SAFE-CHAR / DQUOTE *QSAFE-CHAR DQUOTE
#
# - The group, when present, is split off the name: `item1.EMAIL` is group
#   `item1`, name `EMAIL`. Group and name are ALPHA / DIGIT / "-"; the name is
#   upper-cased, the group is kept as written.
# - A parameter name is upper-cased. A parameter with no "=" (vCard 2.1's
#   `TEL;WORK;VOICE:`) is kept with `has_value = False` and no values.
# - A quoted parameter value ends at the next DQUOTE and may hold ":", ";" and
#   ",". Values are decoded per RFC 6868: `^n` is a line feed, `^'` a DQUOTE,
#   `^^` a caret; a caret before any other character is kept.
# - The value is everything after the first ":" outside quotes, still escaped
#   (the property decides how to split and unescape it; see text.mojo).
#
# `format_content_line` writes the line back unfolded. It refuses a group,
# name or parameter name outside the grammar and a CR in a parameter value,
# so no field can start a new line. A parameter value holding ",", ";" or ":"
# is quoted; a line feed, DQUOTE or caret in it is caret-encoded.
# =============================================================================


struct Param(Copyable, Movable, Equatable):
    """One parameter: an upper-cased name and its decoded values."""

    var name: String
    var values: List[String]
    var has_value: Bool

    def __init__(out self, var name: String, var values: List[String]):
        self.name = name^
        self.values = values^
        self.has_value = True

    def __init__(out self, *, var bare: String):
        self.name = bare^
        self.values = List[String]()
        self.has_value = False

    def __eq__(self, other: Self) -> Bool:
        return (
            self.name == other.name
            and self.has_value == other.has_value
            and self.values == other.values
        )


struct ContentLine(Copyable, Movable, Equatable):
    """One lexed content line. `value` is still escaped."""

    var group: String
    var name: String
    var params: List[Param]
    var value: String

    def __init__(
        out self,
        var group: String,
        var name: String,
        var params: List[Param],
        var value: String,
    ):
        self.group = group^
        self.name = name^
        self.params = params^
        self.value = value^

    def __eq__(self, other: Self) -> Bool:
        return (
            self.group == other.group
            and self.name == other.name
            and self.params == other.params
            and self.value == other.value
        )

    def param(self, name: String) -> Optional[Param]:
        """The first parameter called `name` (upper case), if any."""
        for i in range(len(self.params)):
            if self.params[i].name == name:
                return self.params[i].copy()
        return None


@always_inline
def _is_name_octet(c: UInt8) -> Bool:
    return (
        (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or (c >= 48 and c <= 57)
        or c == 45
    )


def _err(line_number: Int, what: String) -> Error:
    return Error(
        String("content line: line ") + String(line_number) + String(" ") + what
    )


def _slice(b: Span[UInt8, _], start: Int, end: Int) raises -> String:
    var tmp = List[UInt8](capacity=end - start)
    for k in range(start, end):
        tmp.append(b[k])
    return String(StringSlice(from_utf8=Span(tmp)))


def _decode_caret(raw: String) -> String:
    """RFC 6868 decoding of one parameter value."""
    var b = raw.as_bytes()
    if raw.find("^") < 0:
        return raw.copy()
    var out = String()
    var i = 0
    var n = len(b)
    var run = 0
    while i < n:
        if b[i] == 94 and i + 1 < n:
            var c = b[i + 1]
            var rep: String
            if c == 110:
                rep = "\n"
            elif c == 39:
                rep = '"'
            elif c == 94:
                rep = "^"
            else:
                i += 1
                continue
            out += String(raw[byte=run:i])
            out += rep
            i += 2
            run = i
            continue
        i += 1
    out += String(raw[byte=run:n])
    return out^


def parse_content_line(text: String, line_number: Int) raises -> ContentLine:
    """Lex one unfolded content line (file header). `line_number` is used in
    error messages only."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (_is_name_octet(b[i])):
        i += 1
    var group = String()
    var name_start = 0
    if i < n and b[i] == 46:
        if i == 0:
            raise _err(line_number, "has an empty group name")
        group = _slice(b, 0, i)
        i += 1
        name_start = i
        while i < n and _is_name_octet(b[i]):
            i += 1
    if i == name_start:
        raise _err(line_number, "has an empty property name")
    var name = _slice(b, name_start, i).upper()
    if i >= n:
        raise _err(line_number, "has no ':' after the property name")
    if b[i] != 59 and b[i] != 58:
        raise _err(line_number, "has an invalid character in the property name")
    var params = List[Param]()
    while i < n and b[i] == 59:
        i += 1
        var ps = i
        while i < n and _is_name_octet(b[i]):
            i += 1
        if i == ps:
            raise _err(line_number, "has an empty parameter name")
        var pname = _slice(b, ps, i).upper()
        if i < n and (b[i] == 59 or b[i] == 58):
            params.append(Param(bare=pname^))
            continue
        if i >= n or b[i] != 61:
            raise _err(
                line_number, "has an invalid character in a parameter name"
            )
        i += 1
        var values = List[String]()
        while True:
            if i < n and b[i] == 34:
                var qs = i + 1
                var qe = qs
                while qe < n and b[qe] != 34:
                    qe += 1
                if qe >= n:
                    raise _err(
                        line_number, "has an unterminated quoted parameter value"
                    )
                values.append(_decode_caret(_slice(b, qs, qe)))
                i = qe + 1
                if i < n and b[i] != 44 and b[i] != 59 and b[i] != 58:
                    raise _err(
                        line_number,
                        "has a character after a quoted parameter value",
                    )
            else:
                var vs = i
                while i < n and b[i] != 44 and b[i] != 59 and b[i] != 58:
                    if b[i] == 34:
                        raise _err(
                            line_number,
                            "has a DQUOTE inside an unquoted parameter value",
                        )
                    i += 1
                values.append(_decode_caret(_slice(b, vs, i)))
            if i < n and b[i] == 44:
                i += 1
                continue
            break
        params.append(Param(pname^, values^))
    if i >= n or b[i] != 58:
        raise _err(line_number, "has no ':' after the property name")
    var value = _slice(b, i + 1, n)
    return ContentLine(group^, name^, params^, value^)


def _check_token(token: String, what: String) raises:
    var b = token.as_bytes()
    if len(b) == 0:
        raise Error(String("content line: empty ") + what)
    for k in range(len(b)):
        if not _is_name_octet(b[k]):
            raise Error(
                String("content line: ")
                + what
                + String(" '")
                + token
                + String("' has a character outside ALPHA, DIGIT and '-'")
            )


def _encode_param_value(v: String) raises -> String:
    var b = v.as_bytes()
    var quote = False
    var out = String()
    var run = 0
    for k in range(len(b)):
        var c = b[k]
        if c == 13:
            raise Error(
                String("content line: a parameter value holds a CR")
            )
        if c == 44 or c == 59 or c == 58:
            quote = True
        var rep = String()
        if c == 10:
            rep = "^n"
        elif c == 34:
            rep = "^'"
        elif c == 94:
            rep = "^^"
        else:
            continue
        out += String(v[byte=run:k])
        out += rep
        run = k + 1
    out += String(v[byte=run : len(b)])
    if quote:
        return String('"') + out + String('"')
    return out^


def format_content_line(line: ContentLine) raises -> String:
    """`line` as one unfolded content line, without a line break. Raises on a
    field that cannot be written (file header)."""
    var out = String()
    if line.group.byte_length() > 0:
        _check_token(line.group, "group")
        out += line.group
        out += "."
    _check_token(line.name, "property name")
    out += line.name
    for k in range(len(line.params)):
        ref p = line.params[k]
        _check_token(p.name, "parameter name")
        out += ";"
        out += p.name
        if not p.has_value:
            continue
        out += "="
        for j in range(len(p.values)):
            if j > 0:
                out += ","
            out += _encode_param_value(p.values[j])
    var vb = line.value.as_bytes()
    for k in range(len(vb)):
        if vb[k] == 13 or vb[k] == 10:
            raise Error(
                String("content line: the value of ")
                + line.name
                + String(" holds a line break")
            )
    out += ":"
    out += line.value
    return out^
