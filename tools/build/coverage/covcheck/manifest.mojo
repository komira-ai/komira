"""The statements of a mopm.toml: table headers and `key = value` lines.

One scanner walks the whole text, so a value is read to its real end: a
basic string (`"..."`, with `\\` escapes; a backslash may end a line only in
a multi-line string), a literal string (`'...'`), a
multi-line string of either kind (`\"\"\"...\"\"\"`, `'''...'''`, where an escaped
quote does not end it), an array or an inline table (which may span lines,
hold comments and nest; each `]` and `}` must close the bracket or brace
that opened last), or a bare scalar. After a value only blanks and a
comment may follow on its line. A table name is a dotted list of bare keys
(`[ targets . bins ]` is `targets.bins`); a quoted or blank segment is an
error. Every error is `<origin>:<line>: <what>`, never a statement skipped.

Each statement's `value` is its text with comments dropped and line breaks
read as spaces (strings are kept as written), which is what programs.mojo
reads `bins` from. This is the subset of TOML that the program sources need
read strictly; it does not decode values.
"""

from covcheck.text import byte_at, substr, trim

comptime STMT_TABLE = 0
comptime STMT_ARRAY_TABLE = 1
comptime STMT_KEYVAL = 2

comptime _NL = 10
comptime _CR = 13
comptime _SP = 32
comptime _TAB = 9
comptime _HASH = 35
comptime _DQ = 34
comptime _SQ = 39
comptime _BS = 92
comptime _LBRACK = 91
comptime _RBRACK = 93
comptime _LBRACE = 123
comptime _RBRACE = 125
comptime _EQ = 61


struct TomlStmt(Copyable, Movable):
    """A table header (`kind` STMT_TABLE or STMT_ARRAY_TABLE, `name` its dotted name) or
    a `key = value` statement (STMT_KEYVAL, `name` the key as written), and the line it starts on."""

    var kind: Int
    var name: String
    var value: String
    var line: Int

    def __init__(out self, kind: Int, name: String, value: String, line: Int):
        self.kind = kind
        self.name = name
        self.value = value
        self.line = line


def where(origin: String, line: Int) -> String:
    """The `<origin>:<line>: ` prefix of an error."""
    return origin + String(":") + String(line) + String(": ")


