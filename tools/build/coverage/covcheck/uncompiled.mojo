"""The reports of the code no test compiled (buildrules' `uncompiled.cobertura.xml` and
`uncompiled.branches.info`, the last report and branch record file of a mojo_package's `:coverage`,
in its `__coverage__/` directory).

buildrules reads the sources for the functions no test compiled and writes their executable lines
as found and not hit, and the arms of their decision words as not taken. It reads a function as
uncompiled when none of its own lines has a record, which is also what a function the compiler
inlined into its callers looks like (a test calls it, and what is left of it is attributed to a
caller's lines), and what a function looks like whose code is in a `comptime if` arm dropped on this
platform (decls.mojo, "Each listed function has a `kind`").

Those two shapes are told from a function nobody calls only by evidence that a test reached the
function, so a line of the report is left out of the numbers only with it:

* an `@always_inline` function: every own line, when a line outside the function that calls it
  (its name followed by `(` or `[`, in the code of the line; `x.name(` for a method, a bare
  `name(` for a free function) was hit in a test's report;
* a function with `comptime if` / `@parameter` arms (decls.mojo, `arms`): the lines inside those
  arms, when the same evidence exists. The lines outside the arms are counted.

Anything else is counted, as it is without this report: a plain function, a gated function no test
calls, an inlined function no test calls, a nested closure by its own class (never its outer
function's). Each left-out line and arm is counted per file (`ExcludedFile`), and the report names
them.

The reports are told by their file name and parent directory, the ones buildrules gives them
(docs/contract.md of buildrules, "uncompiled"): that is all that sets them apart from a test's report.
"""

from covcheck.decls import KIND_ALWAYS_INLINE, KIND_COMPTIME_IF, declared_functions
from covcheck.lexer import lex_source
from covcheck.model import FileCov
from covcheck.text import parse_count, split_lines, substr

comptime UNCOMPILED_LINES_NAME = "uncompiled.cobertura.xml"
comptime UNCOMPILED_BRANCHES_NAME = "uncompiled.branches.info"
comptime UNCOMPILED_DIR = "__coverage__"


def _split_path(origin: String) -> List[String]:
    var out = List[String]()
    var start = 0
    var b = origin.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(47):
            out.append(substr(origin, start, i))
            start = i + 1
    out.append(substr(origin, start, len(b)))
    return out^


def is_uncompiled_report(origin: String) -> Bool:
    """Whether the report or branch record file named `origin` is buildrules' report of the code no
    test compiled: its file name, in a directory named `__coverage__`."""
    var parts = _split_path(origin)
    var n = len(parts)
    if n < 2:
        return False
    var base = parts[n - 1]
    if base != String(UNCOMPILED_LINES_NAME) and base != String(UNCOMPILED_BRANCHES_NAME):
        return False
    return parts[n - 2] == String(UNCOMPILED_DIR)


