"""The derived checks: the answer of the buck2 build system's `derive_checks`
command (release/artifacts.textproto), run as //tools/build/ci:derive_checks.

kci hands the command a units file (`<unit>\t<target>` per target of every
declared unit) and reads its answer on stdout (the protocol is
src/kci_artifact_proto/artifact.proto's header):

  CHECK <name> <pattern>     a target pattern of the derived check <name>
  UNMATCHED <unit> <target>  a declared target that matches nothing in the
                             graph (kci refuses it for an artifact and reports
                             it as a notice for a check)
  DERIVED <n>                last: the number of derived checks
  BROKEN <reason>            alone, instead of the above: the universe query
                             failed, for any reason (an unknown or invisible
                             dependency, a transport error, a buck2 that does
                             not start); the reason is one line holding
                             buck2's error as `kept_stderr` keeps it. kci
                             FAILS the check (KCI-E-BUILD-FAILED): a graph the
                             tool cannot query is never a widening. The target
                             buck2 names, when it names one, leads the reason;
                             it decides nothing.

THE UNIVERSE is `//...` and `tests//functional/...` (what `./buck2 build //...`
and `./buck2 build tests//functional/...` build), configured for the default
target platform, as `buck2 cquery` sees it: a target incompatible with that
platform is not in it. It is read from the graph on every run; no list of it
is kept in the tree.

THE DERIVATION. Every target of the universe that no declared target names
(an exact label) or matches (a pattern `<cell>//<path>/...` or
`<cell>//<path>:`) is put in its path group, and each group with such a
target is a derived check naming the group's pattern: one check per library
package `//src/<p>/...` (named `<p>`) and per test-only package
`//src/tests/<kind>/<p>/...` (named `<p>`: src/tests is not a package but
holds them by kind), `repo_root` (`//:`), `tools_<t>` for each
`//tools/<t>/...`, `<d>` for any other top directory `//<d>/...`, and
`functional_tests` (`tests//functional/...`). A name is one kci accepts,
`[a-z][a-z0-9_]*`, whatever the directory is called: ASCII upper case becomes
lower, any other character (a code point, not a byte) outside `[a-z0-9_]`
becomes `_`, and a name that does not start with a letter gets `pkg_` before
it; groups whose names meet are one check. A name a declared unit holds gets
`_package` (the rest of that artifact's package), again until it is free:
artifacts and checks are one name space. So every target of the universe is
in some unit by construction, a package added to the tree is in a derived
check with no edit anywhere, and a deleted one is simply no longer derived.
A derived name kci would refuse is never answered: `render_answer` raises.

Naming a target that DEPENDS on another is not enough for coverage: buck2
builds only the outputs a dependent consumes, so a library's conda package
does not build the library's own default output, and with it the library's
welded tests. That is why the derivation covers every TARGET, not the roots.

Everything here but `query_universe` is a pure function, so the welded tests
answer the query from tables (tests/test_derive_naming.mojo,
tests/test_derive_answer.mojo).
"""

from buildtools.bytes import byte_at, join, sort_strings, sorted_unique, split_words, substr, suffix

from change_map.graph import buck_failure
from change_map.labels import strip_config
from change_map.plan import named_target
from change_map.process import Captured, lines_of, run_captured
from change_map.units import UnitTargets

comptime UNIVERSE_ROOT: String = "//..."
comptime UNIVERSE_TESTS: String = "tests//functional/..."
comptime ROOT_CELL: String = "komira"


def universe_union() -> String:
    """The universe as one cquery expression."""
    return String(UNIVERSE_ROOT) + String(" + ") + String(UNIVERSE_TESTS)


def query_command() -> String:
    """The buck2 command line (after `buck2 `) that reads the universe."""
    return String("cquery ") + universe_union()


