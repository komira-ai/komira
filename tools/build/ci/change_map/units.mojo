"""The answer in kci's protocol: which of the template's units a change
reaches.

kci writes a units file, one `<unit>\t<target>` line per target of each unit
the build system owns, and the changed paths; the tool answers with one
`UNIT <name>` line per affected unit and a last line, `AFFECTED <n>` or
`WIDENED <reason>`. A unit is affected when any of its targets is.
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


def affected_units(units: UnitTargets, affected: List[String], root_cell: String) -> List[String]:
    """The names of the units with a target in `affected`, in file order."""
    var reached = Dict[String, Bool]()
    for i in range(len(affected)):
        reached[affected[i]] = True
    var out = List[String]()
    var seen = Dict[String, Bool]()
    for i in range(len(units.names)):
        var label = normalize_label(units.targets[i], root_cell)
        if label in reached and units.names[i] not in seen:
            seen[units.names[i]] = True
            out.append(units.names[i])
    return out^
