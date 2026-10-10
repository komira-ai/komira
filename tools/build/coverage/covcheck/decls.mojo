"""Declaration reachability: the functions a source file declares, and
which of them have no line with a record in any report.

A coverage report holds a line only when the compiler emitted code for it
(the DWARF line rows of a test binary; kcov lists exactly those). Mojo emits
a function only when something the test reaches calls it, so a function no
test calls has no line in any report and line coverage cannot see it: a
file can read 100% with a public function no test calls. This module lists
the functions none of whose lines has a record. That is not the same as
"no test calls it": a function a test does call can also have no record
of its own (below), so the list is a candidate list, with a class per
function saying how far it can be trusted.

**A declaration** is a line holding code, not starting inside a string,
whose first word (after spaces and tabs) is `def` or `fn` followed by a
space or tab. Its **signature** runs from that line to the first line at
which the `(` `)` and `[` `]` it opened are closed again (lexer.mojo counts
them outside strings and comments). The signature ends in `:`; code after
that `:` on its last line is a one-line body. Otherwise the **body** is
every following line up to the first line that holds code, does not start
inside a string, and is indented no deeper than the declaration (a
docstring line further left does not end it); `end` is the last line before
that holding code or string text.

A declaration whose body is only `...` (on the signature line, or as the
body's only code after a docstring), or that has no body, is a requirement
of a trait, not a function: nothing can compile it, so it is left out. A
body of `pass` is a function (its code sits on the `def` line).

A function's **own lines** are the executable lines (lexer.mojo's
heuristic, so the same lines a file no test compiled counts) from its `def`
line to `end`, without the lines of the functions nested in it: a closure
is a function of its own, recorded or not on its own.

A function is **recorded** when any line of its range (`def` line to `end`,
nested functions' ranges left out) has a record. Decorator lines are not
part of a function. `unrecorded_functions` lists the ones that are not,
each with its own lines that carry no exemption marker (`exempt`); a
function left with no line is not listed.

Each listed function has a `kind`:

- `always_inline`: a decorator line right above it starts with
  `@always_inline`. Its code is inlined into its callers, and the compiler
  may attribute what is left of it to the caller's lines or fold it away
  (a constant, a one-instruction body), so a test can call it while none of
  its lines has a record. Not evidence that no test calls it.
- `comptime_if`: its body holds a `comptime if` or `@parameter` line. A
  body whose code is all in a dropped arm (a platform-only or
  build-flag-only function) emits nothing on this platform, and a body
  folded to a constant leaves no line either. Not evidence either.
- `plain`: neither. The class a census can count. Known false positive
  that remains: a function reached only through a dropped `comptime if`
  arm of another function (its caller is never compiled on this platform
  or build).

What it cannot see: a `comptime if` arm the compiler dropped inside a
recorded function (the whole function is the unit here), and a function
whose code the compiler emits without line rows.

**Declaration-only files** (`declaration_only`, read by analyze.mojo for a
file no test compiled). This module's declaration and body reader is the
one authority on which declarations are functions and which are
requirements (a body of `...` alone), and where a body ends; a file is
declaration-only when that reader finds no function in it, every
declaration it finds is a requirement inside a trait's block, and every
other executable line belongs to a statement that emits no code:

- at the top level, a `trait` header (ending in `:`, or `: ...`) or a
  `comptime` declaration (not one opening a block, as `comptime if` does);
- in a trait's block, a `comptime` declaration, a decorator line, or `...`.

A statement runs over the lines its `(` `)`, `[` `]` and `{` `}` keep open
or a trailing backslash continues. Anything else keeps the file counted: a
free function, a struct, a default method body with code (even `pass`), a
statement, a `;` outside an import, an import with code after its `;`, a
tab or form feed in the indentation, a statement still open at the end of
the file, a file the lexer ends inside a string (a raw triple-quoted
string whose last byte before the closing quotes is a backslash hides
what follows), a carriage return not followed by a line feed (a CR-only
file is one line to the lexer). It assumes what a `comptime` initialiser or
a requirement's default-argument expression computes is computed at
compile time, emitting nothing at run time.

A known limit: the lexer reads a backslash before a quote as an escape in
a raw string too, so contrived text in which that puts it out of step with
the compiler and back in step before the end of the file can hide a line
of code from the heuristic and from this test alike.
"""

