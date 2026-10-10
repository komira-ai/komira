"""The answer in kci's protocol: which of the template's units a change
reaches.

kci writes a units file, one `<unit>\t<target>` line per target of each unit
the build system owns, and the changed paths; the tool answers with one
`UNIT <name>` line per affected unit and a last line, `AFFECTED <n>`,
`WIDENED <reason>` or `BROKEN <reason>` (a target of the universe cannot be
configured: kci fails the check). A unit is affected when any of its targets
is.
"""

from change_map.labels import normalize_label
from change_map.process import lines_of


struct UnitTargets(Copyable, Movable):
    """The units file, in file order."""

    var names: List[String]
    var targets: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.targets = List[String]()


def parse_units_file(text: String) raises -> UnitTargets:
    var out = UnitTargets()
    var lines = lines_of(text)
    for i in range(len(lines)):
        var parts = lines[i].split(String("\t"))
        if len(parts) != 2 or String(parts[0]).byte_length() == 0 or String(parts[1]).byte_length() == 0:
            raise Error(String("units file line ") + String(i + 1) + String(": expected `<unit>\\t<target>`"))
        out.names.append(String(parts[0]))
        out.targets.append(String(parts[1]))
    if len(out.names) == 0:
        raise Error(String("the units file names no unit"))
    return out^


def _cell_of(label: String) -> String:
    var at = label.find(String("//"))
    if at < 0:
        return String("")
    return String(label[byte=0:at])


def _package_of(label: String) -> String:
    """`cell//pkg/path:name` -> `pkg/path` (a pattern's path for `cell//pkg/path:`)."""
    var at = label.find(String("//"))
    var rest = label.copy() if at < 0 else String(label[byte = at + 2 :])
    var colon = rest.find(String(":"))
    if colon < 0:
        return rest^
    return String(rest[byte=0:colon])


def target_matches(unit_target: String, label: String, root_cell: String) -> Bool:
    """Whether the unit's target (as the units file spells it) names `label`
    (normalized, as the tool prints it). A unit's target is a label, or a
    package pattern: `<cell>//<path>/...` (the package and every package
    below it), `<cell>//<path>:` (that package), `<cell>//...` (the cell).
    The derived checks are patterns, so a label-only match would leave every
    change that reaches only them reaching no unit."""
    var t = normalize_label(unit_target, root_cell)
    if t == label:
        return True
    if _cell_of(t) != _cell_of(label):
        return False
    var path = _package_of(t)
    if t.endswith(String("/...")) or t.endswith(String("//...")):
        var base = String(t[byte = t.find(String("//")) + 2 : t.byte_length() - 3])  # path with its trailing `/`, or ``
        if base.byte_length() == 0:
            return True
        var pkg = _package_of(label)
        return (pkg + String("/")).startswith(base)
    if t.endswith(String(":")):
        return _package_of(label) == path
    return False


def affected_units(units: UnitTargets, affected: List[String], root_cell: String) -> List[String]:
    """The names of the units with a target (a label or a package pattern)
    that names one of `affected`, in file order."""
    var out = List[String]()
    var seen = Dict[String, Bool]()
    var exact = Dict[String, Bool]()
    for i in range(len(affected)):
        exact[affected[i]] = True
    for i in range(len(units.names)):
        if units.names[i] in seen:
            continue
        var hit = normalize_label(units.targets[i], root_cell) in exact
        if not hit:
            for k in range(len(affected)):
                if target_matches(units.targets[i], affected[k], root_cell):
                    hit = True
                    break
        if hit:
            seen[units.names[i]] = True
            out.append(units.names[i])
    return out^
