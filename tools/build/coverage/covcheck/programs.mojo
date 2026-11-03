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
`UnrunProgram`, when no test target of the package depends on the built
program. The floor is unchanged: this says what the floor measures.

What "depends on" means is evidence from the build graph, not a reading of
the program's text: `parse_program_targets` reads the JSON that
`buck2 uquery ... --output-attribute '^(main|srcs)$'` prints for the program
targets (a `mojo_binary_rule`, or a `mojo_unit_rule` of kind `bin`) that a
test target of their own package depends on (`program_query` writes that
query; .github/ci/coverage_measure.sh runs it), and keeps each target's
ENTRY POINT: its `main`, else its one source, when it is a file of the
target's own cell. A target with several sources and no `main` is evidence
for none of them. This module is pure: manifest text and that JSON in, the
query, programs and findings out.

A `.mojo` path that no manifest names stays ordinary source, and a package
with no `mopm.toml` has no program. The manifest is read strictly
(manifest.mojo for the statements): a `bins` that is not an array of
entries with a quoted `name` and `path`, a `path` that is not a relative
`.mojo` path, a `[targets.bins]` table, `bins` given twice or in both
shapes: each is an error naming the manifest and line, never a silent
exclusion. So is an entry naming a file the repository does not have, a
file of another package (a directory below with its own BUCK file), a file
another entry names, or a name another entry has.
"""

from komira_json import JsonValue, parse_json_value

from covcheck.manifest import STMT_ARRAY_TABLE, STMT_KEYVAL, STMT_TABLE, toml_statements, where
from covcheck.paths import RepoFiles, package_of
from covcheck.stats import UNRUN_PROGRAM, Finding
from covcheck.text import byte_at, substr, suffix, trim

comptime MANIFEST = "mopm.toml"


struct BinEntry(Copyable, Movable):
    """One `bins` entry as written: its name, its path in the manifest and
    the manifest line that declares it."""

    var name: String
    var path: String
    var line: Int

    def __init__(out self, name: String, path: String, line: Int):
        self.name = name
        self.path = path
        self.line = line


struct Program(Copyable, Movable):
    """A program source: the package, the entry's name, the source's
    repository path, the manifest that names it and the line there."""

    var package: String
    var name: String
    var path: String
    var manifest: String
    var line: Int

    def __init__(out self, package: String, name: String, path: String, manifest: String, line: Int):
        self.package = package
        self.name = name
        self.path = path
        self.manifest = manifest
        self.line = line


def _string_end(s: String, i: Int) -> Int:
    """Just past the string that starts at `s[i]` (a `"` or `'`), read as the
    manifest scanner reads it: one-line or multi-line (three quotes, which may
    end with up to two more of their own), `\\` escaping in a basic string.
    The scanner has already refused an unclosed string, so the end is found."""
    var n = s.byte_length()
    var q = byte_at(s, i)
    var multi = i + 2 < n and byte_at(s, i + 1) == q and byte_at(s, i + 2) == q
    var j = i + (3 if multi else 1)
    while j < n:
        var c = byte_at(s, j)
        if c == 92 and q == 34:
            j += 2
            continue
        if c == q and (not multi or (j + 2 < n and byte_at(s, j + 1) == q and byte_at(s, j + 2) == q)):
            j += 3 if multi else 1
            var extra = 0
            while multi and extra < 2 and j < n and byte_at(s, j) == q:
                j += 1
                extra += 1
            return j
        j += 1
    return n


def _find_eq(s: String) -> Int:
    """The first `=` of `s` outside strings, or -1."""
    var n = s.byte_length()
    var i = 0
    while i < n:
        var c = byte_at(s, i)
        if c == 34 or c == 39:
            i = _string_end(s, i)
            continue
        if c == 61:
            return i
        i += 1
    return -1


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
    raise Error(where(origin, line) + what + String(" must be a plain quoted string (no escape, no quote inside), got: ") + v)


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
        raise Error(where(origin, line) + String("bins entry `") + name + String("`: path `") + path + String("` ") + why)


def _entry(name: String, has_name: Bool, path: String, has_path: Bool, origin: String, line: Int) raises -> BinEntry:
    if not has_path:
        raise Error(where(origin, line) + String("a bins entry with no `path`"))
    if not has_name or name.byte_length() == 0:
        raise Error(where(origin, line) + String("the bins entry for `") + path + String("` has no `name`"))
    _check_path(path, name, origin, line)
    return BinEntry(name, path, line)


def _inline_table(body: String, origin: String, line: Int) raises -> BinEntry:
    """`name = "..", path = ".."`: the inside of one inline table."""
    var n = body.byte_length()
    var pieces = List[String]()
    var start = 0
    var depth = 0
    var i = 0
    while i < n:
        var c = byte_at(body, i)
        if c == 34 or c == 39:
            i = _string_end(body, i)
            continue
        if c == 91 or c == 123:
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
            raise Error(where(origin, line) + String("an empty field in a bins entry"))
        var eq = _find_eq(piece)
        if eq < 0:
            raise Error(where(origin, line) + String("a bins entry field that is not `key = value`: ") + piece)
        var key = _unquote_key(trim(substr(piece, 0, eq)))
        if key == String("name") or key == String("path"):
            var v = _string(suffix(piece, eq + 1), String("`") + key + String("` of a bins entry"), origin, line)
            if key == String("name"):
                if has_name:
                    raise Error(where(origin, line) + String("`name` given twice in a bins entry"))
                name = v^
                has_name = True
            else:
                if has_path:
                    raise Error(where(origin, line) + String("`path` given twice in a bins entry"))
                path = v^
                has_path = True
    return _entry(name, has_name, path, has_path, origin, line)


def _inline_bins(value: String, origin: String, line: Int) raises -> List[BinEntry]:
    var v = trim(value)
    var n = v.byte_length()
    if n < 2 or byte_at(v, 0) != 91 or byte_at(v, n - 1) != 93:
        raise Error(
            where(origin, line) + String("`bins` must be an array of entries `{ name = \"..\", path = \"..\" }` (or `[[targets.bins]]` tables), got: ") + v
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
            raise Error(where(origin, line) + String("each `bins` entry must be an inline table `{ name = \"..\", path = \"..\" }`, got: ") + substr(inner, i, m))
        # The manifest scanner has matched every brace of the value, so the entry's `}` is found.
        var depth = 0
        var j = i
        var close = m
        while j < m:
            var c = byte_at(inner, j)
            if c == 34 or c == 39:
                j = _string_end(inner, j)
                continue
            if c == 123:
                depth += 1
            elif c == 125:
                depth -= 1
                if depth == 0:
                    close = j
                    break
            j += 1
        out.append(_inline_table(substr(inner, i + 1, close), origin, line))
        i = close + 1
        while i < m and (byte_at(inner, i) == 32 or byte_at(inner, i) == 9):
            i += 1
        if i < m:
            if byte_at(inner, i) != 44:
                raise Error(where(origin, line) + String("`bins` entries must be separated by `,`, got: ") + substr(inner, i, m))
            i += 1
    return out^


def parse_bins(text: String, origin: String) raises -> List[BinEntry]:
    """The `bins` of the manifest `text` (named `origin` in errors): none
    when it declares none. Raises on every shape this module does not read
    (see the module header)."""
    var stmts = toml_statements(text, origin)
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
        if st.kind != STMT_KEYVAL:
            if open_entry:
                entries.append(_entry(name, has_name, path, has_path, origin, entry_line))
                open_entry = False
            if st.name == String("targets.bins") and st.kind == STMT_TABLE:
                raise Error(where(origin, st.line) + String("`[targets.bins]` is a table: `bins` must be an array (`bins = [{ .. }]` or `[[targets.bins]]`)"))
            if st.name.startswith("targets.bins.") or (st.name == String("targets") and st.kind == STMT_ARRAY_TABLE):
                raise Error(where(origin, st.line) + String("`[") + st.name + String("]` is not a shape this tool reads for `bins`"))
            if st.name == String("targets.bins") and st.kind == STMT_ARRAY_TABLE:
                if inline_given:
                    raise Error(where(origin, st.line) + String("`bins` is given as an inline array and as `[[targets.bins]]` tables"))
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
                        raise Error(where(origin, st.line) + String("`name` given twice in a bins entry"))
                    name = v^
                    has_name = True
                else:
                    if has_path:
                        raise Error(where(origin, st.line) + String("`path` given twice in a bins entry"))
                    path = v^
                    has_path = True
            continue
        if table == String("") and (key == String("targets") or key.startswith("targets.")):
            raise Error(where(origin, st.line) + String("`") + key + String("` at the top of the manifest: write `[targets]` as a table, so its `bins` can be read"))
        if table == String("targets") and (key == String("bins") or key.startswith("bins.")):
            if key != String("bins"):
                raise Error(where(origin, st.line) + String("`") + key + String("`: `bins` must be an array, not a dotted key"))
            if inline_given or tables_given:
                raise Error(where(origin, st.line) + String("`bins` is given twice"))
            inline_given = True
            entries = _inline_bins(st.value, origin, st.line)
    if open_entry:
        entries.append(_entry(name, has_name, path, has_path, origin, entry_line))
    return entries^


def program_sources(repo: RepoFiles, manifests: Dict[String, String], packages: List[String]) raises -> List[Program]:
    """The programs the manifests of `packages` (directories as package_of
    names them) declare. `manifests` holds the text of each manifest that is a
    file of `repo` (the caller reads them). An entry naming a file that is
    not in the repository, a file of another package, a file another entry
    names or a name another entry of the manifest has is an error naming the
    manifest and the entry's line."""
    var out = List[Program]()
    var named = Dict[String, String]()
    for i in range(len(packages)):
        var pkg = packages[i]
        var dir = String("") if pkg == String("(root)") else pkg + String("/")
        var manifest = dir + String(MANIFEST)
        if manifest not in manifests:
            continue
        var bins = parse_bins(manifests[manifest], manifest)
        var names = Dict[String, Int]()
        for k in range(len(bins)):
            ref b = bins[k]
            var p = dir + b.path
            var at = where(manifest, b.line) + String("bins entry `") + b.name + String("` names ") + p
            if not repo.has_file(p):
                raise Error(at + String(", which is not a file of the repository"))
            var owner = package_of(p, repo)
            if owner != pkg:
                raise Error(at + String(", which is a file of the package ") + owner + String(", not of ") + pkg)
            if p in named:
                raise Error(at + String(", which ") + named[p] + String(" names too"))
            if b.name in names:
                raise Error(
                    where(manifest, b.line) + String("bins entry `") + b.name + String("`: the entry of line ")
                    + String(names[b.name]) + String(" has that name too")
                )
            named[p] = where(manifest, b.line) + String("bins entry `") + b.name + String("`")
            names[b.name] = b.line
            out.append(Program(pkg, b.name, p, manifest, b.line))
    return out^