from covcheck.lexer import LexState, SourceLine, executable_lines, lex_line, lex_source
from covcheck.text import split_lines, substr, suffix, trim

comptime KIND_PLAIN = "plain"
comptime KIND_ALWAYS_INLINE = "always_inline"
comptime KIND_COMPTIME_IF = "comptime_if"


struct FnDecl(Copyable, Movable):
    """One function or method with a body. `line` is its `def`/`fn` line,
    `end` the last line of its body (1-based, inclusive), `lines` its own
    executable lines (lexer.mojo's heuristic) from `line` to `end`, those of
    functions nested in it left out; `kind` one of the `KIND_` values (see
    the module header)."""

    var name: String
    var line: Int
    var end: Int
    var lines: List[Int]
    var kind: String

    def __init__(out self, name: String, line: Int, end: Int):
        self.name = name
        self.line = line
        self.end = end
        self.lines = List[Int]()
        self.kind = String(KIND_PLAIN)


def _first_word_is_def(text: String) -> Int:
    """The byte offset of the name after a leading `def` or `fn` word
    (followed by a space or tab), or -1."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    var w = 0
    if i + 3 < n and b[i] == UInt8(100) and b[i + 1] == UInt8(101) and b[i + 2] == UInt8(102):
        w = 3
    elif i + 2 < n and b[i] == UInt8(102) and b[i + 1] == UInt8(110):
        w = 2
    else:
        return -1
    if not (b[i + w] == UInt8(32) or b[i + w] == UInt8(9)):
        return -1
    var k = i + w
    while k < n and (b[k] == UInt8(32) or b[k] == UInt8(9)):
        k += 1
    return k


def _name_at(text: String, at: Int) -> String:
    var b = text.as_bytes()
    var k = at
    while k < len(b):
        var c = Int(b[k])
        if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c >= 128):
            break
        k += 1
    return substr(text, at, k)


def _indent(text: String) -> Int:
    var b = text.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return i


def _code_of(l: SourceLine) -> String:
    """The line's text before its comment, trimmed."""
    if l.comment >= 0:
        return trim(substr(l.text, 0, l.comment))
    return trim(l.text)


def _after_colon(code: String, depth_before: Int) -> String:
    """What follows the signature's `:` on its last line `code` (trimmed):
    a one-line body, or empty. `depth_before` is how many brackets the
    signature's earlier lines left open; the signature's `:` is the first
    one outside every bracket and string."""
    var b = code.as_bytes()
    var depth = depth_before
    var last = -1
    var i = 0
    # Scan outside strings: a quote starts a string the lexer would skip.
    var quote = 0
    while i < len(b):
        var c = Int(b[i])
        if quote != 0:
            if c == 92:
                i += 2
                continue
            if c == quote:
                quote = 0
        elif c == 34 or c == 39:
            quote = c
        elif c == 40 or c == 91:
            depth += 1
        elif c == 41 or c == 93:
            depth -= 1
        elif c == 58 and depth <= 0:
            last = i
            # A one-line body may hold a `:` of its own (a slice): the
            # signature's comes first.
            break
        i += 1
    if last < 0:
        return String("")
    return trim(suffix(code, last + 1))


def declared_functions(text: String) -> List[FnDecl]:
    """Every function with a body that `text` declares, in order of their
    `def` lines (see the module header)."""
    var requirements = List[FnDecl]()
    return _declarations(text, requirements)


