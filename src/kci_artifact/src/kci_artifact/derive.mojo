# =============================================================================
# kci_artifact/derive.mojo -- the per-change check's DERIVED checks: a build
#   system's `derive_checks` command reads the build graph at run time and
#   answers the checks that cover what no declared unit names.
# =============================================================================
#
# The protocol (the .proto's header, in full):
#
#   kci writes  {units_file}  `<unit>\t<target>\n` for every target of every
#                             DECLARED unit (artifacts, then checks, of every
#                             build system), in unit order
#                             (`declared_units_file_text`);
#   kci runs    <derive_checks.executable> <derive_checks.args...>, the
#               affected command's placeholders substituted
#               (`render_derive_argv`);
#   it prints   on stdout, in any order:
#                 `CHECK <name> <target>`  a target of the derived check
#                                          `<name>` (one line per target;
#                                          the checks keep the order of their
#                                          first line);
#                 `UNMATCHED <unit> <target>`  a declared unit's target that
#                                          matches nothing in the graph;
#               then exactly one verdict line, LAST: `DERIVED <n>`, n the
#               number of distinct check names (0 is allowed); or, alone,
#               `BROKEN <reason>`: the tool could not query its build graph
#               (its query failed, buck2's error in the reason), and
#               kci_build FAILS the check. One trailing newline is allowed.
#
# `parse_derive_answer` refuses anything else: an unknown or empty line, a
# CHECK with no target or a target holding a space, an UNMATCHED naming a
# unit or a target that is not declared, a line repeated, a missing,
# repeated or misplaced verdict, an n that is not the count, a BROKEN with
# no reason or after another line. A refusal is "cannot tell" for the caller
# (kci_build), never an empty answer.
#
# `add_derived_checks` appends the derived checks to the file's value, owned
# by the build system that derived them, and validates the result with the
# file's own rules (`validate_artifacts`): a derived name that is a declared
# unit's, or a target given twice in one check, is refused like a declared
# one.
#
# What an UNMATCHED line means is kci's to say, by the unit's kind: an
# ARTIFACT's target that matches nothing is refused (a release would build
# nothing there), a CHECK's is a notice (a package was deleted; the check
# reaches the rest of what it names). kci_build reads `unmatched_artifacts`.
#
# Pure functions over owned values; no pointer, no process, no file.
# =============================================================================

from kci_artifact_proto.artifact import Artifacts, Check

from .affected import Unit, units_of
from .placeholders import AffectedValues, substitute_affected
from .validate import find_artifact, find_build_system, validate_artifacts

comptime DERIVE_CHECK: String = "CHECK"
comptime DERIVE_UNMATCHED: String = "UNMATCHED"
comptime DERIVE_VERDICT: String = "DERIVED"
comptime DERIVE_BROKEN: String = "BROKEN"


struct DeriveAnswer(Copyable, Movable):
    """One build system's parsed answer: the derived checks (names, and the
    targets of each, in parallel lists) and the declared targets that match
    nothing (units and targets, in parallel lists); or `broken`, with the
    tool's `reason`, when it could not query its graph (no check, no line).

    Layout: owned values only. No pointer field."""

    var names: List[String]
    var targets: List[List[String]]
    var unmatched_units: List[String]
    var unmatched_targets: List[String]
    var broken: Bool
    var reason: String

    def __init__(out self):
        self.names = List[String]()
        self.targets = List[List[String]]()
        self.unmatched_units = List[String]()
        self.unmatched_targets = List[String]()
        self.broken = False
        self.reason = String("")


def declared_units_file_text(arts: Artifacts) -> String:
    """`{units_file}`'s content for a `derive_checks` command (file header):
    every declared unit of every build system."""
    var units = units_of(arts)
    var s = String("")
    for i in range(len(units)):
        ref u = units[i]
        for k in range(len(u.targets)):
            s += u.name + String("\t") + u.targets[k] + String("\n")
    return s^


def render_derive_argv(arts: Artifacts, build_system: String, values: AffectedValues) raises -> List[String]:
    """`[executable] + args` of `build_system`'s derive_checks command, every
    placeholder substituted. Raises when the build system is not declared or
    declares no derive_checks command."""
    var j = find_build_system(arts, build_system)
    if j < 0:
        raise Error(String("no build system '") + build_system + String("' is declared"))
    if not arts.build_systems[j].derive_checks:
        raise Error(String("build system '") + build_system + String("' declares no derive_checks command"))
    ref c = arts.build_systems[j].derive_checks.value()
    var argv = List[String]()
    argv.append(c.executable.copy())
    for k in range(len(c.args)):
        argv.append(substitute_affected(c.args[k], values))
    return argv^


