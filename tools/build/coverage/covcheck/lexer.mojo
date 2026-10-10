"""A small Mojo source lexer, line by line: where each line's comment
starts, whether the line holds code, and whether it is part of an import
statement. Exemption markers (exempt.mojo) and the executable-line
heuristic for files no test compiled (analyze.mojo) both read it.

The lexer keeps one piece of state across lines: whether it is inside a
string literal, and which. It knows:

- `"..."` and `'...'`, which end at the same quote or at the line end (a
  backslash as the line's last byte continues the string on the next line);
- triple-quoted strings (three double or three single quotes), which may
  span lines;
- a backslash inside any string keeps the next byte from closing it. In a
  raw string (`r"..."`) the backslash stays in the value, but it still keeps
  the next quote from closing the string, as in Python, so raw strings need
  no case of their own;
- string prefixes: one or two of the letters `r b f u t` (either case)
  right before a quote, not preceded by an identifier byte, are part of the
  string, not code;
- a comment: the first `#` outside every string, to the end of the line.

A carriage return at the end of a line (a CRLF file) is removed first, and
a UTF-8 byte-order mark (`EF BB BF`) at the start of the file.

A line holds **code** when it has a byte outside every string and its
comment other than a space, a tab or a form feed. A line is part of an
**import** statement when, outside a string, its first word is `import` or
`from` followed by a space or tab, and every line after it while the
statement's parentheses are open or a line ends with a backslash. A `;`
outside every string ends the statement: what follows it on the line is
read as the next statement (another import, or code).

**Executable** lines (`executable_lines`) are the lines holding code that
are not part of an import, and the import lines holding code after a `;`
that is not another import. So a line is not executable when it is blank,
only a comment, only inside or made of string literals (a docstring, a
string spanning lines, a line of a string concatenated over lines that
holds nothing but the string), or part of an import (`import x`,
`from x import y`, a parenthesised list over several lines). Every other
line is counted, declarations (`def`, `struct`, `comptime`, a decorator)
and lone brackets included, with one exception: a trait's header and its
**requirements** are not executable, since a requirement emits no code. A
requirement is a `def` inside a `trait` block whose body is only `...`
(after an optional docstring), or a `def` line ending in `: ...`; its
decorators, its signature lines and the `...` line are not counted. A trait
method with a default body is counted like any other `def`. A `trait` block
is its header (with the lines its open parentheses carry) and every line
after it up to the next line holding code at the header's indent or less.
This is a heuristic, which declaration reachability will replace with what
the compiler emits. A file no test compiled whose executable lines are all
declarations the compiler emits no code for counts none of them:
decls.declaration_only decides that.
"""

from covcheck.text import split_lines, substr, suffix

comptime _BACKSLASH: Int = 92
comptime _HASH: Int = 35
comptime _DQUOTE: Int = 34
comptime _SQUOTE: Int = 39


struct LexState(Copyable, Movable):
    """Inside which string a line starts: `quote` is 0 outside any, else
    the quote byte (a one-line string is still open only when the previous
    line ended with a backslash inside it); `triple` for a triple-quoted
    string."""

    var quote: Int
    var triple: Bool

    def __init__(out self):
        self.quote = 0
        self.triple = False


struct SourceLine(Copyable, Movable):
    """One line as the lexer read it. `text` is the line without a trailing
    carriage return; `comment` the byte offset of its comment's `#`, or -1;
    `opens`/`closes` count `(` and `)` in its code, `brackets` is the
    number of `[` less the number of `]` in it (decls.mojo reads both to
    find where a signature ends), `braces` the number of `{` less the number
    of `}` (decls.declaration_only reads all three to find where a
    statement ends); `semi` is the offset of its first `;` in
    code, or -1; `tail_code` is set on an import line when
    a statement that is not an import follows a `;`; `in_string` is set when
    the line starts inside a string literal."""

    var text: String
    var comment: Int
    var code: Bool
    var opens: Int
    var closes: Int
    var brackets: Int
    var braces: Int
    var semi: Int
    var continued: Bool
    var is_import: Bool
    var tail_code: Bool
    var in_string: Bool

    def __init__(out self, text: String):
        self.text = text
        self.comment = -1
        self.code = False
        self.opens = 0
        self.closes = 0
        self.brackets = 0
        self.braces = 0
        self.semi = -1
        self.continued = False
        self.is_import = False
        self.tail_code = False
        self.in_string = False


