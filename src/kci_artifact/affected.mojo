# =============================================================================
# kci_artifact/affected.mojo -- the per-change check's half of the template:
#   the units, the files kci hands a build system's `affected` command, the
#   argvs it runs, and the one grammar of the command's answer.
# =============================================================================
#
# A UNIT is an artifact or a check (one name space); `units_of` lists them
# in the order kci builds them: artifacts in file order, then checks in file
# order. The protocol (the .proto's header, in full):
#
#   kci writes  {units_file}     `<unit>\t<target>\n` for every target of
#                                every unit the build system owns, in unit
#                                order (`units_file_text`);
#               {changed_files}  the paths of the change, NUL-terminated, as
#                                `git diff -z --name-only --no-renames`
#                                printed them (kci_build writes it);
#   kci runs    <affected.executable> <affected.args...>, placeholders
#               substituted (`render_affected_argv`);
#   it prints   on stdout, `UNIT <name>` per affected unit, then exactly one
#               verdict line, LAST: `AFFECTED <n>`, n the number of UNIT
#               lines (0 allowed), or `WIDENED <reason>` with no UNIT line
#               (the change reaches every declared unit), or `BROKEN
#               <reason>` with no UNIT line (the tool's query of its build
#               graph failed, for any reason, such as a target with an
#               unknown or invisible dependency; kci_build FAILS the check). One
#               trailing newline is allowed.
#
# And to build the units it decided:
#
#   kci runs    <build_targets.executable> <build_targets.args...> then
#               targets, no placeholder. One unit alone gets its own targets
#               (`render_targets_argv`). Units whose build_targets commands
#               are element-wise identical (the executable and every arg) form
#               one GROUP (`batch_groups`: groups in the order their first
#               unit comes, unit order inside each), and a group of two or
#               more runs once over the union of its units' targets, in unit
#               order, exact repeats dropped (`render_batch_argv`). So a
#               build_targets command must be correct on the union of several
#               units' targets: it builds and tests them together.
#
# `parse_affected_answer` refuses anything else: an unknown line, an empty
# line, a UNIT the build system does not own or names twice, a missing,
# repeated or misplaced verdict, an n that is not the count, a WIDENED or
# BROKEN with no reason or with UNIT lines. A refusal is "cannot tell" for
# the caller (kci_build), never a widening and never an empty answer.
#
# Pure functions over owned values; no pointer, no process, no file.
# =============================================================================

from kci_artifact_proto.artifact import Artifacts

from kci_api import AFFECTED_VERDICT_AFFECTED, AFFECTED_VERDICT_WIDENED

from .placeholders import AffectedValues, substitute_affected
from .validate import find_build_system

comptime ANSWER_UNIT: String = "UNIT"
comptime VERDICT_AFFECTED: String = AFFECTED_VERDICT_AFFECTED
comptime VERDICT_WIDENED: String = AFFECTED_VERDICT_WIDENED
comptime VERDICT_BROKEN: String = "BROKEN"
"""Not a verdict a result records: the check is FAILED on it."""


struct Unit(Copyable, Movable):
    """One unit of the per-change check: an artifact or a check.

    Layout: owned values only. No pointer field."""

    var name: String
    var build_system: String
    var targets: List[String]
    var is_check: Bool

    def __init__(out self, var name: String, var build_system: String, var targets: List[String], is_check: Bool):
        self.name = name^
        self.build_system = build_system^
        self.targets = targets^
        self.is_check = is_check


def units_of(arts: Artifacts) -> List[Unit]:
    """Every unit, artifacts first, each list in file order."""
    var out = List[Unit]()
    for i in range(len(arts.artifacts)):
        ref a = arts.artifacts[i]
        out.append(Unit(a.name.copy(), a.build_system.copy(), a.targets.copy(), False))
    for i in range(len(arts.checks)):
        ref c = arts.checks[i]
        out.append(Unit(c.name.copy(), c.build_system.copy(), c.targets.copy(), True))
    return out^


def unit_names_of(arts: Artifacts, build_system: String) -> List[String]:
    """The names of the units `build_system` owns, in unit order."""
    var units = units_of(arts)
    var out = List[String]()
    for i in range(len(units)):
        if units[i].build_system == build_system:
            out.append(units[i].name.copy())
    return out^