def _repo_path(label_path: String, origin: String) raises -> String:
    """`<cell>//<path>` (or `<cell>//<package>:<path>`) as a repository path."""
    var at = label_path.find("//")
    if at < 0:
        raise Error(origin + String(": a source that is not `<cell>//<path>`: ") + label_path)
    var rest = suffix(label_path, at + 2)
    var colon = rest.find(":")
    if colon < 0:
        return rest^
    if colon == 0:
        return suffix(rest, 1)
    return substr(rest, 0, colon) + String("/") + suffix(rest, colon + 1)


def _cell(label: String) -> String:
    """The cell of a label or source the caller has checked is `<cell>//...`: the text before `//`."""
    return substr(label, 0, label.find("//"))


def _json(text: String, origin: String) raises -> JsonValue:
    try:
        return parse_json_value(text)
    except e:
        raise Error(origin + String(": not the JSON of a buck2 uquery: ") + String(e))


def parse_program_targets(text: String, origin: String) raises -> Dict[String, Bool]:
    """The entry points, as repository paths, of the program targets in
    `text`: buck2's JSON for `uquery ... --output-attribute '^(main|srcs)$'`,
    an object of target label to its attributes. A target's entry point is
    its `main`, else its one source; one with several sources and no `main`
    gives none, and so does an entry point of another cell than the target's
    (another repository's file, though its path may read the same). Anything else than that shape is an error naming `origin`
    (an empty file included: the query always writes an object)."""
    var doc = _json(text, origin)
    if not doc.is_object():
        raise Error(origin + String(": not a JSON object of target labels"))
    var out = Dict[String, Bool]()
    for i in range(doc.num_members()):
        var label = doc.key_at(i)
        var attrs = doc.value_at(i)
        if label.find("//") < 0:
            raise Error(origin + String(": a target label that is not `<cell>//<package>:<name>`: ") + label)
        if not attrs.is_object():
            raise Error(origin + String(": ") + label + String(": not an object of attributes"))
        var main = String("")
        if attrs.has(String("main")):
            var m = attrs.get(String("main"))
            if m.is_string():
                main = m.as_string()
            elif not m.is_null():
                raise Error(origin + String(": ") + label + String(": `main` is neither a path nor null"))
        var srcs = List[String]()
        if attrs.has(String("srcs")):
            var sv = attrs.get(String("srcs"))
            if not sv.is_array():
                raise Error(origin + String(": ") + label + String(": `srcs` is not a list"))
            for k in range(len(sv.children)):
                if not sv.children[k].is_string():
                    raise Error(origin + String(": ") + label + String(": a source in `srcs` is not a path"))
                srcs.append(sv.children[k].as_string())
        var entry = String("")
        if main.byte_length() > 0:
            entry = main^
        elif len(srcs) == 1:
            entry = srcs[0]
        if entry.byte_length() == 0:
            continue
        var path = _repo_path(entry, origin)
        # A source of another cell is not this repository's file, though its path may read the same.
        if _cell(entry) == _cell(label):
            out[path] = True
    return out^