def _decimal(s: String) -> Int:
    """`s` as a decimal of at most 9 digits with no leading zero (but "0"),
    or -1."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 9 or (len(b) > 1 and Int(b[0]) == 48):
        return -1
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        n = n * 10 + (c - 48)
    return n


def _index(xs: List[String], x: String) -> Int:
    for i in range(len(xs)):
        if xs[i] == x:
            return i
    return -1


def _pair(rest: String, where: String, what: String) raises -> Tuple[String, String]:
    """`<a> <b>`: two words, one space between them, no other space."""
    var sp = rest.find(String(" "))
    if sp <= 0 or sp == rest.byte_length() - 1:
        raise Error(where + String(": expected ") + what)
    var a = String(rest[byte=0:sp])
    var b = String(rest[byte = sp + 1 :])
    if b.find(String(" ")) >= 0 or b.find(String("\t")) >= 0 or a.find(String("\t")) >= 0:
        raise Error(where + String(": expected ") + what + String(" (a target holds no whitespace)"))
    return (a^, b^)


def _declares(units: List[Unit], unit: String, target: String) -> Int:
    """1 when `unit` is declared with `target`, 0 when declared without it,
    -1 when not declared."""
    for i in range(len(units)):
        if units[i].name != unit:
            continue
        for k in range(len(units[i].targets)):
            if units[i].targets[k] == target:
                return 1
        return 0
    return -1


def parse_derive_answer(text: String, declared: List[Unit]) raises -> DeriveAnswer:
    """The answer printed by a derive_checks command, the declared units
    being `declared` (file header). Raises on anything outside the grammar,
    naming the line."""
    var body = text.copy()
    if body.endswith(String("\n")):
        var trimmed = String(body[byte = : body.byte_length() - 1])
        body = trimmed^
    if body.byte_length() == 0:
        raise Error(String("printed nothing (expected CHECK lines and one verdict line)"))
    var lines = body.split(String("\n"))
    var out = DeriveAnswer()
    var n = len(lines)
    for i in range(n):
        var line = String(lines[i])
        var where = String("line ") + String(i + 1) + String(" '") + line + String("'")
        var sp = line.find(String(" "))
        var word = line.copy() if sp < 0 else String(line[byte = 0:sp])
        var rest = String("") if sp < 0 else String(line[byte = sp + 1 :])
        if word == DERIVE_CHECK or word == DERIVE_UNMATCHED:
            if i == n - 1:
                raise Error(where + String(": the last line must be the verdict (DERIVED <n>)"))
        if word == DERIVE_CHECK:
            var p = _pair(rest, where, String("CHECK <name> <target>"))
            var k = _index(out.names, p[0])
            if k < 0:
                out.names.append(p[0].copy())
                out.targets.append(List[String]())
                k = len(out.names) - 1
            if _index(out.targets[k], p[1]) >= 0:
                raise Error(where + String(": check '") + p[0] + String("' names '") + p[1] + String("' twice"))
            out.targets[k].append(p[1].copy())
            continue
        if word == DERIVE_UNMATCHED:
            var p = _pair(rest, where, String("UNMATCHED <unit> <target>"))
            var d = _declares(declared, p[0], p[1])
            if d < 0:
                raise Error(where + String(": '") + p[0] + String("' is not a declared unit"))
            if d == 0:
                raise Error(where + String(": unit '") + p[0] + String("' declares no target '") + p[1] + String("'"))
            for j in range(len(out.unmatched_units)):
                if out.unmatched_units[j] == p[0] and out.unmatched_targets[j] == p[1]:
                    raise Error(where + String(": given twice"))
            out.unmatched_units.append(p[0].copy())
            out.unmatched_targets.append(p[1].copy())
            continue
        if word == DERIVE_BROKEN:
            if n != 1:
                raise Error(where + String(": BROKEN fails the check, so it is the only line"))
            if rest.byte_length() == 0:
                raise Error(where + String(": BROKEN needs a reason"))
            out.broken = True
            out.reason = rest^
            return out^
        if word == DERIVE_VERDICT:
            if i != n - 1:
                raise Error(where + String(": the verdict must be the last line, and there is one"))
            var count = _decimal(rest)
            if count < 0:
                raise Error(where + String(": '") + rest + String("' is not a count"))
            if count != len(out.names):
                raise Error(
                    where + String(": says ") + String(count) + String(" check(s) but CHECK lines name ")
                    + String(len(out.names))
                )
            return out^
        raise Error(where + String(": not CHECK <name> <target>, UNMATCHED <unit> <target>, DERIVED <n> or BROKEN <reason>"))
    raise Error(String("no verdict line (DERIVED <n>)"))


def unmatched_artifacts(arts: Artifacts, answer: DeriveAnswer) -> List[String]:
    """`<artifact> <target>` for each UNMATCHED line naming an artifact: a
    refusal (file header). A check's UNMATCHED line is a notice."""
    var out = List[String]()
    for i in range(len(answer.unmatched_units)):
        if find_artifact(arts, answer.unmatched_units[i]) >= 0:
            out.append(answer.unmatched_units[i] + String(" ") + answer.unmatched_targets[i])
    return out^


def add_derived_checks(mut arts: Artifacts, build_system: String, answer: DeriveAnswer, source: String) raises:
    """Append the answer's checks, owned by `build_system`, in answer order,
    and validate the file's value again (file header). Raises on the first
    refusal."""
    for i in range(len(answer.names)):
        arts.checks.append(Check(answer.names[i].copy(), build_system.copy(), answer.targets[i].copy()))
    validate_artifacts(arts, source + String(" with the checks build system '") + build_system + String("' derived"))
