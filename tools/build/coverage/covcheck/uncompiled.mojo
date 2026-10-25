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
  (its name followed by `(` or `[`, in the code of the line) was hit in a test's report;
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


def _code_words_called(line: String, mut into: Dict[String, Bool]):
    """Adds to `into` each identifier of the code of `line` that is followed by `(` or `[`: what
    the line calls. A comment and the inside of a quoted string are not code."""
    var b = line.as_bytes()
    var n = len(b)
    var quote = 0
    var i = 0
    var start = -1
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
                into[substr(line, start, i)] = True
            start = -1
        i += 1


def names_called_on(text: String, hit: Dict[Int, Bool], mut into: Dict[String, Bool]):
    """Adds to `into` the names the lines of `text` in `hit` (1-based line numbers a test hit) call."""
    var lines = split_lines(text)
    for e in hit.items():
        if e.key >= 1 and e.key <= len(lines):
            _code_words_called(lines[e.key - 1], into)


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


def unreliable_lines(text: String, called: Dict[String, Bool]) -> Dict[Int, Bool]:
    """The lines of `text` an uncompiled report may not count: the own lines of an `@always_inline`
    function, the lines in the arms of a gated one, each only when its name is in `called`."""
    var out = Dict[Int, Bool]()
    var fns = declared_functions(text)
    for k in range(len(fns)):
        if fns[k].name not in called:
            continue
        if fns[k].kind == String(KIND_ALWAYS_INLINE):
            for i in range(len(fns[k].lines)):
                out[fns[k].lines[i]] = True
        elif fns[k].kind == String(KIND_COMPTIME_IF):
            for i in range(len(fns[k].arms)):
                out[fns[k].arms[i]] = True
    return out^


def drop_unreliable(mut f: FileCov, text: String, called: Dict[String, Bool]) -> Dropped:
    """Removes from `f` (a file of an uncompiled report) every line record, and every branch arm
    on a line, that `unreliable_lines` names; says what it removed."""
    var d = Dropped()
    var lines = unreliable_lines(text, called)
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
