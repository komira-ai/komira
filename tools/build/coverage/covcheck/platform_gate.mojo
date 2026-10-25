"""Platform-gated functions: the functions of buildrules' uncompiled report that no build for the
measured target can reach, because every call to them sits in a compile-time arm that build dropped.

A function the report lists as uncompiled and whose callers are all inside `comptime if` /
`@parameter` arms that were not compiled here (an AVX-512 path on a machine without AVX-512, a NEON
path on x86) is not an uncalled function: its callers exist and are dropped on this target. It is
left out of the numbers and listed (`GatedFunction`), whatever its class. The proof is from the
call sites, found in the sources of the function's package (its tests included):

* a call site is a line whose code holds the function's name followed by `(` or `[` (`x.name(` for a
  method, a bare `name(` for a free function; a declaration is no call), as uncompiled.mojo finds
  them. Every call site of the name counts, so a same-named function elsewhere in the package with a
  live call keeps the function counted;
* a call site is **dropped** when it is in a function the reports show compiled (one of its own lines has
  a record), on a line inside one of its compile-time arms that has no record: the build did not
  compile that arm. It is also dropped when it is inside a function that is itself platform-gated (a
  chain: computed to a fixpoint);
* any other call site is live: a line outside every arm, an arm with a record, a function no report
  shows compiled that is not gated, a line outside any function.

A function qualifies only with at least one call site (not counting its own body) and every one
dropped. No call site: it counts as uncovered, as an uncalled function does.
"""

from covcheck.decls import FnDecl, declared_functions
from covcheck.text import split_lines
from covcheck.uncompiled import call_keys


struct Cand(Copyable, Movable):
    """A function with lines in the uncompiled report: its file, name, `def` line and the number of
    its own lines the report lists."""

    var path: String
    var name: String
    var line: Int
    var lines: Int

    def __init__(out self, path: String, name: String, line: Int, lines: Int):
        self.path = path
        self.name = name
        self.line = line
        self.lines = lines


struct _Site(Copyable, Movable):
    var path: String
    var line: Int
    # The innermost function of the file around the call, -1 at the top level.
    var owner: Int

    def __init__(out self, path: String, line: Int, owner: Int):
        self.path = path
        self.line = line
        self.owner = owner


struct _File(Copyable, Movable):
    var fns: List[FnDecl]
    var arm_set: List[Dict[Int, Bool]]
    var compiled: List[Bool]

    def __init__(out self):
        self.fns = List[FnDecl]()
        self.arm_set = List[Dict[Int, Bool]]()
        self.compiled = List[Bool]()


def _key_of(name: String, text_lines: List[String], line: Int) -> String:
    """`name` for a free function (its declaration is not indented), `.name` for a method."""
    if line >= 1 and line <= len(text_lines):
        var b = text_lines[line - 1].as_bytes()
        if len(b) > 0 and (b[0] == UInt8(32) or b[0] == UInt8(9)):
            return String(".") + name
    return name.copy()


def platform_gated(
    texts: Dict[String, String], recorded: Dict[String, Dict[Int, Bool]], cands: List[Cand]
) raises -> List[Bool]:
    """For each candidate (functions of one package whose files are `texts`, path to source), whether it
    is platform-gated. `recorded` holds, per path, the lines any test report gives a record."""
    var files = Dict[String, _File]()
    var file_lines = Dict[String, List[String]]()
    var sites = Dict[String, List[_Site]]()
    var paths = List[String]()
    for e in texts.items():
        paths.append(e.key)
    for pi in range(len(paths)):
        var path = paths[pi]
        var text = texts[path]
        var lines = split_lines(text)
        var fns = declared_functions(text)
        var fi = _File()
        for k in range(len(fns)):
            var arms = Dict[Int, Bool]()
            for a in range(len(fns[k].arms)):
                arms[fns[k].arms[a]] = True
            fi.arm_set.append(arms^)
            var has = False
            for a in range(len(fns[k].lines)):
                if path in recorded and fns[k].lines[a] in recorded[path]:
                    has = True
            fi.compiled.append(has)
        for ln in range(1, len(lines) + 1):
            var keys = call_keys(lines[ln - 1])
            if len(keys) == 0:
                continue
            # The innermost function whose range holds the line.
            var inner = -1
            for k in range(len(fns)):
                if ln > fns[k].line and ln <= fns[k].end:
                    if inner < 0 or fns[k].line > fns[inner].line:
                        inner = k
            for q in range(len(keys)):
                if keys[q] not in sites:
                    sites[keys[q]] = List[_Site]()
                sites[keys[q]].append(_Site(path, ln, inner))
        fi.fns = fns^
        files[path] = fi^
        file_lines[path] = lines^
    var gated = Dict[String, Bool]()  # "<path>:<def line>"
    var out = List[Bool]()
    for _ in range(len(cands)):
        out.append(False)
    var changed = True
    while changed:
        changed = False
        for c in range(len(cands)):
            if out[c]:
                continue
            if cands[c].path not in files or cands[c].path not in file_lines:
                continue
            var key = _key_of(cands[c].name, file_lines[cands[c].path], cands[c].line)
            if key not in sites:
                continue
            var n_sites = 0
            var all_dropped = True
            for s in range(len(sites[key])):
                ref st = sites[key][s]
                # A call inside the function itself (recursion) says nothing about its callers.
                var own = False
                if st.owner >= 0 and st.path == cands[c].path and files[st.path].fns[st.owner].line == cands[c].line:
                    own = True
                if own:
                    continue
                n_sites += 1
                var dropped = False
                if st.owner >= 0:
                    ref g = files[st.path].fns[st.owner]
                    if (st.path + String(":") + String(g.line)) in gated:
                        dropped = True
                    elif files[st.path].compiled[st.owner] and st.line in files[st.path].arm_set[st.owner]:
                        if st.path not in recorded or st.line not in recorded[st.path]:
                            dropped = True
                if not dropped:
                    all_dropped = False
                    break
            if n_sites > 0 and all_dropped:
                out[c] = True
                gated[cands[c].path + String(":") + String(cands[c].line)] = True
                changed = True
    return out^