def _is_ident(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def _starts_word(line: String, at: Int, word: String) -> Bool:
    var b = line.as_bytes()
    var w = word.as_bytes()
    if at + len(w) >= len(b):
        return False
    for k in range(len(w)):
        if b[at + k] != w[k]:
            return False
    return b[at + len(w)] == UInt8(32) or b[at + len(w)] == UInt8(9)


def _receiver_before(line: String, dot: Int) -> String:
    """The name a call's receiver ends in, before the `.` at `dot`: an identifier (`T.name(`, `x.name(`), or the
    identifier before the `(` of a call (`T(a).name(`); empty when it is neither."""
    var b = line.as_bytes()
    var j = dot - 1
    if j < 0:
        return String("")
    var e = -1
    if b[j] == UInt8(41):
        var depth = 0
        var p = j
        while p >= 0:
            if b[p] == UInt8(41):
                depth += 1
            elif b[p] == UInt8(40):
                depth -= 1
                if depth == 0:
                    break
            p -= 1
        if p <= 0:
            return String("")
        e = p
    elif _is_ident(Int(b[j])):
        e = j + 1
    else:
        return String("")
    var s = e
    while s > 0 and _is_ident(Int(b[s - 1])):
        s -= 1
    if s >= e:
        return String("")
    return substr(line, s, e)


def _code_words_called(line: String, mut into: Dict[String, Bool]):
    """Adds to `into` each identifier of the code of `line` that is followed by `(` or `[`: what
    the line calls. A comment and the inside of a quoted string are not code."""
    var b = line.as_bytes()
    var n = len(b)
    var quote = 0
    var i = 0
    var start = -1
    # A declaration calls nothing: `def f(` is no evidence that a test calls `f`.
    var first = 0
    while first < n and (b[first] == UInt8(32) or b[first] == UInt8(9)):
        first += 1
    if _starts_word(line, first, "def") or _starts_word(line, first, "fn"):
        return
    while i < n:
        var c = Int(b[i])
        if quote != 0:
            if c == 92:
                i += 2
                continue
            if c == quote:
                quote = 0
            i += 1
            continue
        if c == 35:
            break
        if c == 34 or c == 39:
            quote = c
            start = -1
            i += 1
            continue
        if _is_ident(c):
            if start < 0:
                start = i
        else:
            if start >= 0 and (c == 40 or c == 91):
                # `.name(` is a method call, a bare `name(` a call of a free function.
                var dotted = start > 0 and b[start - 1] == UInt8(46)
                var called_name = substr(line, start, i)
                into[(String(".") if dotted else String("")) + called_name] = True
                if dotted:
                    # The receiver, where it is a name or a constructor call (`T(...).name(`, `T.name(`):
                    # `T.name`, which a method declared in `struct T` is resolved by.
                    var recv = _receiver_before(line, start - 1)
                    if recv.byte_length() > 0:
                        into[recv + String(".") + called_name] = True
            start = -1
        i += 1


def _indent(line: String) -> Int:
    var b = line.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return i


def call_keys(line: String) -> List[String]:
    """The calls the code of `line` makes: each key is `name` (a bare call of a free function) or `.name`
    (a method call), as `names_called_on` records them. A declaration calls nothing."""
    var d = Dict[String, Bool]()
    _code_words_called(line, d)
    var out = List[String]()
    for e in d.items():
        out.append(e.key)
    return out^


def names_called_on(text: String, hit: Dict[Int, Bool], mut into: Dict[String, Bool]):
    """Adds to `into` the names the lines of `text` in `hit` (1-based line numbers a test hit) call. A line
    that starts inside a string (a docstring's or a multi-line string's interior) or holds no code is no call."""
    var ls = lex_source(text)
    for e in hit.items():
        if e.key >= 1 and e.key <= len(ls):
            if ls[e.key - 1].in_string or not ls[e.key - 1].code:
                continue
            _code_words_called(ls[e.key - 1].text, into)


def declared_twice(texts: Dict[String, String]) -> Dict[String, Bool]:
    """The function names declared more than once among the sources `texts` (a package's): a call of such a name
    is not told from a call of another function of it, so the name is no evidence for any."""
    var seen = Dict[String, Int]()
    for e in texts.items():
        var fns = declared_functions(e.value)
        for k in range(len(fns)):
            seen[fns[k].name] = seen.get(fns[k].name, 0) + 1
    var out = Dict[String, Bool]()
    for e in seen.items():
        if e.value > 1:
            out[e.key] = True
    return out^


def _struct_of(lines: List[String], def_line: Int) -> String:
    """The name of the `struct` a method declared at `def_line` (1-based) sits in, or the empty string."""
    var ind = 0
    var b = lines[def_line - 1].as_bytes()
    while ind < len(b) and (b[ind] == UInt8(32) or b[ind] == UInt8(9)):
        ind += 1
    var i = def_line - 2
    while i >= 0:
        var t = lines[i].as_bytes()
        var k = 0
        while k < len(t) and (t[k] == UInt8(32) or t[k] == UInt8(9)):
            k += 1
        if k < ind and k < len(t) and _starts_word(lines[i], k, "struct"):
            var s = k + 7
            var e = s
            while e < len(t) and _is_ident(Int(t[e])):
                e += 1
            return substr(lines[i], s, e)
        i -= 1
    return String("")


struct Dropped(Copyable, Movable):
    """What `drop_unreliable` took out of one file: `lines` line records and `arms` branch arms,
    and `line_set` the lines of the line records."""

    var lines: Int
    var arms: Int
    var line_set: Dict[Int, Bool]

    def __init__(out self):
        self.lines = 0
        self.arms = 0
        self.line_set = Dict[Int, Bool]()


def unreliable_lines(text: String, called: Dict[String, Bool], dups: Dict[String, Bool]) -> Dict[Int, Bool]:
    """The lines of `text` an uncompiled report may not count: the own lines of an `@always_inline`
    function, the lines in the arms of a gated one, each only with evidence. `called` holds the calls the hit
    lines of the function's package make (`name`, `.name`, `Receiver.name`); `dups` the names the package
    declares more than once: such a name is evidence only through `Struct.name` for a method of `struct Struct`
    (the receiver of the call named the type), and for none for a free function."""
    var out = Dict[Int, Bool]()
    var fns = declared_functions(text)
    var lines = split_lines(text)
    for k in range(len(fns)):
        # A method (a declaration indented) is called as `x.name(`, a free function as `name(`: a
        # `.name(` call of a same-named method of another type is no evidence for a free function.
        var method = False
        if fns[k].line >= 1 and fns[k].line <= len(lines) and _indent(lines[fns[k].line - 1]) > 0:
            method = True
        if fns[k].name in dups:
            if not method:
                continue
            var owner = _struct_of(lines, fns[k].line)
            if owner.byte_length() == 0 or (owner + String(".") + fns[k].name) not in called:
                continue
        else:
            var key = (String(".") if method else String("")) + fns[k].name
            if key not in called:
                continue
        if fns[k].kind == String(KIND_ALWAYS_INLINE):
            for i in range(len(fns[k].lines)):
                out[fns[k].lines[i]] = True
        elif fns[k].kind == String(KIND_COMPTIME_IF):
            for i in range(len(fns[k].arms)):
                out[fns[k].arms[i]] = True
    return out^


def drop_unreliable(mut f: FileCov, text: String, called: Dict[String, Bool], dups: Dict[String, Bool]) -> Dropped:
    """Removes from `f` (a file of an uncompiled report) every line record, and every branch arm
    on a line, that `unreliable_lines` names; says what it removed."""
    return drop_lines(f, unreliable_lines(text, called, dups))


def drop_lines(mut f: FileCov, lines: Dict[Int, Bool]) -> Dropped:
    """Removes from `f` every line record, and every branch arm on a line, in `lines`; says what it removed."""
    var d = Dropped()
    if len(lines) == 0:
        return d^
    var kept_lines = Dict[Int, Int]()
    for e in f.hits.items():
        if e.key in lines:
            d.lines += 1
            d.line_set[e.key] = True
        else:
            kept_lines[e.key] = e.value
    f.hits = kept_lines^
    var kept = Dict[String, Int]()
    for e in f.branches.items():
        var comma = e.key.find(",")
        var line = parse_count(substr(e.key, 0, comma)) if comma > 0 else -1
        if line in lines:
            d.arms += 1
        else:
            kept[e.key] = e.value
    f.branches = kept^
    return d^
