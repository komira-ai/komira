# =============================================================================
# komira_textproto/lexer.mojo -- a textproto lexer.
# =============================================================================
#
# Token kinds:
#   TOKEN_LBRACE / TOKEN_RBRACE / TOKEN_COLON  the structural `{` `}` `:`.
#   TOKEN_STRING  a "..." or '...' string; quotes stripped, escapes decoded.
#                 A string may not span a line.
#   TOKEN_NUMBER  a bareword starting with a digit, with `.` then a digit, or
#                 with a sign then a digit or `.` and a digit (`42`, `-7`,
#                 `0.5`, `.25`, `-.5`, `1e3`). Its text is kept verbatim.
#   TOKEN_WORD    any other bareword: field names, enum values, `true`.
# `#` starts a comment that runs to the end of the line. Whitespace separates
# tokens and is dropped. Every token records the 1-based line it starts on.
#
# Every refusal names its source and line: `<source>: line N: ...`, where the
# source defaults to `textproto` and a reader may pass its own (for example
# the name of the file kind it reads), so lexer and cursor refusals read the
# same as the reader's own.
#
# Refusals: an unterminated string, an unknown
# escape, and a character this lexer does not support (`[ ] < > , ;`), so a
# file written for a richer textproto dialect fails loudly instead of being
# lexed into barewords.
#
# Supported escapes: \\  \"  \'  \n  \t  \r
#
# Stdlib only: depends on nothing above String, List and Int.
# =============================================================================

comptime TOKEN_WORD: Int = 0
comptime TOKEN_NUMBER: Int = 1
comptime TOKEN_STRING: Int = 2
comptime TOKEN_LBRACE: Int = 3
comptime TOKEN_RBRACE: Int = 4
comptime TOKEN_COLON: Int = 5

comptime _B_TAB: Int = 9
comptime _B_LF: Int = 10
comptime _B_CR: Int = 13
comptime _B_SPACE: Int = 32
comptime _B_DQUOTE: Int = 34
comptime _B_HASH: Int = 35
comptime _B_SQUOTE: Int = 39
comptime _B_COMMA: Int = 44
comptime _B_PLUS: Int = 43
comptime _B_MINUS: Int = 45
comptime _B_DOT: Int = 46
comptime _B_0: Int = 48
comptime _B_9: Int = 57
comptime _B_COLON: Int = 58
comptime _B_SEMI: Int = 59
comptime _B_LT: Int = 60
comptime _B_GT: Int = 62
comptime _B_LBRACKET: Int = 91
comptime _B_BACKSLASH: Int = 92
comptime _B_RBRACKET: Int = 93
comptime _B_LBRACE: Int = 123
comptime _B_RBRACE: Int = 125


def token_kind_name(kind: Int) -> String:
    """A readable name for a token kind, for error messages."""
    if kind == TOKEN_WORD:
        return String("word")
    if kind == TOKEN_NUMBER:
        return String("number")
    if kind == TOKEN_STRING:
        return String("string")
    if kind == TOKEN_LBRACE:
        return String("'{'")
    if kind == TOKEN_RBRACE:
        return String("'}'")
    if kind == TOKEN_COLON:
        return String("':'")
    return String("token kind ") + String(kind)


struct Token(Copyable, Movable):
    """One lexed token: its kind, its text (decoded, for a string) and the
    1-based line it starts on."""

    var kind: Int
    var text: String
    var line: Int

    def __init__(out self, kind: Int, var text: String, line: Int):
        self.kind = kind
        self.text = text^
        self.line = line

    def describe(self) -> String:
        """`<kind> '<text>'` for words and numbers, `string "<text>"` for
        strings, and the kind alone for structural tokens."""
        if self.kind == TOKEN_WORD or self.kind == TOKEN_NUMBER:
            return token_kind_name(self.kind) + String(" '") + self.text + String("'")
        if self.kind == TOKEN_STRING:
            return String("string \"") + self.text + String("\"")
        return token_kind_name(self.kind)


def _is_ws(c: Int) -> Bool:
    return c == _B_SPACE or c == _B_TAB or c == _B_LF or c == _B_CR


def _is_structural(c: Int) -> Bool:
    return c == _B_LBRACE or c == _B_RBRACE or c == _B_COLON


def _is_unsupported(c: Int) -> Bool:
    return (
        c == _B_LBRACKET
        or c == _B_RBRACKET
        or c == _B_LT
        or c == _B_GT
        or c == _B_COMMA
        or c == _B_SEMI
    )


def _is_digit(c: Int) -> Bool:
    return c >= _B_0 and c <= _B_9


comptime DEFAULT_SOURCE: String = "textproto"
"""The source label refusals carry when the reader names none."""


def _line_prefix(source: String, line: Int) -> String:
    return source + String(": line ") + String(line) + String(": ")


def _codepoint_end(text: String, i: Int) -> Int:
    """The byte index just past the UTF-8 codepoint that starts at byte `i`,
    so a slice ending there never splits a character."""
    var b = text.as_bytes()
    var lead = Int(b[i])
    var width = 1
    if lead >= 0xF0:
        width = 4
    elif lead >= 0xE0:
        width = 3
    elif lead >= 0xC0:
        width = 2
    return min(i + width, len(b))


def lex(text: String) raises -> List[Token]:
    """Lex `text`, labelling refusals `textproto`. See `lex(text, source)`."""
    return lex(text, String(DEFAULT_SOURCE))