struct _Scan(Movable):
    var text: String
    var origin: String
    var n: Int
    var i: Int
    var line: Int

    def __init__(out self, text: String, origin: String):
        self.text = text
        self.origin = origin
        self.n = text.byte_length()
        self.i = 0
        self.line = 1

    def at(self, k: Int) -> Int:
        """The byte at `i + k`, or -1 past the end."""
        if self.i + k >= self.n:
            return -1
        return byte_at(self.text, self.i + k)

    def advance(mut self):
        if self.at(0) == _NL:
            self.line += 1
        self.i += 1

    def fail(self, line: Int, what: String) -> Error:
        return Error(where(self.origin, line) + what)

    def rest_of_line(self) -> String:
        var e = self.i
        while e < self.n and byte_at(self.text, e) != _NL:
            e += 1
        return trim(substr(self.text, self.i, e))

    def skip_blanks(mut self):
        while self.at(0) == _SP or self.at(0) == _TAB or self.at(0) == _CR:
            self.advance()

    def skip_comment(mut self):
        if self.at(0) == _HASH:
            while self.at(0) != -1 and self.at(0) != _NL:
                self.advance()

    def skip_space_and_comments(mut self):
        """Blanks, line ends and comments between statements."""
        while True:
            self.skip_blanks()
            self.skip_comment()
            if self.at(0) == _NL:
                self.advance()
                continue
            return

    def end_of_line(mut self) raises:
        """Only blanks and a comment may follow a statement on its line."""
        self.skip_blanks()
        self.skip_comment()
        if self.at(0) == -1:
            return
        if self.at(0) != _NL:
            raise self.fail(self.line, String("text after the end of a statement: ") + self.rest_of_line())
        self.advance()

    def string(mut self, mut acc: String) raises:
        """A string of any kind at `i`, appended to `acc` as written."""
        var start = self.i
        var start_line = self.line
        var q = self.at(0)
        var multi = self.at(1) == q and self.at(2) == q
        var quotes = 3 if multi else 1
        for _ in range(quotes):
            self.advance()
        while True:
            var c = self.at(0)
            if c == -1 or (c == _NL and not multi):
                raise self.fail(start_line, String("a string that is never closed"))
            if c == _BS and q == _DQ:
                self.advance()
                # A backslash may end a line only inside a multi-line string: a one-line string
                # does not continue on the next line, so it is never closed.
                var e = self.at(0)
                if e == -1 or (not multi and (e == _NL or e == _CR)):
                    raise self.fail(start_line, String("a string that is never closed"))
                self.advance()
                continue
            if c == q and (not multi or (self.at(1) == q and self.at(2) == q)):
                for _ in range(quotes):
                    self.advance()
                # A multi-line string may end with one or two quotes of its own before the closing three.
                var extra = 0
                while multi and extra < 2 and self.at(0) == q:
                    self.advance()
                    extra += 1
                acc += substr(self.text, start, self.i)
                return
            self.advance()

    def value(mut self, key: String, stmt_line: Int) raises -> String:
        """The value at `i`, to its end, as the statement's normalised text."""
        self.skip_blanks()
        var out = String("")
        var c = self.at(0)
        if c == _DQ or c == _SQ:
            self.string(out)
            return out^
        if c != _LBRACK and c != _LBRACE:
            var start = self.i
            while True:
                var b = self.at(0)
                if b == -1 or b == _NL or b == _CR or b == _SP or b == _TAB or b == _HASH or b == _LBRACK or b == _RBRACK or b == _LBRACE or b == _RBRACE or b == _DQ or b == _SQ or b == 44:
                    break
                self.advance()
            if self.i == start:
                raise self.fail(stmt_line, String("`") + key + String("` has no value"))
            return substr(self.text, start, self.i)
        # An array or an inline table: to the close of the bracket it opens.
        var stack = List[Int]()
        var lines = List[Int]()
        while True:
            var b = self.at(0)
            if b == -1:
                raise self.fail(stmt_line, String("a value of `") + key + String("` that is never closed"))
            if b == _DQ or b == _SQ:
                self.string(out)
                continue
            if b == _HASH:
                self.skip_comment()
                continue
            if b == _NL or b == _CR:
                self.advance()
                if b == _NL:
                    out += String(" ")
                continue
            if b == _LBRACK or b == _LBRACE:
                stack.append(b)
                lines.append(self.line)
            elif b == _RBRACK or b == _RBRACE:
                var want = _RBRACK if b == _RBRACK else _RBRACE
                # The stack is never empty here: the value starts with its opener, and the loop
                # returns as soon as the closer of that opener empties it.
                var opener = stack.pop()
                var opened = lines.pop()
                if (opener == _LBRACK) != (want == _RBRACK):
                    raise self.fail(
                        self.line,
                        String("a `") + substr(self.text, self.i, self.i + 1) + String("` where the `")
                        + (String("[") if opener == _LBRACK else String("{")) + String("` of line ") + String(opened)
                        + String(" is never closed"),
                    )
            out += substr(self.text, self.i, self.i + 1)
            self.advance()
            if len(stack) == 0:
                return out^

    def key(mut self, stmt_line: Int) raises -> String:
        """The key at `i`, up to its `=` (which is consumed)."""
        var start = self.i
        while True:
            var c = self.at(0)
            if c == -1 or c == _NL:
                raise self.fail(stmt_line, String("expected `key = value` or a table header, got: ") + trim(substr(self.text, start, self.i)))
            if c == _DQ or c == _SQ:
                var ignored = String("")
                self.string(ignored)
                continue
            if c == _EQ:
                var k = trim(substr(self.text, start, self.i))
                self.advance()
                if k.byte_length() == 0:
                    raise self.fail(stmt_line, String("a `=` with no key"))
                return k^
            self.advance()

    def header(mut self) raises -> TomlStmt:
        """A table header at `i`: `[name]` or `[[name]]`, on one line."""
        var no = self.line
        var array = self.at(1) == _LBRACK
        var skip = 2 if array else 1
        var whole = self.rest_of_line()
        for _ in range(skip):
            self.advance()
        var start = self.i
        while True:
            var c = self.at(0)
            if c == -1 or c == _NL or c == _RBRACK or c == _LBRACK:
                break
            if c == _DQ or c == _SQ:
                raise self.fail(no, String("a quoted table name is not a shape this tool reads: ") + whole)
            self.advance()
        var inner = substr(self.text, start, self.i)
        for _ in range(skip):
            if self.at(0) != _RBRACK:
                raise self.fail(no, String("a table header that does not end with its brackets: ") + whole)
            self.advance()
        var name = String("")
        var seg_start = 0
        var m = inner.byte_length()
        for k in range(m + 1):
            if k == m or byte_at(inner, k) == 46:
                var seg = trim(substr(inner, seg_start, k))
                if not _bare(seg):
                    raise self.fail(no, String("a table name that is not a dotted list of bare keys: ") + whole)
                if name.byte_length() > 0:
                    name += String(".")
                name += seg
                seg_start = k + 1
        self.end_of_line()
        return TomlStmt(STMT_ARRAY_TABLE if array else STMT_TABLE, name, String(""), no)


def _bare(s: String) -> Bool:
    """Whether `s` is a TOML bare key: one or more of A-Z a-z 0-9 _ -."""
    if s.byte_length() == 0:
        return False
    for i in range(s.byte_length()):
        var c = byte_at(s, i)
        var ok = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45
        if not ok:
            return False
    return True


def toml_statements(text: String, origin: String) raises -> List[TomlStmt]:
    """The table headers and `key = value` statements of `text`, in order
    (see the module header for what is read and what is refused)."""
    var s = _Scan(text, origin)
    var out = List[TomlStmt]()
    while True:
        s.skip_space_and_comments()
        if s.at(0) == -1:
            return out^
        if s.at(0) == _LBRACK:
            out.append(s.header())
            continue
        var no = s.line
        var key = s.key(no)
        var value = s.value(key, no)
        s.end_of_line()
        out.append(TomlStmt(STMT_KEYVAL, key, value, no))
