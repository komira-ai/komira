# =============================================================================
# kci_cell/cell.mojo -- a `cell` entry of a cells file, and its lookups.
# =============================================================================
#
# A cell is one closed world: one cloud, one place, owned by one machine.
#
#   name             the cell id, in the step-name grammar (kci_api's
#                    `is_step_name`), unique in the file. It is the cell of
#                    every ownership stamp written into the cell.
#   cloud            a cloud id word (e.g. "gcp"). Whether this kci was built
#                    with that cloud is checked when a step runs, not here.
#   settings         keys and values, each key at most once, in file order.
#                    kci does not interpret them: the cloud adapter reports
#                    an unknown or missing key.
#   bootstrap_level  the level the operator wrote after running bootstrap;
#                    only `BOOTSTRAP_LEVEL_V1` is accepted.
#
# Plain value types (Strings in Lists); no pointer field.
# =============================================================================

comptime BOOTSTRAP_LEVEL_V1: Int = 1
"""The only `bootstrap_level` a cells file may state today."""


@fieldwise_init
struct CellSetting(Copyable, Movable):
    """One `setting { key: ... value: ... }` of a cell.

    Layout: owned Strings. No pointer field."""

    var key: String
    var value: String


struct Cell(Copyable, Movable):
    """One cell of a cells file. See the module header.

    Layout: owned Strings, a List of settings and Ints. No pointer field."""

    var name: String
    var cloud: String
    var settings: List[CellSetting]
    var bootstrap_level: Int
    var line: Int  # the line of the cell's `{` in the cells file (0 when built in code)

    def __init__(
        out self,
        var name: String,
        var cloud: String,
        var settings: List[CellSetting],
        bootstrap_level: Int,
        line: Int = 0,
    ):
        self.name = name^
        self.cloud = cloud^
        self.settings = settings^
        self.bootstrap_level = bootstrap_level
        self.line = line

    def has_setting(self, key: String) -> Bool:
        """True when the cell declares a setting `key`."""
        for i in range(len(self.settings)):
            if self.settings[i].key == key:
                return True
        return False

    def setting(self, key: String) raises -> String:
        """The value of setting `key`. Raises when the cell declares none: a
        missing setting is never defaulted."""
        for i in range(len(self.settings)):
            if self.settings[i].key == key:
                return self.settings[i].value.copy()
        raise Error(
            String("cell '") + self.name + String("' declares no setting '") + key + String("'")
        )


def cell_names(cells: List[Cell]) -> List[String]:
    """Every declared cell's name, in file order."""
    var out = List[String]()
    for i in range(len(cells)):
        out.append(cells[i].name.copy())
    return out^


def find_cell(cells: List[Cell], name: String) raises -> Cell:
    """The cell named `name`. Raises on an unknown name, naming the declared
    ones; an unknown cell never falls back to another one."""
    for i in range(len(cells)):
        if cells[i].name == name:
            return cells[i].copy()
    raise Error(
        String("unknown cell '")
        + name
        + String("' (declared: ")
        + String(", ").join(cell_names(cells))
        + String(")")
    )