def _is_ident(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def _is_prefix_letter(c: Int) -> Bool:
    # r b f u t, either case
    return c == 114 or c == 82 or c == 98 or c == 66 or c == 102 or c == 70 or c == 117 or c == 85 or c == 116 or c == 84


def _prefix_len(text: String, i: Int) -> Int:
    """How many string-prefix letters start at byte `i` of `text` (0, 1 or
    2): letters right before a quote, not continuing an identifier."""
    var b = text.as_bytes()
    if i > 0 and _is_ident(Int(b[i - 1])):
        return 0
    var n = len(b)
    var k = 0
    while k < 2 and i + k < n and _is_prefix_letter(Int(b[i + k])):
        k += 1
        if i + k < n and (Int(b[i + k]) == _DQUOTE or Int(b[i + k]) == _SQUOTE):
            return k
    return 0


def strip_cr(line: String) -> String:
    """`line` without one trailing carriage return."""
    if line.endswith("\r"):
        return substr(line, 0, line.byte_length() - 1)
    return line


def lex_line(line: String, mut st: LexState) -> SourceLine:
    """Reads one line from the state `st` leaves off in, and leaves `st`
    where the next line starts."""
    var text = strip_cr(line)
    var b = text.as_bytes()
    var n = len(b)
    var comment = -1
    var code = False
    var opens = 0
    var closes = 0
    var brackets = 0
    var braces = 0
    var semi = -1
    var continued = False
    var string_continues = False
    var i = 0
    while i < n:
        var c = Int(b[i])
        if st.quote != 0:
            if c == _BACKSLASH:
                if i + 1 >= n:
                    string_continues = True
                i += 2
                continue
            if c == st.quote:
                if not st.triple:
                    st.quote = 0
                    i += 1
                    continue
                if i + 2 < n and Int(b[i + 1]) == c and Int(b[i + 2]) == c:
                    st.quote = 0
                    st.triple = False
                    i += 3
                    continue
            i += 1
            continue
        if c == _HASH:
            comment = i
            break
        if c == _DQUOTE or c == _SQUOTE:
            st.quote = c
            st.triple = i + 2 < n and Int(b[i + 1]) == c and Int(b[i + 2]) == c
            i += 3 if st.triple else 1
            continue
        if c == 32 or c == 9 or c == 12:
            i += 1
            continue
        var p = _prefix_len(text, i)
        if p > 0:
            i += p
            continue
        code = True
        if c == 40:
            opens += 1
        elif c == 41:
            closes += 1
        elif c == 91:
            brackets += 1
        elif c == 93:
            brackets -= 1
        elif c == 123:
            braces += 1
        elif c == 125:
            braces -= 1
        elif c == 59 and semi < 0:
            semi = i
        elif c == _BACKSLASH and i == n - 1:
            continued = True
        i += 1
    if st.quote != 0 and not st.triple and not string_continues:
        # A one-line string left open ends with its line.
        st.quote = 0
    var out = SourceLine(text)
    out.comment = comment
    out.code = code
    out.opens = opens
    out.closes = closes
    out.brackets = brackets
    out.braces = braces
    out.semi = semi
    out.continued = continued
    return out^


def _keyword_then_blank(rest: String, word: String) -> Bool:
    var w = word.byte_length()
    if not rest.startswith(word) or rest.byte_length() <= w:
        return False
    var after = Int(rest.as_bytes()[w])
    return after == 32 or after == 9


def _starts_import(text: String) -> Bool:
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    var rest = substr(text, i, n)
    return _keyword_then_blank(rest, String("import")) or _keyword_then_blank(rest, String("from"))


struct _ImportState(Copyable, Movable):
    """Whether an import statement continues on the next line, and its
    open parentheses."""

    var continues: Bool
    var depth: Int

    def __init__(out self, continues: Bool, depth: Int):
        self.continues = continues
        self.depth = depth


def _after_semicolons(mut l: SourceLine) -> _ImportState:
    """An import statement on `l` ended at its `;` (`l.semi`). Reads each
    statement after it: one that is not an import sets `l.tail_code` and
    ends the import; the last one, if an import, may continue."""
    # The `;` was in code, so each `rest` starts outside every string.
    var st = LexState()
    var seg = lex_line(suffix(l.text, l.semi + 1), st)
    while seg.code and _starts_import(seg.text) and seg.semi >= 0:
        var fresh = LexState()
        seg = lex_line(suffix(seg.text, seg.semi + 1), fresh)
    if not seg.code:
        return _ImportState(False, 0)
    if not _starts_import(seg.text):
        l.tail_code = True
        return _ImportState(False, 0)
    var depth = seg.opens - seg.closes
    return _ImportState(depth > 0 or seg.continued, depth)


def _without_bom(text: String) -> String:
    """`text` without a leading UTF-8 byte-order mark."""
    var b = text.as_bytes()
    if len(b) >= 3 and b[0] == UInt8(0xEF) and b[1] == UInt8(0xBB) and b[2] == UInt8(0xBF):
        return suffix(text, 3)
    return text


def lex_source(text: String) -> List[SourceLine]:
    """Every line of `text` (split at LF; a final LF ends the last line;
    a leading byte-order mark dropped), lexed in order, with `is_import`
    and `tail_code` set."""
    var lines = split_lines(_without_bom(text))
    var out = List[SourceLine](capacity=len(lines))
    var st = LexState()
    var in_import = False
    var depth = 0
    for i in range(len(lines)):
        var starts_in_string = st.quote != 0
        var l = lex_line(lines[i], st)
        l.in_string = starts_in_string
        var starts = not in_import and not starts_in_string and l.code and _starts_import(l.text)
        if in_import or starts:
            l.is_import = True
            if l.semi >= 0:
                # A `;` cannot sit inside an import's parentheses: the
                # statement ends there.
                var s = _after_semicolons(l)
                in_import = s.continues
                depth = s.depth
            else:
                depth = (depth if in_import else 0) + l.opens - l.closes
                in_import = depth > 0 or l.continued
        out.append(l^)
    return out^


def executable_lines(text: String) -> List[Int]:
    """The 1-based numbers of the executable lines of `text`, ascending
    (see the module header)."""
    var ls = lex_source(text)
    var skip = _trait_requirement_lines(ls)
    var out = List[Int]()
    for i in range(len(ls)):
        if skip[i]:
            continue
        if ls[i].code and (not ls[i].is_import or ls[i].tail_code):
            out.append(i + 1)
    return out^


def _indent(text: String) -> Int:
    """How many spaces and tabs start `text`."""
    var b = text.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return i


def _code_text(l: SourceLine) -> String:
    """`l`'s text before its comment, without the spaces around it."""
    var t = l.text if l.comment < 0 else substr(l.text, 0, l.comment)
    return String(t.strip())


def _statement(l: SourceLine) -> Bool:
    """`l` holds code that starts a statement: code, not inside a string at
    its start, not part of an import."""
    return l.code and not l.in_string and not l.is_import


def _depth(l: SourceLine) -> Int:
    return l.opens - l.closes + l.brackets


def _block_end(ls: List[SourceLine], start: Int, indent: Int) -> Int:
    """The index of the first statement line from `start` on whose indent is
    `indent` or less, or `len(ls)`."""
    var j = start
    while j < len(ls):
        if _statement(ls[j]) and _indent(ls[j].text) <= indent:
            return j
        j += 1
    return j


def _header_end(ls: List[SourceLine], start: Int) -> Int:
    """The index of the last line of the statement starting at `start`: the
    line where its open brackets close (or one not ending in a backslash)."""
    var depth = 0
    var j = start
    while j < len(ls):
        depth += _depth(ls[j])
        if depth <= 0 and not ls[j].continued:
            return j
        j += 1
    return len(ls) - 1


def _trait_requirement_lines(ls: List[SourceLine]) -> List[Bool]:
    """Per line, whether it is a trait header or requirement line (see the
    module header)."""
    var skip = List[Bool](length=len(ls), fill=False)
    var i = 0
    while i < len(ls):
        var ti = _indent(ls[i].text)
        if not (_statement(ls[i]) and _keyword_then_blank(suffix(ls[i].text, ti), String("trait"))):
            i += 1
            continue
        var he = _header_end(ls, i)
        for k in range(i, he + 1):
            skip[k] = True
        var end = _block_end(ls, he + 1, ti)
        var j = he + 1
        while j < end:
            if not (_statement(ls[j]) and _keyword_then_blank(suffix(ls[j].text, _indent(ls[j].text)), String("def"))):
                j += 1
                continue
            var di = _indent(ls[j].text)
            var se = _header_end(ls, j)
            var body_end = _block_end(ls, se + 1, di)
            var body = List[Int]()
            for k in range(se + 1, body_end):
                if ls[k].code:
                    body.append(k)
            var sig = _code_text(ls[se])
            var inline = sig.endswith(": ...")
            var stub = inline or (len(body) == 1 and _code_text(ls[body[0]]) == "...")
            if stub and (not inline or len(body) == 0):
                # Its decorators: the statement lines right above it at its indent.
                var d = j - 1
                while d > he and (not ls[d].code or (_statement(ls[d]) and _indent(ls[d].text) == di and _code_text(ls[d]).startswith("@"))):
                    if ls[d].code:
                        skip[d] = True
                    d -= 1
                for k in range(j, se + 1):
                    skip[k] = True
                if not inline:
                    skip[body[0]] = True
            j = body_end
        i = end
    return skip^
