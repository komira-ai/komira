"""The changed lines of a change: the new-side line numbers each file of
`git diff --no-color --no-ext-diff --unified=0 -M <base> <head>` adds or
modifies, keyed by the file's new path.

Read per `diff --git` block: the `diff --git a/<path> b/<path>` line,
`old mode`/`new mode`, `new file mode`,
`deleted file mode`, `similarity index`, `dissimilarity index`,
`rename from`/`rename to`, `copy from`/`copy to`, `index`, `Binary files`,
`--- a/<path>` (or `/dev/null`), `+++ b/<path>` (or `/dev/null`) and hunks
`@@ -a[,b] +c[,d] @@` (an omitted count is 1). A hunk's body is read by its
counts, so a removed line that starts `--- ` is never taken for a header.
A rename attributes its lines to the new path; a pure rename, a deletion, a
binary file and a mode change add no line. Git's C-quoted paths
(`"b/sp\\303\\251cial \\"x\\""`: octal bytes and `\\a \\b \\t \\n \\v \\f
\\r \\" \\\\`) are unquoted, and the tab git writes after an unquoted path
that holds a space is dropped.

Every path a block names touches its package (`Diff.paths`), whether or not
it gains lines: the `---`/`+++` paths, `rename from`/`rename to`,
`copy to`, and the two paths of the `diff --git` line when they can be told
apart (each is quoted, or they are the same path, as for a binary file, a
mode change or an empty file, which have no `---`/`+++` lines). A copy's
source is not changed, so `copy from` names nothing.

A carriage return is file content inside a hunk body (a changed line of a
CRLF file ends in one) and is kept there; git quotes a path that holds one,
so anywhere else it is refused.

Refused, naming `<origin>:<line>` (`origin` is the diff file): text before
the first `diff --git`, a line that is none of the above, a carriage return
outside a hunk body, a hunk before `+++`, a hunk body whose lines disagree
with its counts, a hunk line number above 10^9, a path without the
`a/`/`b/` prefix (a diff made with `--no-prefix`, `diff.noprefix=true` or
another prefix: give `--src-prefix=a/ --dst-prefix=b/`).
"""

from covcheck.text import MAX_LINE, byte_at, has_byte, parse_count, split_lines, substr, suffix


struct ChangedFile(Copyable, Movable):
    """A file's new path and its added or modified lines, ascending."""

    var path: String
    var lines: List[Int]

    def __init__(out self, path: String):
        self.path = path
        self.lines = List[Int]()


struct Diff(Copyable, Movable):
    """The files that gain lines (`files`, in diff order), and every path
    the diff names (`paths`, old and new, each once, in diff order; see the
    module header): a deleted file's package is touched by the change as
    much as an edited file's."""

    var files: List[ChangedFile]
    var paths: List[String]

    def __init__(out self):
        self.files = List[ChangedFile]()
        self.paths = List[String]()

    def name(mut self, path: String):
        for i in range(len(self.paths)):
            if self.paths[i] == path:
                return
        self.paths.append(path)


def _fail(origin: String, line_no: Int, why: String) raises:
    raise Error(origin + String(":") + String(line_no) + String(": ") + why)


def unquote_c(s: String, origin: String, line_no: Int) raises -> String:
    """Git's C-quoted path (`s` starts with `"`), unquoted; a single tab
    after the closing quote is allowed."""
    var out = List[UInt8]()
    var n = s.byte_length()
    var i = 1
    while i < n:
        var c = byte_at(s, i)
        if c == 34:
            var rest = suffix(s, i + 1)
            if rest.byte_length() > 0 and rest != String("\t"):
                _fail(origin, line_no, String("text after a quoted path: ") + s)
            return String(from_utf8_lossy=out)
        if c != 92:
            out.append(UInt8(c))
            i += 1
            continue
        if i + 1 >= n:
            break
        var e = byte_at(s, i + 1)
        if e >= 48 and e <= 55:
            if i + 3 >= n:
                _fail(origin, line_no, String("a short octal escape in ") + s)
            var v = 0
            for k in range(1, 4):
                var d = byte_at(s, i + k)
                if d < 48 or d > 55:
                    _fail(origin, line_no, String("a malformed octal escape in ") + s)
                v = v * 8 + (d - 48)
            if v > 255:
                _fail(origin, line_no, String("an octal escape above 377 in ") + s)
            out.append(UInt8(v))
            i += 4
            continue
        var m = -1
        if e == 97:
            m = 7
        elif e == 98:
            m = 8
        elif e == 116:
            m = 9
        elif e == 110:
            m = 10
        elif e == 118:
            m = 11
        elif e == 102:
            m = 12
        elif e == 114:
            m = 13
        elif e == 34:
            m = 34
        elif e == 92:
            m = 92
        if m < 0:
            _fail(origin, line_no, String("an unknown escape in ") + s)
        out.append(UInt8(m))
        i += 2
    _fail(origin, line_no, String("an unterminated quoted path: ") + s)
    return String("")


