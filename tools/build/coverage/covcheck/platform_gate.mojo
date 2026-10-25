"""Platform-gated functions: the functions of buildrules' uncompiled report that no build for the
measured target can reach, because every use of them sits in a compile-time arm that build dropped.

A function the report lists as uncompiled and whose uses are all inside `comptime if` /
`@parameter` arms that were not compiled here (an AVX-512 path on a machine without AVX-512, a NEON
path on x86) is not an uncalled function: its callers exist and are dropped on this target. It is
left out of the numbers and listed (`GatedFunction`), whatever its class. The proof is from the
uses, found in the sources of the function's package (its tests included). This direction hides code,
so a use is anything that could be one:

* a **use** is any occurrence of the function's name as an identifier in the code of the package:
  a call (`name(`, `x.name(`, `mod.name(`), a function passed as a value (`map(name)`), a method
  reference. Comments, strings (a multi-line string's interior too), import lines and the function's own
  declaration name are not uses. An alias (`from x import name as z`) makes every use of `z` a use of
  `name`. Every use of the name counts, so a same-named function elsewhere in the package that is
  used live keeps the function counted;
* a use is **dropped** when it is in a function the reports show compiled (one of its own lines has a
  record), inside one of that function's compile-time arms, **and no line of that arm has a record**: the
  arm was not compiled. One line without a record is not enough: a continuation line of a multi-line
  call, or a line the compiler attributed elsewhere, sits in an arm that was compiled. A use on the
  line of the `comptime if` condition itself is live (the condition runs whichever arm is compiled). A
  use inside a function that is itself platform-gated is dropped too (a chain: computed to a fixpoint);
* any other use is live: a line outside every arm, an arm with a record, a function no report shows
  compiled that is not gated, a line outside any function.

A function qualifies only with at least one use (not counting its own body) and every use dropped.
No use: it counts as uncovered, as an uncalled function does. A group of functions that call only
each other, reachable only from a dropped arm, is not gated either: the fixpoint starts from nothing
gated and each function needs a dropped use, so such a cycle stays counted.
"""

from covcheck.decls import FnDecl, declared_functions
from covcheck.lexer import lex_source


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
    # The innermost function of the file around the use, -1 at the top level.
    var owner: Int

    def __init__(out self, path: String, line: Int, owner: Int):
        self.path = path
        self.line = line
        self.owner = owner


struct _File(Copyable, Movable):
    var fns: List[FnDecl]
    var compiled: List[Bool]

    def __init__(out self):
        self.fns = List[FnDecl]()
        self.compiled = List[Bool]()


def _is_ident(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def _tokens(line: String) -> List[String]:
    """The identifiers of the code of `line`, in order: not those in a comment or inside a quoted string."""
    var out = List[String]()
    var b = line.as_bytes()
    var n = len(b)
    var quote = 0
    var i = 0
    var start = -1
    while i <= n:
        var c = -1
        if i < n:
            c = Int(b[i])
        if quote != 0:
            if c == 92:
                i += 2
                continue
            if c == quote:
                quote = 0
            i += 1
            continue
        if c >= 0 and _is_ident(c):
            if start < 0:
                start = i
        else:
            if start >= 0:
                # A number (digits first) is no name.
                var first = Int(b[start])
                if not (first >= 48 and first <= 57):
                    out.append(String(line[byte=start:i]))
                start = -1
            if c == 35:
                break
            if c == 34 or c == 39:
                quote = c
        i += 1
    return out^


def _aliases(lines_text: List[String], is_import: List[Bool]) -> Dict[String, String]:
    """`alias` to `name` for every `name as alias` of the import lines."""
    var out = Dict[String, String]()
    for i in range(len(lines_text)):
        if not is_import[i]:
            continue
        var t = _tokens(lines_text[i])
        for k in range(len(t) - 2):
            if t[k + 1] == String("as"):
                out[t[k + 2]] = t[k]
    return out^


def platform_gated(
    texts: Dict[String, String], recorded: Dict[String, Dict[Int, Bool]], cands: List[Cand]
) raises -> List[Bool]:
    """For each candidate (functions of one package whose files are `texts`, path to source), whether it
    is platform-gated. `recorded` holds, per path, the lines any test report gives a record."""
    var files = Dict[String, _File]()
    var sites = Dict[String, List[_Site]]()
    var track = Dict[String, Bool]()
    for c in range(len(cands)):
        track[cands[c].name] = True
    var paths = List[String]()
    for e in texts.items():
        paths.append(e.key)
    # The aliases of the package: a use of one is a use of the name it stands for.
    var alias_of = Dict[String, String]()
    var lexed = Dict[String, List[Bool]]()  # per path: the lines that are code and not inside a string
    for pi in range(len(paths)):
        var ls = lex_source(texts[paths[pi]])
        var texts_of = List[String]()
        var imp = List[Bool]()
        var live = List[Bool]()
        for i in range(len(ls)):
            texts_of.append(ls[i].text.copy())
            imp.append(ls[i].is_import)
            live.append(ls[i].code and not ls[i].in_string)
        var al = _aliases(texts_of, imp)
        for e in al.items():
            if e.value in track:
                alias_of[e.key] = e.value
        lexed[paths[pi]] = live^
    for pi in range(len(paths)):
        var path = paths[pi]
        var text = texts[path]
        var ls = lex_source(text)
        var fns = declared_functions(text)
        var fi = _File()
        for k in range(len(fns)):
            var has = False
            for a in range(len(fns[k].lines)):
                if path in recorded and fns[k].lines[a] in recorded[path]:
                    has = True
            fi.compiled.append(has)
        for ln in range(1, len(ls) + 1):
            if not lexed[path][ln - 1] or ls[ln - 1].is_import:
                continue
            var toks = _tokens(ls[ln - 1].text)
            if len(toks) == 0:
                continue
            # The name a declaration gives is no use: `def name(` / `fn name(`.
            var skip = -1
            if len(toks) >= 2 and (toks[0] == String("def") or toks[0] == String("fn")):
                skip = 1
            # The innermost function whose range holds the line.
            var inner = -1
            for k in range(len(fns)):
                if ln > fns[k].line and ln <= fns[k].end:
                    if inner < 0 or fns[k].line > fns[inner].line:
                        inner = k
            for q in range(len(toks)):
                if q == skip:
                    continue
                var key = toks[q].copy()
                if key in alias_of:
                    key = alias_of[key]
                if key not in track:
                    continue
                if key not in sites:
                    sites[key] = List[_Site]()
                sites[key].append(_Site(path, ln, inner))
        fi.fns = fns^
        files[path] = fi^
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
            if cands[c].path not in files:
                continue
            var key = cands[c].name
            if key not in sites:
                continue
            var n_sites = 0
            var all_dropped = True
            for s in range(len(sites[key])):
                ref st = sites[key][s]
                # A use inside the function itself (recursion) says nothing about its callers.
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
                    elif files[st.path].compiled[st.owner]:
                        # Dropped when an arm around the line has no record on any of its lines.
                        for b in range(len(g.arm_blocks)):
                            var holds = False
                            var recorded_any = False
                            for q in range(len(g.arm_blocks[b])):
                                if g.arm_blocks[b][q] == st.line:
                                    holds = True
                                if st.path in recorded and g.arm_blocks[b][q] in recorded[st.path]:
                                    recorded_any = True
                            if holds and not recorded_any:
                                dropped = True
                if not dropped:
                    all_dropped = False
                    break
            if n_sites > 0 and all_dropped:
                out[c] = True
                gated[cands[c].path + String(":") + String(cands[c].line)] = True
                changed = True
    return out^