def _declarations(text: String, mut requirements: List[FnDecl]) -> List[FnDecl]:
    """declared_functions, and in `requirements` every declaration whose
    body is `...` alone (its range `line` to `end`; no own lines, kind
    plain). A declaration with no body at all is in neither list."""
    var src = text
    var tb = text.as_bytes()
    if len(tb) >= 3 and tb[0] == UInt8(0xEF) and tb[1] == UInt8(0xBB) and tb[2] == UInt8(0xBF):
        src = suffix(text, 3)
    var lines = split_lines(src)
    var ls = List[SourceLine](capacity=len(lines))
    var starts_in_string = List[Bool](capacity=len(lines))
    var st = LexState()
    for i in range(len(lines)):
        starts_in_string.append(st.quote != 0)
        ls.append(lex_line(lines[i], st))
    var exe = executable_lines(text)
    var is_exe = Dict[Int, Bool]()
    for i in range(len(exe)):
        is_exe[exe[i]] = True
    var n = len(ls)
    var out = List[FnDecl]()
    for i in range(n):
        if not ls[i].code or starts_in_string[i]:
            continue
        var at = _first_word_is_def(ls[i].text)
        if at < 0:
            continue
        var name = _name_at(ls[i].text, at)
        if name.byte_length() == 0:
            continue
        var ind = _indent(ls[i].text)
        # The signature: until its ( ) and [ ] are closed.
        var depth = 0
        var before = 0
        var h = i
        while h < n:
            before = depth
            depth += ls[h].opens - ls[h].closes + ls[h].brackets
            if depth <= 0:
                break
            h += 1
        if h >= n:
            h = n - 1
        var inline = _after_colon(_code_of(ls[h]), before)
        var end = h
        var body_code = List[String]()
        if inline.byte_length() > 0:
            body_code.append(inline)
        else:
            var j = h + 1
            while j < n:
                if ls[j].code and not starts_in_string[j] and _indent(ls[j].text) <= ind:
                    break
                # Code, or string text (a docstring's lines); not a blank
                # or comment-only line.
                if ls[j].code or (ls[j].comment < 0 and trim(ls[j].text).byte_length() > 0):
                    end = j
                if ls[j].code:
                    body_code.append(_code_of(ls[j]))
                j += 1
        # A trait's requirement: its only code is `...`.
        var only_ellipsis = len(body_code) == 0
        if len(body_code) == 1 and body_code[0] == String("..."):
            only_ellipsis = True
        if only_ellipsis:
            if len(body_code) == 1:
                requirements.append(FnDecl(name, i + 1, end + 1))
            continue
        var f = FnDecl(name, i + 1, end + 1)
        # Its class: the decorators right above it, then its body.
        var inline_dec = False
        var d = i - 1
        while d >= 0 and ls[d].code and not starts_in_string[d] and _code_of(ls[d]).startswith("@"):
            if _code_of(ls[d]).startswith("@always_inline"):
                inline_dec = True
            d -= 1
        var gated = False
        for c in range(len(body_code)):
            if body_code[c].startswith("comptime if") or body_code[c].startswith("@parameter"):
                gated = True
        if inline_dec:
            f.kind = String(KIND_ALWAYS_INLINE)
        elif gated:
            f.kind = String(KIND_COMPTIME_IF)
        out.append(f^)
    # Own lines: the function's range less its nested functions' ranges.
    for k in range(len(out)):
        for ln in range(out[k].line, out[k].end + 1):
            if ln not in is_exe:
                continue
            var nested = False
            for m in range(len(out)):
                if m != k and out[m].line > out[k].line and out[m].line <= out[k].end and ln >= out[m].line and ln <= out[m].end:
                    nested = True
                    break
            if not nested:
                out[k].lines.append(ln)
    return out^


def unrecorded_functions(text: String, recorded: Dict[Int, Int], exempt: Dict[Int, Bool]) -> List[FnDecl]:
    """The functions of `text` (declared_functions) no line of whose range
    is a key of `recorded` (the lines a report gives a record, whatever
    their hits), each with its own lines less those in `exempt` (lines
    carrying a marker); a function left with no line is not listed."""
    var fns = declared_functions(text)
    var out = List[FnDecl]()
    for k in range(len(fns)):
        var has_record = False
        for ln in range(fns[k].line, fns[k].end + 1):
            if ln not in recorded:
                continue
            var nested = False
            for m in range(len(fns)):
                if m != k and fns[m].line > fns[k].line and fns[m].line <= fns[k].end and ln >= fns[m].line and ln <= fns[m].end:
                    nested = True
                    break
            if not nested:
                has_record = True
                break
        if has_record:
            continue
        var f = FnDecl(fns[k].name, fns[k].line, fns[k].end)
        f.kind = fns[k].kind
        for i in range(len(fns[k].lines)):
            if fns[k].lines[i] not in exempt:
                f.lines.append(fns[k].lines[i])
        if len(f.lines) > 0:
            out.append(f^)
    return out^


