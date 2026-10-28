"""Program sources: the `bins` a package's mopm.toml declares.

A package that ships a program names its source in the manifest, in the
`[targets]` table:

    [targets]
    bins = [{ name = "spsc_ring", path = "bins/spsc_ring.mojo" }]

or, the same list as an array of tables:

    [[targets.bins]]
    name = "spsc_ring"
    path = "bins/spsc_ring.mojo"

`path` is relative to the manifest's directory. The program's `main` is
reachable only through the built program, which the census cannot
instrument, so such a file is PROGRAM SOURCE: it is left out of the line and
branch numbers (and is no `UnmeasuredFile`), and it is a finding,
`UnrunProgram`, when no test target of the package runs the built program.
The floor is unchanged: this says what the floor measures.

What "runs" means is evidence, not a reading of the program's text: the
caller passes the repository paths of the program sources whose built
program some test target depends on (`Options.program_runs`, the
`--program-runs` file), which the measuring flow takes from the build graph
(.github/ci/coverage_measure.sh). This module is pure: manifest text and
that set in, programs and findings out.

A `.mojo` path that no manifest names stays ordinary source, and a package
with no `mopm.toml` has no program. A manifest is read for the packages
under analysis only, and read strictly: a `bins` that is not an array of
entries with a quoted `name` and `path`, a `path` that is not a relative
`.mojo` path of the repository, a `[targets.bins]` table, `bins` given
twice or in both shapes, an unterminated value: each is an error naming the
manifest and line, never a silent exclusion. Everything else in a manifest
is skipped, multi-line strings included.
"""

from covcheck.paths import RepoFiles
from covcheck.stats import UNRUN_PROGRAM, Finding
from covcheck.text import byte_at, split_lines, substr, suffix, trim

comptime MANIFEST = "mopm.toml"

comptime _TABLE = 0
comptime _ARRAY = 1
comptime _KEYVAL = 2


struct BinEntry(Copyable, Movable):
    """One `bins` entry as written: its name and its path in the manifest."""

    var name: String
    var path: String

    def __init__(out self, name: String, path: String):
        self.name = name
        self.path = path


struct Program(Copyable, Movable):
    """A program source: the package, the entry's name, the source's
    repository path and the manifest that names it."""

    var package: String
    var name: String
    var path: String
    var manifest: String

    def __init__(out self, package: String, name: String, path: String, manifest: String):
        self.package = package
        self.name = name
        self.path = path
        self.manifest = manifest


struct _Stmt(Copyable, Movable):
    var kind: Int
    var name: String
    var value: String
    var line: Int

    def __init__(out self, kind: Int, name: String, value: String, line: Int):
        self.kind = kind
        self.name = name
        self.value = value
        self.line = line


def _where(origin: String, line: Int) -> String:
    return origin + String(":") + String(line) + String(": ")


def _strip_comment(raw: String) -> String:
    """`raw` without a trailing CR, a `#` comment and the blanks around."""
    var n = raw.byte_length()
    var quote = 0
    var cut = n
    var i = 0
    while i < n:
        var c = byte_at(raw, i)
        if quote != 0:
            if c == 92 and quote == 34:
                i += 2
                continue
            if c == quote:
                quote = 0
        elif c == 34 or c == 39:
            quote = c
        elif c == 35:
            cut = i
            break
        i += 1
    var s = substr(raw, 0, cut)
    while s.byte_length() > 0 and byte_at(s, s.byte_length() - 1) == 13:
        s = substr(s, 0, s.byte_length() - 1)
    return trim(s)


def _depth_delta(s: String) -> Int:
    """The `[` and `{` of `s` outside quotes, less its `]` and `}`."""
    var n = s.byte_length()
    var quote = 0
    var d = 0
    var i = 0
    while i < n:
        var c = byte_at(s, i)
        if quote != 0:
            if c == 92 and quote == 34:
                i += 2
                continue
            if c == quote:
                quote = 0
        elif c == 34 or c == 39:
            quote = c
        elif c == 91 or c == 123:
            d += 1
        elif c == 93 or c == 125:
            d -= 1
        i += 1
    return d


def _find_eq(s: String) -> Int:
    """The first `=` of `s` outside quotes, or -1."""
    var n = s.byte_length()
    var quote = 0
    var i = 0
    while i < n:
        var c = byte_at(s, i)
        if quote != 0:
            if c == 92 and quote == 34:
                i += 2
                continue
            if c == quote:
                quote = 0
        elif c == 34 or c == 39:
            quote = c
        elif c == 61:
            return i
        i += 1
    return -1