def label_of(configured: String) -> String:
    """`komira//a:b (cfg)` -> `//a:b`; `tests//a:b (cfg)` -> `tests//a:b`."""
    var lab = String(strip_config(configured).strip())
    if lab.startswith(String(ROOT_CELL) + String("//")):
        lab = suffix(lab, String(ROOT_CELL).byte_length())
    return lab^


struct Split(Copyable, Movable):
    """`<cell>//<pkg>:<name>`, each part "" when absent."""

    var cell: String
    var pkg: String
    var name: String

    def __init__(out self, label: String):
        var at = label.find(String("//"))
        var rest = String("")
        if at < 0:
            self.cell = label.copy()
        else:
            self.cell = substr(label, 0, at)
            rest = suffix(label, at + 2)
        var colon = rest.find(String(":"))
        if colon < 0:
            self.pkg = rest^
            self.name = String("")
        else:
            self.pkg = substr(rest, 0, colon)
            self.name = suffix(rest, colon + 1)


def _parts(pkg: String) -> List[String]:
    """`pkg` split on `/` (`""` is one empty part)."""
    var out = List[String]()
    var pieces = pkg.split(String("/"))
    for i in range(len(pieces)):
        out.append(String(pieces[i]))
    return out^


def is_pattern(t: String) -> Bool:
    """`<cell>//<path>/...` (a package and every package below it) or
    `<cell>//<path>:` (the targets of one package; `//:` is the root's).
    `<cell>//...` is not one: it is matched as an exact label."""
    var at = t.find(String("//"))
    if at < 0:
        return False
    if t.endswith(String("/...")):
        return t.byte_length() - (at + 2) > 4
    if not t.endswith(String(":")):
        return False
    return substr(t, 0, t.byte_length() - 1).find(String(":")) < 0


def matches(t: String, label: String) -> Bool:
    """A unit's target `t` (a pattern or an exact label) names `label`."""
    if not is_pattern(t):
        return t == label
    var s = Split(label)
    if t.endswith(String("/...")):
        var p = Split(substr(t, 0, t.byte_length() - 4))
        return s.cell == p.cell and (s.pkg == p.pkg or s.pkg.startswith(p.pkg + String("/")))
    var p = Split(substr(t, 0, t.byte_length() - 1))
    return s.cell == p.cell and s.pkg == p.pkg


