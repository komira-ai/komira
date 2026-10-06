"""Coverage exemptions: the lines a source file marks as untestable.

The one marker form is an end-of-line comment: the line's comment (its
first `#` outside every string literal, as lexer.mojo finds it), at the
start of the line or after a space or tab, is exactly the bytes
`# cov: unreachable` followed by either the end of the line or one space
and the reason (the rest of the line, without surrounding blanks). It
exempts the line it is on, and nothing else. Anything that is not exactly
that is not a marker: `#cov:`, `# cov:unreachable`, `# Cov: unreachable`,
`# cov: unreachable:`, `# cov: unreachables`, `##cov: unreachable`, a
marker inside a word, after a quote, inside a string literal or a
docstring (one line or several), or after another comment's text
(`# see # cov: unreachable`) all leave the line counted. A trailing
carriage return (a CRLF file) is not part of the line.

What a marker does depends on the line's record (see `apply_exemptions`):

- `exempt`: the line has a record with 0 hits. It leaves the line count
  (found) and its branches leave the branch count.
- `exempt branches`: the line was hit (or has no line record) and some of
  its branches were never taken (a defensive check whose failure path
  cannot happen). The line stays counted (covered); its branches leave the
  branch count.
- `stale`: the line was hit and every branch on it (if any) was taken.
  Nothing changes; a `StaleExemption` finding says the marker should go.
- `no record`: the report has no record for the line and no untaken branch
  on it (the compiler emitted no code for it). Nothing changes.
- `no reason`: the marker has no reason. Nothing changes; an
  `ExemptionWithoutReason` finding asks for one.

Every marker in a measured file is listed: each needs a reviewer's approval.
"""

from covcheck.lexer import LexState, lex_line, lex_source
from covcheck.model import FileCov, branch_line
from covcheck.text import byte_at, suffix, trim

comptime MARKER = "# cov: unreachable"

comptime STATUS_EXEMPT = "exempt"
comptime STATUS_EXEMPT_BRANCHES = "exempt branches"
comptime STATUS_STALE = "stale"
comptime STATUS_NO_RECORD = "no record"
comptime STATUS_NO_REASON = "no reason"


struct Exemption(Copyable, Movable):
    """One marker: where it is, why, and what it did."""

    var path: String
    var line: Int
    var reason: String
    var status: String

    def __init__(out self, path: String, line: Int, reason: String, status: String):
        self.path = path
        self.line = line
        self.reason = reason
        self.status = status


struct Marker(Copyable, Movable):
    """Whether a line holds a marker, and its reason."""

    var found: Bool
    var reason: String

    def __init__(out self, found: Bool, reason: String):
        self.found = found
        self.reason = reason


def marker_at(text: String, comment: Int) -> Marker:
    """The marker of a lexed line: `text` without its carriage return,
    `comment` the offset of its comment's `#` (-1: none)."""
    if comment < 0:
        return Marker(False, String(""))
    if comment > 0:
        var before = byte_at(text, comment - 1)
        if before != 32 and before != 9:
            return Marker(False, String(""))
    var rest = suffix(text, comment)
    if not rest.startswith(MARKER):
        return Marker(False, String(""))
    var end = comment + String(MARKER).byte_length()
    if end == text.byte_length():
        return Marker(True, String(""))
    if byte_at(text, end) != 32:
        return Marker(False, String(""))
    return Marker(True, trim(suffix(text, end + 1)))


def marker_in(line: String) -> Marker:
    """The marker of `line` read on its own (outside any string at its
    start), if any; see the module header."""
    var st = LexState()
    var l = lex_line(line, st)
    return marker_at(l.text, l.comment)


def scan_markers(path: String, text: String) -> List[Exemption]:
    """Every marker of the source `text` of `path`, by line, with no status
    yet. The lines are lexed in order, so a line inside a string spanning
    lines holds no comment."""
    var out = List[Exemption]()
    var lines = lex_source(text)
    for i in range(len(lines)):
        var m = marker_at(lines[i].text, lines[i].comment)
        if m.found:
            out.append(Exemption(path, i + 1, m.reason, String("")))
    return out^


def _drop_branches(mut f: FileCov, line: Int) raises:
    var gone = List[String]()
    for e in f.branches.items():
        if branch_line(e.key) == line:
            gone.append(e.key)
    for k in range(len(gone)):
        _ = f.branches.pop(gone[k])


def _untaken_branches(f: FileCov, line: Int) -> Int:
    var n = 0
    for e in f.branches.items():
        if e.value == 0 and branch_line(e.key) == line:
            n += 1
    return n


def apply_exemptions(mut f: FileCov, mut markers: List[Exemption]) raises -> Int:
    """Sets each marker's status and takes the `exempt` lines, and the
    branches of `exempt` and `exempt branches` lines, out of `f`; returns
    how many lines left the line count."""
    var removed = 0
    for i in range(len(markers)):
        var line = markers[i].line
        if markers[i].reason.byte_length() == 0:
            markers[i].status = String(STATUS_NO_REASON)
        elif line in f.hits and f.hits[line] == 0:
            markers[i].status = String(STATUS_EXEMPT)
            _ = f.hits.pop(line)
            removed += 1
            _drop_branches(f, line)
        elif _untaken_branches(f, line) > 0:
            markers[i].status = String(STATUS_EXEMPT_BRANCHES)
            _drop_branches(f, line)
        elif line in f.hits:
            markers[i].status = String(STATUS_STALE)
        else:
            markers[i].status = String(STATUS_NO_RECORD)
    return removed