def _squeeze(s: String) -> String:
    """`s` without spaces and tabs (a table name written `targets . bins`)."""
    var out = String("")
    for i in range(s.byte_length()):
        var c = byte_at(s, i)
        if c != 32 and c != 9:
            out += substr(s, i, i + 1)
    return out^


def _statements(text: String, origin: String) raises -> List[_Stmt]:
    """Table headers and `key = value` statements; a value that opens a
    bracket or a brace runs to its close, a multi-line string to its closing
    quotes."""
    var lines = split_lines(text)
    var out = List[_Stmt]()
    var i = 0
    while i < len(lines):
        var no = i + 1
        var raw = lines[i].copy()
        var line = _strip_comment(raw)
        i += 1
        if line.byte_length() == 0:
            continue
        if byte_at(line, 0) == 91:
            var array = line.startswith("[[")
            var skip = 2 if array else 1
            if not line.endswith("]]" if array else "]") or line.byte_length() < 2 * skip:
                raise Error(_where(origin, no) + String("a table header that does not end with its brackets: ") + line)
            out.append(_Stmt(_ARRAY if array else _TABLE, _squeeze(substr(line, skip, line.byte_length() - skip)), String(""), no))
            continue
        var eq = _find_eq(line)
        if eq < 0:
            raise Error(_where(origin, no) + String("expected `key = value` or a table header, got: ") + line)
        var key = trim(substr(line, 0, eq))
        var value = trim(suffix(line, eq + 1))
        var delim = String("")
        var rawv = trim(suffix(raw, _find_eq(raw) + 1))
        if rawv.startswith("\"\"\""):
            delim = String("\"\"\"")
        elif rawv.startswith("'''"):
            delim = String("'''")
        if delim.byte_length() > 0:
            var rest = suffix(rawv, 3)
            while rest.find(delim) < 0:
                if i >= len(lines):
                    raise Error(_where(origin, no) + String("a multi-line string that is never closed"))
                rest = lines[i].copy()
                i += 1
            out.append(_Stmt(_KEYVAL, key, String(""), no))
            continue
        var depth = _depth_delta(value)
        while depth > 0:
            if i >= len(lines):
                raise Error(_where(origin, no) + String("a value of `") + key + String("` that is never closed"))
            var more = _strip_comment(lines[i])
            i += 1
            value += String(" ") + more
            depth += _depth_delta(more)
        out.append(_Stmt(_KEYVAL, key, value, no))
    return out^


def _unquote_key(k: String) -> String:
    var n = k.byte_length()
    if n >= 2:
        var a = byte_at(k, 0)
        if (a == 34 or a == 39) and byte_at(k, n - 1) == a:
            return substr(k, 1, n - 1)
    return k.copy()


def _string(value: String, what: String, origin: String, line: Int) raises -> String:
    """The text of a plain quoted string: no escape, no quote inside."""
    var v = trim(value)
    var n = v.byte_length()
    if n >= 2:
        var q = byte_at(v, 0)
        if (q == 34 or q == 39) and byte_at(v, n - 1) == q:
            var inner = substr(v, 1, n - 1)
            var bad = False
            for i in range(inner.byte_length()):
                var c = byte_at(inner, i)
                if c == q or (c == 92 and q == 34):
                    bad = True
            if not bad:
                return inner^
    raise Error(_where(origin, line) + what + String(" must be a plain quoted string (no escape, no quote inside), got: ") + v)


def _check_path(path: String, name: String, origin: String, line: Int) raises:
    var why = String("")
    if path.byte_length() == 0:
        why = String("is empty")
    elif path.startswith("/") or path.find("\\") >= 0:
        why = String("is not a relative path with `/` separators")
    elif not path.endswith(".mojo"):
        why = String("is not a `.mojo` file")
    else:
        var start = 0
        var n = path.byte_length()
        for i in range(n + 1):
            if i == n or byte_at(path, i) == 47:
                var seg = substr(path, start, i)
                if seg.byte_length() == 0 or seg == String(".") or seg == String(".."):
                    why = String("has an empty, `.` or `..` segment")
                start = i + 1
    if why.byte_length() > 0:
        raise Error(_where(origin, line) + String("bins entry `") + name + String("`: path `") + path + String("` ") + why)