def unrun_findings(programs: List[Program], runs: Dict[String, Bool]) -> List[Finding]:
    """An `UnrunProgram` for each program no test target depends on."""
    var out = List[Finding]()
    for i in range(len(programs)):
        ref p = programs[i]
        if p.path in runs:
            continue
        out.append(Finding(
            String(UNRUN_PROGRAM), p.package, String(""), -1, -1, p.path, 0,
            String("bins entry `") + p.name + String("` of ") + p.manifest
            + String(" is program source, left out of the numbers, and no test target of the package depends on its built program:")
            + String(" add a test (a mojo_test whose data is the program's binary target) that runs it"),
        ))
    return out^


def program_query(repo: RepoFiles, packages: List[String]) raises -> String:
    """The `buck2 uquery` expression whose answer is the program targets'
    file (`parse_program_targets`): for each of `packages` (repository
    directories, the empty string for the root package) whose `mopm.toml` is
    a file of `repo`, the program targets of that package (a
    `mojo_binary_rule`, or a `mojo_unit_rule` of kind `bin`) that a test
    target of that package (a `mojo_test_rule` or `mojo_test_run_rule`)
    depends on; one selection per package, joined, so a test of another
    package is no evidence. The empty string when no package has a manifest:
    no query is run, and no program is declared. A directory holding a
    character a target pattern cannot is an error."""
    var out = String("")
    for i in range(len(packages)):
        var p = packages[i]
        var manifest = String(MANIFEST) if p.byte_length() == 0 else p + String("/") + String(MANIFEST)
        if not repo.has_file(manifest):
            continue
        for k in range(p.byte_length()):
            var c = byte_at(p, k)
            var ok = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 46 or c == 47 or c == 43 or c == 45
            if not ok:
                raise Error(String("package directory '") + p + String("' holds a character a target pattern cannot"))
        var tdeps = String("deps(kind('^mojo_test(_run)?_rule$', //") + p + String(":))")
        var sel = (
            String("((kind('^mojo_binary_rule$', ") + tdeps + String(") + attrfilter('kind', 'bin', kind('^mojo_unit_rule$', ")
            + tdeps + String("))) intersect //") + p + String(":)")
        )
        if out.byte_length() > 0:
            out += String(" + ")
        out += sel
    return out^
