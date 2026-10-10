"""The mapping: the files of a change -> the targets it affects.

A pure function over a `Graph`. The rules, in this order, for each file:

  1. a file matching a `widen` rule widens: the answer is every target;
  2. a file the changed tree no longer has is looked up in the BASE tree: the
     package that held it is a seed, whole (a deleted file is not in the
     changed tree, so no target lists it there);
  3. a `BUCK` file seeds its whole package;
  4. a `.bzl` file seeds every package whose BUCK file loads it (and the
     targets that list it, such as a doc tree): `owner()` alone finds only the
     latter, a fraction of what the macros of a `.bzl` reach;
  5. any other file seeds the targets that list it; a file nothing lists
     widens, unless an `inert` rule names it (it builds nothing).

The answer is the seeds and everything that depends on one of them. It never
under-approximates: anything the mapping cannot do widens, with the reason,
and a change whose files reach no target is VACUOUS, never an empty pass.

One failure is not a widening: a universe holding a target buck2 cannot
configure (an unknown or invisible dependency, such as a visibility a change
narrowed). Every configured query over the universe fails on it, for every
change, so widening would answer every unit on every change and bury the
cause in a reason; dropping it from the universe would pass a change that
broke it. The answer is BROKEN, naming the target and buck2's error, and kci
fails the check. A widened answer would query nothing configured, so
`compute` configures the universe before it widens: a change that plants such
a target under a widen rule (tools/build/**) fails its own check by name,
instead of passing and breaking every change after it.
"""

from buildtools.bytes import dirname, join, sorted_unique

from change_map.graph import Graph, PACKAGE_FOUND, PACKAGE_NONE, PACKAGE_UNKNOWN
from change_map.rules import Rules

comptime KIND_AFFECTED: String = "AFFECTED"
comptime KIND_WIDENED: String = "WIDENED"
comptime KIND_VACUOUS: String = "VACUOUS"
comptime KIND_EMPTY: String = "EMPTY"
comptime KIND_BROKEN: String = "BROKEN"


struct Verdict(Copyable, Movable):
    """The answer. `targets` is sorted and unique; for WIDENED it is every
    target of the universe, for VACUOUS, EMPTY and BROKEN it is empty.
    `reason` says why for WIDENED, VACUOUS and BROKEN. `warnings` are events
    the run saw (a file no target owns, inert or not; a universe query that
    failed before a widening)."""

    var kind: String
    var reason: String
    var targets: List[String]
    var files: Int
    var seeds: Int
    var warnings: List[String]

    def __init__(
        out self,
        var kind: String,
        var reason: String,
        var targets: List[String],
        files: Int,
        seeds: Int,
        var warnings: List[String],
    ):
        self.kind = kind^
        self.reason = reason^
        self.targets = targets^
        self.files = files
        self.seeds = seeds
        self.warnings = warnings^


def _basename(path: String) -> String:
    var d = dirname(path)
    if d.byte_length() == 0:
        return path.copy()
    return String(path[byte = d.byte_length() + 1 :])


def _collect[
    G: Graph
](
    rules: Rules,
    files: List[String],
    mut graph: G,
    mut seeds: List[String],
    mut warnings: List[String],
) raises -> String:
    """Fill `seeds`; return the reason to widen, or "" when every file mapped."""
    var owned_paths = List[String]()
    var may_be_unowned = List[Bool]()
    for i in range(len(files)):
        var f = files[i].copy()
        var rule = rules.widen_reason(f)
        if rule.byte_length() > 0:
            return String("'") + f + String("' matches widen rule ") + rule
        if not graph.file_exists(f):
            var held = graph.package_at_base(f)
            if held.status == PACKAGE_UNKNOWN:
                return String("'") + f + String("' was deleted and no base revision says which package held it")
            if held.status == PACKAGE_NONE:
                if rules.is_inert(f):
                    warnings.append(String("deleted file no package held (inert): ") + f)
                    continue
                return String("'") + f + String("' was deleted and no package held it")
            if not graph.has_package(held.dir):
                return String("the package '") + held.dir + String("' of the deleted '") + f + String("' is gone")
            seeds.append(graph.package_pattern(held.dir))
            continue
        var name = _basename(f)
        if name == String("BUCK"):
            seeds.append(graph.package_pattern(dirname(f)))
            continue
        if f.endswith(String(".bzl")):
            var including = graph.packages_including(f)
            if len(including) == 0:
                return String("the .bzl file '") + f + String("' is loaded by no BUCK file")
            for k in range(len(including)):
                seeds.append(graph.package_pattern(including[k]))
            owned_paths.append(f)
            may_be_unowned.append(True)
            continue
        owned_paths.append(f)
        may_be_unowned.append(False)
    var owners = graph.owners(owned_paths)
    if len(owners) != len(owned_paths):
        return String("the owner query answered ") + String(len(owners)) + String(" of ") + String(len(owned_paths)) + String(" files")
    for i in range(len(owned_paths)):
        if len(owners[i]) > 0:
            for k in range(len(owners[i])):
                seeds.append(owners[i][k])
        elif not may_be_unowned[i]:
            if rules.is_inert(owned_paths[i]):
                warnings.append(String("no target owns (inert): ") + owned_paths[i])
            else:
                warnings.append(String("no target owns: ") + owned_paths[i])
                return String("no target owns '") + owned_paths[i] + String("' and no inert rule names it")
    return String("")