def unit_name(raw: String) -> String:
    """A directory name as a name kci accepts: ASCII upper case lowered,
    every other code point outside `[a-z0-9_]` one `_`, and `pkg_` before a
    name that does not start with a letter."""
    var out = String("")
    for i in range(raw.byte_length()):
        var c = byte_at(raw, i)
        if c >= 0x80 and c < 0xC0:
            continue  # a UTF-8 continuation byte: its code point is already one `_`
        if c >= 65 and c <= 90:
            out += chr(c + 32)
        elif (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95:
            out += chr(c)
        else:
            out += String("_")
    if out.byte_length() == 0 or byte_at(out, 0) < 97 or byte_at(out, 0) > 122:
        out = String("pkg_") + out
    return out^


def check_name(label: String, taken: Dict[String, Bool]) -> String:
    """The derived check a target maps to (the grouping by path); a name in
    `taken` gets `_package` until it is free."""
    var s = Split(label)
    if s.cell == String("tests"):
        return String("functional_tests")
    if s.pkg.byte_length() == 0:
        return String("repo_root")
    var parts = _parts(s.pkg)
    var raw: String
    if len(parts) > 3 and parts[0] == String("src") and parts[1] == String("tests"):
        raw = parts[3]
    elif parts[0] == String("src") and len(parts) > 1:
        raw = parts[1]
    elif parts[0] == String("tools") and len(parts) > 1:
        raw = String("tools_") + parts[1]
    else:
        raw = parts[0]
    var name = unit_name(raw)
    while name in taken:
        name += String("_package")
    return name^


def group_pattern(label: String) -> String:
    """The pattern of `label`'s path group (check_name's grouping)."""
    var s = Split(label)
    if s.cell == String("tests"):
        return String(UNIVERSE_TESTS)
    if s.pkg.byte_length() == 0:
        return String("//:")
    var parts = _parts(s.pkg)
    if len(parts) >= 2 and parts[0] == String("src") and parts[1] == String("tests"):
        # src/tests holds the test-only packages by kind: one group each.
        if len(parts) > 3:
            return String("//src/tests/") + parts[2] + String("/") + parts[3] + String("/...")
        return String("//") + s.pkg + String(":")
    if parts[0] == String("src") or parts[0] == String("tools"):
        if len(parts) == 1:
            return String("//") + parts[0] + String(":")
        return String("//") + parts[0] + String("/") + parts[1] + String("/...")
    return String("//") + parts[0] + String("/...")


def is_valid_name(name: String) -> Bool:
    """A name kci accepts for a unit, `[a-z][a-z0-9_]*`
    (src/kci_artifact/validate.mojo, is_valid_artifact_name)."""
    if name.byte_length() == 0:
        return False
    for i in range(name.byte_length()):
        var c = byte_at(name, i)
        var lower = c >= 97 and c <= 122
        if i == 0 and not lower:
            return False
        if not (lower or (c >= 48 and c <= 57) or c == 95):
            return False
    return True


struct Derived(Movable):
    """The derivation: the checks in output order (`names[i]` with its sorted
    `patterns[i]`), and the declared (unit, target) pairs matching no label,
    in units-file order."""

    var names: List[String]
    var patterns: List[List[String]]
    var unmatched_units: List[String]
    var unmatched_targets: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.patterns = List[List[String]]()
        self.unmatched_units = List[String]()
        self.unmatched_targets = List[String]()


def _matched_by_any(targets: List[String], label: String) -> Bool:
    for i in range(len(targets)):
        if matches(targets[i], label):
            return True
    return False


def derive(declared: UnitTargets, labels: List[String]) raises -> Derived:
    """The checks deriving every label of `labels` no declared target names,
    and the declared targets that match no label. Raises when a label's group
    pattern does not match the label (the grouping is wrong)."""
    var out = Derived()
    for i in range(len(declared.targets)):
        var hit = False
        for k in range(len(labels)):
            if matches(declared.targets[i], labels[k]):
                hit = True
                break
        if not hit:
            out.unmatched_units.append(declared.names[i])
            out.unmatched_targets.append(declared.targets[i])
    var taken = Dict[String, Bool]()
    for i in range(len(declared.names)):
        taken[declared.names[i]] = True
    var index = Dict[String, Int]()
    var names = List[String]()
    var groups = List[List[String]]()
    for k in range(len(labels)):
        ref lab = labels[k]
        if _matched_by_any(declared.targets, lab):
            continue
        var pattern = group_pattern(lab)
        if not matches(pattern, lab):
            raise Error(String("the group pattern ") + pattern + String(" does not match ") + lab)
        var name = check_name(lab, taken)
        if name not in index:
            index[name] = len(names)
            names.append(name)
            groups.append(List[String]())
        var g = index[name]
        var seen = False
        for j in range(len(groups[g])):
            if groups[g][j] == pattern:
                seen = True
                break
        if not seen:
            groups[g].append(pattern)
    # Output order: the root cell's groups before the tests cell's, then by
    # each group's least pattern (distinct groups never share a pattern).
    var keys = List[String]()
    for g in range(len(names)):
        sort_strings(groups[g])
        var least = groups[g][0]
        var flag = String("1") if least.startswith(String("tests//")) else String("0")
        keys.append(flag + least + String("\n") + names[g])
    sort_strings(keys)
    for i in range(len(keys)):
        var nl = keys[i].find(String("\n"))
        var name = suffix(keys[i], nl + 1)
        out.patterns.append(groups[index[name]].copy())
        out.names.append(name^)
    return out^


def render_answer(declared: UnitTargets, labels: List[String]) raises -> String:
    """The answer for a universe that configured: UNMATCHED lines, CHECK
    lines, then `DERIVED <n>`. Raises on a derived name kci would refuse."""
    var d = derive(declared, labels)
    for i in range(len(d.names)):
        if not is_valid_name(d.names[i]):
            raise Error(String("the derived check name '") + d.names[i] + String("' is not [a-z][a-z0-9_]*"))
    var out = String("")
    for i in range(len(d.unmatched_units)):
        out += String("UNMATCHED ") + d.unmatched_units[i] + String(" ") + d.unmatched_targets[i] + String("\n")
    for i in range(len(d.names)):
        for k in range(len(d.patterns[i])):
            out += String("CHECK ") + d.names[i] + String(" ") + d.patterns[i][k] + String("\n")
    out += String("DERIVED ") + String(len(d.names)) + String("\n")
    return out^


def broken_line(error: String) -> String:
    """The answer when the universe query failed: one `BROKEN` line, its
    whitespace runs one space."""
    var reason = String("the universe query failed")
    var named = named_target(error)
    if named.byte_length() > 0:
        reason += String(", naming ") + named
    reason += String(": ") + error
    return String("BROKEN ") + join(split_words(reason), String(" ")) + String("\n")


def universe_labels(cquery_stdout: String) raises -> List[String]:
    """Every target of the universe, from cquery's output, sorted and
    unique. Raises on an empty universe: it cannot be."""
    var labels = List[String]()
    var lines = lines_of(cquery_stdout)
    for i in range(len(lines)):
        if String(lines[i].strip()).byte_length() > 0:
            labels.append(label_of(lines[i]))
    if len(labels) == 0:
        raise Error(String("the universe is empty; it cannot be"))
    return sorted_unique(labels)


def answer_query(declared: UnitTargets, query: Captured) raises -> String:
    """The whole answer for the universe query's result: BROKEN when it
    failed, whatever buck2 printed; else `render_answer` of its targets."""
    if not query.ok():
        return broken_line(buck_failure(query_command(), Int(query.exit_code), query.stderr))
    return render_answer(declared, universe_labels(query.stdout))


def query_universe(buck2: String) raises -> Captured:
    """Run `<buck2> cquery //... + tests//functional/...` (the one process)."""
    var args = List[String]()
    args.append(String("cquery"))
    args.append(universe_union())
    return run_captured(buck2, args)


def read_artifacts_text(text: String) -> UnitTargets:
    """The (unit, target) pairs of a textproto artifacts file's artifacts and
    checks, read loosely (for a reader; kci hands the tool its units file):
    a block opens on a line `artifacts {` or `checks {` and closes on a line
    starting `}`; its first `name: "..."` names it, and each
    `targets: "..."` is one of its targets."""
    var out = UnitTargets()
    var in_unit = False
    var unit = String("")
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        var trimmed_right = String(line.rstrip())
        if trimmed_right == String("artifacts {") or trimmed_right == String("checks {"):
            in_unit = True
            unit = String("")
            continue
        if line.startswith(String("}")):
            in_unit = False
            continue
        if not in_unit:
            continue
        var s = String(line.strip())
        if unit.byte_length() == 0 and _quoted_field(s, String("name")).byte_length() > 0:
            unit = _quoted_field(s, String("name"))
        var t = _quoted_field(s, String("targets"))
        if t.byte_length() > 0:
            out.names.append(unit)
            out.targets.append(t^)
    return out^


def _quoted_field(s: String, key: String) -> String:
    """The value of `s` when it is exactly `<key>: "<value>"` with no `"` in
    the value, else ""."""
    var head = key + String(": \"")
    if not s.startswith(head) or not s.endswith(String("\"")) or s.byte_length() <= head.byte_length() + 1:
        return String("")
    var v = substr(s, head.byte_length(), s.byte_length() - 1)
    if v.find(String("\"")) >= 0:
        return String("")
    return v^