def _entry(name: String, has_name: Bool, path: String, has_path: Bool, origin: String, line: Int) raises -> BinEntry:
    if not has_path:
        raise Error(_where(origin, line) + String("a bins entry with no `path`"))
    if not has_name or name.byte_length() == 0:
        raise Error(_where(origin, line) + String("the bins entry for `") + path + String("` has no `name`"))
    _check_path(path, name, origin, line)
    return BinEntry(name, path)


def _inline_table(body: String, origin: String, line: Int) raises -> BinEntry:
    """`name = "..", path = ".."`: the inside of one inline table."""
    var n = body.byte_length()
    var pieces = List[String]()
    var quote = 0
    var start = 0
    var depth = 0
    var i = 0
    while i < n:
        var c = byte_at(body, i)
        if quote != 0:
            if c == 92 and quote == 34:
                i += 2
                continue
            if c == quote:
                quote = 0
        elif c == 34 or c == 39:
            quote = c
        elif c == 91 or c == 123:
            depth += 1
        elif c == 93 or c == 125:
            depth -= 1
        elif c == 44 and depth == 0:
            pieces.append(substr(body, start, i))
            start = i + 1
        i += 1
    pieces.append(substr(body, start, n))
    var name = String("")
    var path = String("")
    var has_name = False
    var has_path = False
    for k in range(len(pieces)):
        var piece = trim(pieces[k])
        if piece.byte_length() == 0:
            if k == len(pieces) - 1 and k > 0:
                continue
            raise Error(_where(origin, line) + String("an empty field in a bins entry"))
        var eq = _find_eq(piece)
        if eq < 0:
            raise Error(_where(origin, line) + String("a bins entry field that is not `key = value`: ") + piece)
        var key = _unquote_key(trim(substr(piece, 0, eq)))
        if key == String("name") or key == String("path"):
            var v = _string(suffix(piece, eq + 1), String("`") + key + String("` of a bins entry"), origin, line)
            if key == String("name"):
                if has_name:
                    raise Error(_where(origin, line) + String("`name` given twice in a bins entry"))
                name = v^
                has_name = True
            else:
                if has_path:
                    raise Error(_where(origin, line) + String("`path` given twice in a bins entry"))
                path = v^
                has_path = True
    return _entry(name, has_name, path, has_path, origin, line)


def _inline_bins(value: String, origin: String, line: Int) raises -> List[BinEntry]:
    var v = trim(value)
    var n = v.byte_length()
    if n < 2 or byte_at(v, 0) != 91 or byte_at(v, n - 1) != 93:
        raise Error(
            _where(origin, line) + String("`bins` must be an array of entries `{ name = \"..\", path = \"..\" }` (or `[[targets.bins]]` tables), got: ") + v
        )
    var inner = substr(v, 1, n - 1)
    var m = inner.byte_length()
    var out = List[BinEntry]()
    var i = 0
    while True:
        while i < m and (byte_at(inner, i) == 32 or byte_at(inner, i) == 9):
            i += 1
        if i >= m:
            break
        if byte_at(inner, i) != 123:
            raise Error(_where(origin, line) + String("each `bins` entry must be an inline table `{ name = \"..\", path = \"..\" }`, got: ") + substr(inner, i, m))
        var quote = 0
        var depth = 0
        var j = i
        var close = -1
        while j < m:
            var c = byte_at(inner, j)
            if quote != 0:
                if c == 92 and quote == 34:
                    j += 2
                    continue
                if c == quote:
                    quote = 0
            elif c == 34 or c == 39:
                quote = c
            elif c == 123:
                depth += 1
            elif c == 125:
                depth -= 1
                if depth == 0:
                    close = j
                    break
            j += 1
        if close < 0:
            raise Error(_where(origin, line) + String("a `bins` entry that is never closed"))
        out.append(_inline_table(substr(inner, i + 1, close), origin, line))
        i = close + 1
        while i < m and (byte_at(inner, i) == 32 or byte_at(inner, i) == 9):
            i += 1
        if i < m:
            if byte_at(inner, i) != 44:
                raise Error(_where(origin, line) + String("`bins` entries must be separated by `,`, got: ") + substr(inner, i, m))
            i += 1
    return out^