def _keyword_then_blank(code: String, word: String) -> Bool:
    var w = word.byte_length()
    if not code.startswith(word) or code.byte_length() <= w:
        return False
    var after = Int(code.as_bytes()[w])
    return after == 32 or after == 9


def _leading_spaces(text: String) -> Int:
    """The spaces before `text`'s first other byte; -1 when a tab or a form
    feed is among them."""
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        if c == 9 or c == 12:
            return -1
        if c != 32:
            break
        i += 1
    return i


def _ellipsis_block(code: String) -> Bool:
    """A header's last line ends with `: ...`."""
    if not code.endswith("..."):
        return False
    return trim(substr(code, 0, code.byte_length() - 3)).endswith(":")


def _bare_cr(text: String) -> Bool:
    var b = text.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(13) and (i + 1 >= len(b) or b[i + 1] != UInt8(10)):
            return True
    return False


def _ends_in_string(text: String) -> Bool:
    var st = LexState()
    var lines = split_lines(text)
    for i in range(len(lines)):
        _ = lex_line(lines[i], st)
    return st.quote != 0


comptime _TRAIT: Int = 1
comptime _COMPTIME: Int = 2
comptime _MEMBER: Int = 3


def declaration_only(text: String) -> Bool:
    """Whether `text` has executable lines and every one is a declaration
    the compiler emits no code for (see the module header); False whenever
    unsure."""
    if _bare_cr(text) or _ends_in_string(text):
        return False
    # decls' reader is the authority: any function it finds (even one the
    # walk below would not reach, inside a statement whose brackets balance
    # around it) makes the file not declaration-only; the requirements it
    # finds are the only `def` lines the walk accepts.
    var requirements = List[FnDecl]()
    if len(_declarations(text, requirements)) > 0:
        return False
    # The last line of the requirement each `def` line starts.
    var req_end = Dict[Int, Int]()
    for k in range(len(requirements)):
        req_end[requirements[k].line] = requirements[k].end
    var ls = lex_source(text)
    var any = False
    var in_trait = False
    var depth = 0
    var cont = False
    var kind = 0
    var skip_to = 0
    for i in range(len(ls)):
        if i + 1 <= skip_to:
            continue
        if not ls[i].code:
            continue
        if ls[i].is_import:
            if ls[i].tail_code:
                return False
            continue
        if ls[i].semi >= 0:
            return False
        any = True
        var code = _code_of(ls[i])
        var net = ls[i].opens - ls[i].closes + ls[i].brackets + ls[i].braces
        if cont:
            depth += net
        else:
            var ind = _leading_spaces(ls[i].text)
            if ind < 0:
                return False
            var req = req_end.get(i + 1, -1)
            if req >= 0:
                # A requirement: only in a trait's block.
                if ind == 0 or not in_trait:
                    return False
                skip_to = req
                continue
            if ind == 0:
                in_trait = False
                if _keyword_then_blank(code, String("trait")):
                    kind = _TRAIT
                elif _keyword_then_blank(code, String("comptime")):
                    kind = _COMPTIME
                else:
                    return False
            elif not in_trait:
                return False
            elif _keyword_then_blank(code, String("comptime")):
                kind = _COMPTIME
            elif code == String("...") or code.startswith("@"):
                kind = _MEMBER
            else:
                return False
            depth = net
        cont = depth > 0 or ls[i].continued
        if cont:
            continue
        if depth < 0:
            return False
        # The statement ends on this line.
        if kind == _TRAIT:
            if code.endswith(":"):
                in_trait = True
            elif not _ellipsis_block(code):
                return False
        elif kind == _COMPTIME and code.endswith(":"):
            return False
    return any and not cont