comptime _CONFIGURED_NODE: String = "Error looking up configured node "


def unconfigurable_target(error: String) -> String:
    """The target buck2 named as one it could not configure in a failed
    query's message (the label ends at the space before its configuration,
    or at a line break), or "" when the message names none."""
    var at = error.find(String(_CONFIGURED_NODE))
    if at < 0:
        return String("")
    var start = at + String(_CONFIGURED_NODE).byte_length()
    var b = error.as_bytes()
    var end = start
    while end < len(b) and Int(b[end]) != 32 and Int(b[end]) != 10:
        end += 1
    return String(error[byte=start:end])


def _broken(target: String, error: String, files: Int, var warnings: List[String]) -> Verdict:
    return Verdict(
        String(KIND_BROKEN),
        String("the universe holds a target buck2 cannot configure: ") + target + String(": ") + error,
        List[String](),
        files,
        0,
        warnings^,
    )


def _widened[G: Graph](var reason: String, files: Int, var warnings: List[String], mut graph: G) raises -> Verdict:
    """WIDENED, unless the universe holds a target buck2 cannot configure
    (then BROKEN, naming it). A universe query failing for another reason
    keeps the widening, the failure a warning."""
    try:
        graph.configure_universe()
    except e:
        var broken = unconfigurable_target(String(e))
        if broken.byte_length() > 0:
            return _broken(broken, String(e), files, warnings^)
        warnings.append(String("the universe query failed: ") + String(e))
    var all = sorted_unique(graph.all_targets())
    return Verdict(String(KIND_WIDENED), reason^, all^, files, 0, warnings^)


def compute[G: Graph](rules: Rules, files_in: List[String], mut graph: G) raises -> Verdict:
    """The verdict for a change of `files_in` (repository-relative paths).
    Raises only when even the widened answer cannot be made (the graph
    cannot be listed). A universe holding a target buck2 cannot configure is
    BROKEN, never a widening (the module's header says why)."""
    var files = sorted_unique(files_in)
    var warnings = List[String]()
    if len(files) == 0:
        return Verdict(String(KIND_EMPTY), String(""), List[String](), 0, 0, warnings^)
    var seeds = List[String]()
    var reason = String("")
    try:
        reason = _collect(rules, files, graph, seeds, warnings)
    except e:
        reason = String("a file could not be mapped: ") + String(e)
    if reason.byte_length() > 0:
        return _widened(reason^, len(files), warnings^, graph)
    if len(seeds) == 0:
        var shown = List[String]()
        for i in range(min(len(files), 5)):
            shown.append(files[i])
        var more = String(" ...") if len(files) > 5 else String("")
        return Verdict(
            String(KIND_VACUOUS),
            String("the ") + String(len(files)) + String(" changed file(s) reach no target: ") + join(shown, String(", ")) + more,
            List[String](),
            len(files),
            0,
            warnings^,
        )
    seeds = sorted_unique(seeds)
    var reached = List[String]()
    try:
        reached = graph.rdeps(seeds)
    except e:
        var broken = unconfigurable_target(String(e))
        if broken.byte_length() > 0:
            return _broken(broken, String(e), len(files), warnings^)
        return _widened(String("the reverse-dependency query failed: ") + String(e), len(files), warnings^, graph)
    if len(reached) == 0:
        return _widened(
            String("the reverse-dependency query of ") + String(len(seeds)) + String(" seed(s) answered nothing"),
            len(files),
            warnings^,
            graph,
        )
    return Verdict(String(KIND_AFFECTED), String(""), sorted_unique(reached), len(files), len(seeds), warnings^)


def uncovered(universe: List[String], closure: List[String]) -> List[String]:
    """The targets of `universe` that are not in `closure`, sorted."""
    var held = Dict[String, Bool]()
    for i in range(len(closure)):
        held[closure[i]] = True
    var out = List[String]()
    for i in range(len(universe)):
        if universe[i] not in held:
            out.append(universe[i])
    return sorted_unique(out)
