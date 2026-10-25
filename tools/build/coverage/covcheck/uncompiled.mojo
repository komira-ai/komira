"""The reports of the code no test compiled (buildrules' `uncompiled.cobertura.xml` and
`uncompiled.branches.info`, the last report and branch record file of a mojo_package's `:coverage`).

buildrules reads the sources for the functions no test compiled and writes their executable lines
as found and not hit, and the arms of their decision words as not taken. It reads a function as
uncompiled when none of its own lines has a record, which is also what a function the compiler
inlined into its callers looks like (a test calls it, and what is left of it is attributed to a
caller's lines), and a function whose code is wholly in a `comptime if` arm dropped on this platform
(decls.mojo, "Each listed function has a `kind`"). Those are the two classes `unrecorded_functions`
keeps apart from `plain`: no evidence that no test reaches the function. So the lines and arms of
an unreliable-class function in an uncompiled report are left out of the numbers, as the function
is left out of the plain list; the function stays in `unrecorded_functions_unreliable`, which says
what was left out. A `plain` function (and every line of a file no test compiled at all) is
counted, as it is without this report.

The reports are told by their file name, the one buildrules gives them (docs/contract.md of
buildrules, "uncompiled"): the name is the only thing that sets them apart from a test's report.
"""

from covcheck.decls import KIND_PLAIN, declared_functions
from covcheck.model import FileCov
from covcheck.text import parse_count, substr

comptime UNCOMPILED_LINES_NAME = "uncompiled.cobertura.xml"
comptime UNCOMPILED_BRANCHES_NAME = "uncompiled.branches.info"


def _base(origin: String) -> String:
    var slash = origin.rfind("/")
    if slash < 0:
        return origin
    return substr(origin, slash + 1, origin.byte_length())


def is_uncompiled_report(origin: String) -> Bool:
    """Whether the report or branch record file named `origin` is buildrules' report of the code no
    test compiled."""
    var b = _base(origin)
    return b == String(UNCOMPILED_LINES_NAME) or b == String(UNCOMPILED_BRANCHES_NAME)


def unreliable_lines(text: String) -> Dict[Int, Bool]:
    """The own executable lines of every function of `text` whose class is not `plain`."""
    var out = Dict[Int, Bool]()
    var fns = declared_functions(text)
    for k in range(len(fns)):
        if fns[k].kind == String(KIND_PLAIN):
            continue
        for i in range(len(fns[k].lines)):
            out[fns[k].lines[i]] = True
    return out^


def drop_unreliable(mut f: FileCov, text: String):
    """Removes from `f` (a file of an uncompiled report) every line record, and every branch arm
    on a line, that is an own line of an unreliable-class function of `text`."""
    var lines = unreliable_lines(text)
    if len(lines) == 0:
        return
    var kept_lines = Dict[Int, Int]()
    for e in f.hits.items():
        if e.key not in lines:
            kept_lines[e.key] = e.value
    f.hits = kept_lines^
    var kept = Dict[String, Int]()
    for e in f.branches.items():
        var comma = e.key.find(",")
        var line = parse_count(substr(e.key, 0, comma)) if comma > 0 else -1
        if line not in lines:
            kept[e.key] = e.value
    f.branches = kept^