def _path(raw: String, prefix: String, origin: String, line_no: Int) raises -> String:
    """A `---`/`+++` or `rename to` path: unquoted, its tab dropped, its
    `prefix` (`a/`, `b/` or none) removed."""
    var p: String
    if raw.startswith("\""):
        p = unquote_c(raw, origin, line_no)
    else:
        p = raw
        if p.endswith("\t"):
            p = substr(p, 0, p.byte_length() - 1)
    if prefix.byte_length() == 0:
        return p^
    if not p.startswith(prefix):
        _fail(origin, line_no, String("path '") + p + String("' lacks the '") + prefix + String("' prefix (make the diff without --no-prefix)"))
    return suffix(p, prefix.byte_length())


def _range(spec: String, origin: String, line_no: Int) raises -> List[Int]:
    """`a[,b]` as [a, b]; an omitted b is 1."""
    var comma = spec.find(",")
    var a: Int
    var b = 1
    if comma < 0:
        a = parse_count(spec)
    else:
        a = parse_count(substr(spec, 0, comma))
        b = parse_count(suffix(spec, comma + 1))
    if a < 0 or b < 0:
        _fail(origin, line_no, String("a malformed hunk range '") + spec + String("'"))
    if a > MAX_LINE or b > MAX_LINE:
        _fail(origin, line_no, String("a hunk range above 10^9 lines '") + spec + String("'"))
    var r = List[Int]()
    r.append(a)
    r.append(b)
    return r^


def _quoted_end(s: String, start: Int) -> Int:
    """The index just past the closing quote of the C-quoted string that
    starts at `start`, or -1."""
    var n = s.byte_length()
    var i = start + 1
    while i < n:
        var c = byte_at(s, i)
        if c == 92:
            i += 2
            continue
        if c == 34:
            return i + 1
        i += 1
    return -1


def _header_paths(rest: String, origin: String, line_no: Int) raises -> List[String]:
    """The two paths of a `diff --git <a> <b>` line (`rest` is what follows
    `diff --git `), prefixes removed, when they can be told apart: a quoted
    name ends at its closing quote (git quotes a name holding a quote, so an
    unquoted name ends before the first quote); two unquoted names are split
    only when they are the same path. Otherwise none (a rename or copy names
    its paths on its own lines)."""
    var out = List[String]()
    var n = rest.byte_length()
    var a: String
    var b: String
    if rest.startswith("\""):
        var e = _quoted_end(rest, 0)
        if e < 0 or e >= n or byte_at(rest, e) != 32:
            _fail(origin, line_no, String("a malformed 'diff --git' line"))
        a = substr(rest, 0, e)
        b = suffix(rest, e + 1)
    else:
        var q = rest.find("\"")
        if q >= 0:
            if q == 0 or byte_at(rest, q - 1) != 32:
                _fail(origin, line_no, String("a malformed 'diff --git' line"))
            a = substr(rest, 0, q - 1)
            b = suffix(rest, q)
        else:
            if n % 2 == 0:
                return out^
            var half = (n - 1) // 2
            if byte_at(rest, half) != 32:
                return out^
            a = substr(rest, 0, half)
            b = suffix(rest, half + 1)
            if a == b:
                _fail(origin, line_no, String("path '") + a + String("' lacks the 'a/' prefix (make the diff without --no-prefix)"))
            if not a.startswith("a/") or not b.startswith("b/") or suffix(a, 2) != suffix(b, 2):
                return out^
    out.append(_path(a, String("a/"), origin, line_no))
    out.append(_path(b, String("b/"), origin, line_no))
    return out^