def units_file_text(arts: Artifacts, build_system: String) -> String:
    """`{units_file}`'s content for `build_system` (file header)."""
    var units = units_of(arts)
    var s = String("")
    for i in range(len(units)):
        ref u = units[i]
        if u.build_system != build_system:
            continue
        for k in range(len(u.targets)):
            s += u.name + String("\t") + u.targets[k] + String("\n")
    return s^


def render_affected_argv(arts: Artifacts, build_system: String, values: AffectedValues) raises -> List[String]:
    """`[executable] + args` of `build_system`'s affected command, every
    placeholder substituted. Raises when the build system is not declared or
    declares no affected command."""
    var j = find_build_system(arts, build_system)
    if j < 0:
        raise Error(String("no build system '") + build_system + String("' is declared"))
    if not arts.build_systems[j].affected:
        raise Error(String("build system '") + build_system + String("' declares no affected command"))
    ref c = arts.build_systems[j].affected.value()
    var argv = List[String]()
    argv.append(c.executable.copy())
    for k in range(len(c.args)):
        argv.append(substitute_affected(c.args[k], values))
    return argv^


struct _UnitCommand(Copyable, Movable):
    """One unit's build_targets command (`[executable] + args`) and its
    targets.

    Layout: owned values only. No pointer field."""

    var command: List[String]
    var targets: List[String]

    def __init__(out self, var command: List[String], var targets: List[String]):
        self.command = command^
        self.targets = targets^


def _unit_command(arts: Artifacts, units: List[Unit], unit: String) raises -> _UnitCommand:
    """The build_targets command and the targets of the unit named `unit`
    (`units` is `units_of(arts)`). Raises on an unknown unit, a unit with no
    targets, or a build system with no build_targets command."""
    for i in range(len(units)):
        ref u = units[i]
        if u.name != unit:
            continue
        if len(u.targets) == 0:
            raise Error(String("unit '") + unit + String("' has no targets"))
        var j = find_build_system(arts, u.build_system)
        if j < 0:
            raise Error(String("unit '") + unit + String("': build_system '") + u.build_system + String("' is not declared"))
        if not arts.build_systems[j].build_targets:
            raise Error(
                String("unit '") + unit + String("': build_system '") + u.build_system
                + String("' declares no build_targets command")
            )
        ref c = arts.build_systems[j].build_targets.value()
        var command = List[String]()
        command.append(c.executable.copy())
        for k in range(len(c.args)):
            command.append(c.args[k].copy())
        return _UnitCommand(command^, u.targets.copy())
    raise Error(String("no unit '") + unit + String("' is declared"))