def parse_bins(text: String, origin: String) raises -> List[BinEntry]:
    """The `bins` of the manifest `text` (named `origin` in errors): none
    when it declares none. Raises on every shape this module does not read
    (see the module header)."""
    var stmts = _statements(text, origin)
    var table = String("")
    var entries = List[BinEntry]()
    var inline_given = False
    var tables_given = False
    var open_entry = False
    var name = String("")
    var path = String("")
    var has_name = False
    var has_path = False
    var entry_line = 0
    for s in range(len(stmts)):
        ref st = stmts[s]
        if st.kind != _KEYVAL:
            if open_entry:
                entries.append(_entry(name, has_name, path, has_path, origin, entry_line))
                open_entry = False
            if st.name == String("targets.bins") and st.kind == _TABLE:
                raise Error(_where(origin, st.line) + String("`[targets.bins]` is a table: `bins` must be an array (`bins = [{ .. }]` or `[[targets.bins]]`)"))
            if st.name.startswith("targets.bins.") or (st.name == String("targets") and st.kind == _ARRAY):
                raise Error(_where(origin, st.line) + String("`[") + st.name + String("]` is not a shape this tool reads for `bins`"))
            if st.name == String("targets.bins") and st.kind == _ARRAY:
                if inline_given:
                    raise Error(_where(origin, st.line) + String("`bins` is given as an inline array and as `[[targets.bins]]` tables"))
                tables_given = True
                open_entry = True
                name = String("")
                path = String("")
                has_name = False
                has_path = False
                entry_line = st.line
            table = st.name.copy()
            continue
        var key = _unquote_key(st.name)
        if open_entry:
            if key == String("name") or key == String("path"):
                var v = _string(st.value, String("`") + key + String("` of a bins entry"), origin, st.line)
                if key == String("name"):
                    if has_name:
                        raise Error(_where(origin, st.line) + String("`name` given twice in a bins entry"))
                    name = v^
                    has_name = True
                else:
                    if has_path:
                        raise Error(_where(origin, st.line) + String("`path` given twice in a bins entry"))
                    path = v^
                    has_path = True
            continue
        if table == String("") and (key == String("targets") or key.startswith("targets.")):
            raise Error(_where(origin, st.line) + String("`") + key + String("` at the top of the manifest: write `[targets]` as a table, so its `bins` can be read"))
        if table == String("targets") and (key == String("bins") or key.startswith("bins.")):
            if key != String("bins"):
                raise Error(_where(origin, st.line) + String("`") + key + String("`: `bins` must be an array, not a dotted key"))
            if inline_given or tables_given:
                raise Error(_where(origin, st.line) + String("`bins` is given twice"))
            inline_given = True
            entries = _inline_bins(st.value, origin, st.line)
    if open_entry:
        entries.append(_entry(name, has_name, path, has_path, origin, entry_line))
    return entries^


def program_sources(repo: RepoFiles, manifests: Dict[String, String], packages: List[String]) raises -> List[Program]:
    """The programs the manifests of `packages` (directories as package_of
    names them) declare. `manifests` holds the text of each manifest that is a
    file of `repo` (the caller reads them). An entry naming a file that is
    not in the repository is an error: the manifest and the checkout
    disagree."""
    var out = List[Program]()
    for i in range(len(packages)):
        var pkg = packages[i]
        var dir = String("") if pkg == String("(root)") else pkg + String("/")
        var manifest = dir + String(MANIFEST)
        if manifest not in manifests:
            continue
        var bins = parse_bins(manifests[manifest], manifest)
        for k in range(len(bins)):
            var p = dir + bins[k].path
            if not repo.has_file(p):
                raise Error(manifest + String(": bins entry `") + bins[k].name + String("` names ") + p + String(", which is not a file of the repository"))
            out.append(Program(pkg, bins[k].name, p, manifest))
    return out^


def parse_program_runs(text: String) -> Dict[String, Bool]:
    """The `--program-runs` file: one repository path per line (blank lines
    skipped)."""
    var out = Dict[String, Bool]()
    var lines = split_lines(text)
    for i in range(len(lines)):
        var l = trim(lines[i])
        while l.byte_length() > 0 and byte_at(l, l.byte_length() - 1) == 13:
            l = substr(l, 0, l.byte_length() - 1)
        if l.byte_length() > 0:
            out[l] = True
    return out^


def unrun_findings(programs: List[Program], runs: Dict[String, Bool]) -> List[Finding]:
    """An `UnrunProgram` for each program no test target runs."""
    var out = List[Finding]()
    for i in range(len(programs)):
        ref p = programs[i]
        if p.path in runs:
            continue
        out.append(Finding(
            String(UNRUN_PROGRAM), p.package, String(""), -1, -1, p.path, 0,
            String("bins entry `") + p.name + String("` of ") + p.manifest
            + String(" is program source, left out of the numbers, and no test target of the package runs its built program:")
            + String(" add a test (a mojo_test whose data is the program's binary target) that runs it"),
        ))
    return out^