def _is_ignored_header(line: String) -> Bool:
    """The extended header lines that add no line."""
    return (
        line.startswith("old mode ") or line.startswith("new mode ")
        or line.startswith("new file mode ") or line.startswith("deleted file mode ")
        or line.startswith("similarity index ") or line.startswith("dissimilarity index ")
        or line.startswith("copy from ")
        or line.startswith("index ") or line.startswith("Binary files ")
    )


def parse_diff(text: String, origin: String = "diff") raises -> Diff:
    """The changed lines and the named paths of the diff `text` (`origin`
    names it in errors)."""
    var out = Diff()
    var lines = split_lines(text)
    var in_file = False
    var current = ChangedFile(String(""))
    var have_new = False
    var old_left = 0
    var new_left = 0
    var new_at = 0
    var i = 0
    while i < len(lines):
        var n = i + 1
        var line = lines[i]
        i += 1
        if old_left > 0 or new_left > 0:
            if line.startswith("+"):
                if new_left == 0:
                    _fail(origin, n, String("more added lines than the hunk counts"))
                current.lines.append(new_at)
                new_at += 1
                new_left -= 1
            elif line.startswith("-"):
                if old_left == 0:
                    _fail(origin, n, String("more removed lines than the hunk counts"))
                old_left -= 1
            elif line.startswith(" ") or line.byte_length() == 0:
                if old_left == 0 or new_left == 0:
                    _fail(origin, n, String("a context line past the hunk's counts"))
                old_left -= 1
                new_left -= 1
                new_at += 1
            elif line.startswith("\\"):
                pass
            else:
                _fail(origin, n, String("the hunk ends early: '") + line + String("'"))
            continue
        if has_byte(line, 13):
            _fail(origin, n, String("carriage return outside a hunk body (git quotes a path that holds one)"))
        if line.startswith("\\"):
            # `\ No newline at end of file` after a hunk's last line.
            continue
        if line.startswith("diff --git "):
            if in_file and len(current.lines) > 0:
                out.files.append(current.copy())
            current = ChangedFile(String(""))
            in_file = True
            have_new = False
            var hp = _header_paths(suffix(line, 11), origin, n)
            for k in range(len(hp)):
                out.name(hp[k])
            continue
        if not in_file:
            if line.byte_length() == 0:
                continue
            _fail(origin, n, String("text before the first 'diff --git': '") + line + String("'"))
        if line.byte_length() == 0:
            continue
        if line.startswith("rename to ") or line.startswith("copy to "):
            var at = 10 if line.startswith("rename to ") else 8
            current.path = _path(suffix(line, at), String(""), origin, n)
            have_new = True
            out.name(current.path)
        elif line.startswith("rename from "):
            out.name(_path(suffix(line, 12), String(""), origin, n))
        elif line.startswith("--- "):
            var p = suffix(line, 4)
            if p != String("/dev/null"):
                out.name(_path(p, String("a/"), origin, n))
        elif line.startswith("+++ "):
            var p = suffix(line, 4)
            if p == String("/dev/null"):
                current.path = String("")
                have_new = False
            else:
                current.path = _path(p, String("b/"), origin, n)
                have_new = True
                out.name(current.path)
        elif line.startswith("@@ "):
            var close = line.find(" @@", 3)
            if close < 0:
                _fail(origin, n, String("a malformed hunk header"))
            var spec = substr(line, 3, close)
            var sp = spec.find(" ")
            if not spec.startswith("-") or sp < 0 or sp + 1 >= spec.byte_length() or byte_at(spec, sp + 1) != 43:
                _fail(origin, n, String("a malformed hunk header"))
            var old_r = _range(substr(spec, 1, sp), origin, n)
            var new_r = _range(suffix(spec, sp + 2), origin, n)
            if new_r[1] > 0 and not have_new:
                _fail(origin, n, String("a hunk adding lines to no file (no '+++ b/<path>' before it)"))
            old_left = old_r[1]
            new_left = new_r[1]
            new_at = new_r[0]
        elif _is_ignored_header(line):
            continue
        else:
            _fail(origin, n, String("not a diff line: '") + line + String("'"))
    if old_left > 0 or new_left > 0:
        _fail(origin, len(lines), String("the last hunk ends early"))
    if in_file and len(current.lines) > 0:
        out.files.append(current.copy())
    return out^