def lex(text: String, source: String) raises -> List[Token]:
    """Lex `text` into typed tokens; each refusal starts `<source>: line N:`.
    See the module header for the kinds, the escapes and the refusals."""
    var toks = List[Token]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var line = 1
    while i < n:
        var c = Int(b[i])
        if c == _B_LF:
            line += 1
            i += 1
            continue
        if _is_ws(c):
            i += 1
            continue
        if c == _B_HASH:
            while i < n and Int(b[i]) != _B_LF:
                i += 1
            continue
        if c == _B_LBRACE:
            toks.append(Token(TOKEN_LBRACE, String("{"), line))
            i += 1
            continue
        if c == _B_RBRACE:
            toks.append(Token(TOKEN_RBRACE, String("}"), line))
            i += 1
            continue
        if c == _B_COLON:
            toks.append(Token(TOKEN_COLON, String(":"), line))
            i += 1
            continue
        if _is_unsupported(c):
            raise Error(
                _line_prefix(source, line)
                + String("unsupported character '")
                + String(text[byte=i : i + 1])
                + String("'")
            )
        if c == _B_DQUOTE or c == _B_SQUOTE:
            var quote = c
            var out = String("")
            var seg = i + 1
            var j = i + 1
            var closed = False
            while j < n:
                var cj = Int(b[j])
                if cj == quote:
                    closed = True
                    break
                if cj == _B_LF:
                    break
                if cj == _B_BACKSLASH:
                    out += String(text[byte=seg:j])
                    if j + 1 >= n:
                        break
                    var e = Int(b[j + 1])
                    if e == _B_BACKSLASH:
                        out += "\\"
                    elif e == _B_DQUOTE:
                        out += "\""
                    elif e == _B_SQUOTE:
                        out += "'"
                    elif e == 110:  # n
                        out += "\n"
                    elif e == 116:  # t
                        out += "\t"
                    elif e == 114:  # r
                        out += "\r"
                    else:
                        raise Error(
                            _line_prefix(source, line)
                            + String("unknown escape '\\")
                            + String(text[byte=j + 1 : _codepoint_end(text, j + 1)])
                            + String("' in a string")
                        )
                    j += 2
                    seg = j
                    continue
                j += 1
            if not closed:
                raise Error(_line_prefix(source, line) + String("unterminated string"))
            out += String(text[byte=seg:j])
            toks.append(Token(TOKEN_STRING, out^, line))
            i = j + 1
            continue
        # A bareword: read to the next whitespace, structural, quote, comment
        # or unsupported character.
        var start = i
        while i < n:
            var cc = Int(b[i])
            if (
                _is_ws(cc)
                or _is_structural(cc)
                or _is_unsupported(cc)
                or cc == _B_DQUOTE
                or cc == _B_SQUOTE
                or cc == _B_HASH
            ):
                break
            i += 1
        var kind = TOKEN_WORD
        if _is_digit(c):
            kind = TOKEN_NUMBER
        elif c == _B_DOT and start + 1 < i:
            if _is_digit(Int(b[start + 1])):
                kind = TOKEN_NUMBER
        elif (c == _B_MINUS or c == _B_PLUS) and start + 1 < i:
            var c1 = Int(b[start + 1])
            if _is_digit(c1):
                kind = TOKEN_NUMBER
            elif c1 == _B_DOT and start + 2 < i and _is_digit(Int(b[start + 2])):
                kind = TOKEN_NUMBER
        toks.append(Token(kind, String(text[byte=start:i]), line))
    return toks^


struct TokenCursor(Movable):
    """A forward reader over a lexed token list, for hand-written parsers.
    Every refusal names the source, the line and what was found."""

    var toks: List[Token]
    var pos: Int
    var source: String

    def __init__(out self, var toks: List[Token]):
        """A cursor whose refusals are labelled `textproto`."""
        self.toks = toks^
        self.pos = 0
        self.source = String(DEFAULT_SOURCE)

    def __init__(out self, var toks: List[Token], var source: String):
        """A cursor whose refusals start `<source>: line N:`."""
        self.toks = toks^
        self.pos = 0
        self.source = source^

    def at_end(self) -> Bool:
        return self.pos >= len(self.toks)

    def is_kind(self, kind: Int) -> Bool:
        """True when the next token exists and has kind `kind`."""
        return self.pos < len(self.toks) and self.toks[self.pos].kind == kind

    def last_line(self) -> Int:
        """The line of the last token, or 1 for an empty input."""
        if len(self.toks) == 0:
            return 1
        return self.toks[len(self.toks) - 1].line

    def next(mut self, what: String) raises -> Token:
        """Consume and return the next token. `what` names what the caller
        expected, for the end-of-input refusal."""
        if self.pos >= len(self.toks):
            raise Error(
                _line_prefix(self.source, self.last_line())
                + String("expected ")
                + what
                + String(" but reached the end of input")
            )
        var t = self.toks[self.pos].copy()
        self.pos += 1
        return t^

    def expect(mut self, kind: Int) raises -> Token:
        """Consume the next token, which must have kind `kind`."""
        var t = self.next(token_kind_name(kind))
        if t.kind != kind:
            raise Error(
                _line_prefix(self.source, t.line)
                + String("expected ")
                + token_kind_name(kind)
                + String(" but got ")
                + t.describe()
            )
        return t^