def _same(a: List[String], b: List[String]) -> Bool:
    """Element-wise equal."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _joined(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        if i > 0:
            s += String(" ")
        s += xs[i]
    return s^


def render_targets_argv(arts: Artifacts, unit: String) raises -> List[String]:
    """`[executable] + build_targets.args + targets` of the unit named
    `unit`. Raises on an unknown unit, a unit with no targets, or a build
    system with no build_targets command."""
    var c = _unit_command(arts, units_of(arts), unit)
    var argv = c.command.copy()
    for k in range(len(c.targets)):
        argv.append(c.targets[k].copy())
    return argv^


def batch_groups(arts: Artifacts, units: List[String]) raises -> List[List[String]]:
    """`units` split into groups whose build_targets commands are
    element-wise identical (file header): groups in the order of their
    first unit, `units`' order inside each. Raises as `render_targets_argv`
    does for any unit."""
    var all = units_of(arts)
    var commands = List[List[String]]()
    var groups = List[List[String]]()
    for i in range(len(units)):
        var c = _unit_command(arts, all, units[i])
        var at = -1
        for g in range(len(commands)):
            if _same(commands[g], c.command):
                at = g
                break
        if at < 0:
            commands.append(c.command.copy())
            groups.append(List[String]())
            at = len(groups) - 1
        groups[at].append(units[i].copy())
    return groups^


def render_batch_argv(arts: Artifacts, units: List[String]) raises -> List[String]:
    """The shared build_targets command of `units`, then every unit's
    targets in `units`' order with exact repeats dropped (file header).
    Raises on an empty list, an unknown unit, a unit with no targets, or
    units whose commands differ."""
    if len(units) == 0:
        raise Error(String("a batch needs at least one unit"))
    var all = units_of(arts)
    var first = _unit_command(arts, all, units[0])
    var argv = first.command.copy()
    var seen = List[String]()
    for i in range(len(units)):
        var c = _unit_command(arts, all, units[i])
        if not _same(c.command, first.command):
            raise Error(
                String("unit '") + units[i] + String("' builds with `") + _joined(c.command) + String("` and unit '")
                + units[0] + String("' with `") + _joined(first.command)
                + String("`: one batch runs one build_targets command")
            )
        for k in range(len(c.targets)):
            if not _contains(seen, c.targets[k]):
                seen.append(c.targets[k].copy())
                argv.append(c.targets[k].copy())
    return argv^


struct AffectedAnswer(Copyable, Movable):
    """One build system's parsed answer: WIDENED or BROKEN with its reason,
    or the affected units (possibly none).

    Layout: owned values only. No pointer field."""

    var widened: Bool
    var broken: Bool
    var reason: String
    var units: List[String]

    def __init__(out self):
        self.widened = False
        self.broken = False
        self.reason = String("")
        self.units = List[String]()


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


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def parse_affected_answer(text: String, owned: List[String]) raises -> AffectedAnswer:
    """The answer printed by an affected command whose build system owns the
    units `owned` (file header). Raises on anything outside the grammar,
    naming the line."""
    var body = text.copy()
    if body.endswith(String("\n")):
        var trimmed = String(body[byte = : body.byte_length() - 1])
        body = trimmed^
    if body.byte_length() == 0:
        raise Error(String("printed nothing (expected UNIT lines and one verdict line)"))
    var lines = body.split(String("\n"))
    var out = AffectedAnswer()
    var n = len(lines)
    for i in range(n):
        var line = String(lines[i])
        var where = String("line ") + String(i + 1) + String(" '") + line + String("'")
        var sp = line.find(String(" "))
        var word = line.copy() if sp < 0 else String(line[byte = 0:sp])
        var rest = String("") if sp < 0 else String(line[byte = sp + 1 :])
        if word == ANSWER_UNIT:
            if i == n - 1:
                raise Error(where + String(": the last line must be the verdict (AFFECTED <n>, WIDENED <reason> or BROKEN <reason>)"))
            if not _contains(owned, rest):
                raise Error(where + String(": '") + rest + String("' is not a unit this build system owns"))
            if _contains(out.units, rest):
                raise Error(where + String(": unit '") + rest + String("' is named twice"))
            out.units.append(rest^)
            continue
        if word == VERDICT_AFFECTED or word == VERDICT_WIDENED or word == VERDICT_BROKEN:
            if i != n - 1:
                raise Error(where + String(": the verdict must be the last line, and there is one"))
            if word == VERDICT_AFFECTED:
                var count = _decimal(rest)
                if count < 0:
                    raise Error(where + String(": '") + rest + String("' is not a count"))
                if count != len(out.units):
                    raise Error(
                        where + String(": says ") + String(count) + String(" unit(s) but ")
                        + String(len(out.units)) + String(" UNIT line(s) came before it")
                    )
                return out^
            if rest.byte_length() == 0:
                raise Error(where + String(": ") + word + String(" needs a reason"))
            if word == VERDICT_BROKEN:
                if len(out.units) > 0:
                    raise Error(where + String(": BROKEN fails the check, so it comes with no UNIT line"))
                out.broken = True
                out.reason = rest^
                return out^
            if len(out.units) > 0:
                raise Error(where + String(": WIDENED reaches every unit, so it comes with no UNIT line"))
            out.widened = True
            out.reason = rest^
            return out^
        raise Error(where + String(": not UNIT <name>, AFFECTED <n>, WIDENED <reason> or BROKEN <reason>"))
    raise Error(String("no verdict line (AFFECTED <n>, WIDENED <reason> or BROKEN <reason>)"))
