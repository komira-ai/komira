# =============================================================================
# komira_plan_harness/canon_text.mojo -- the canonical result text, in memory.
# =============================================================================
#
# The file form (one result, UTF-8, LF line ends):
#
#   #! komira-plan-conformance v1
#   #  order: total | keys=<c1>,<c2> | none
#   #  float: ulps=<n> | rel=<x>
#   #  float[<column>]: ulps=<n> | rel=<x>        (zero or more overrides)
#   # <any other comment line, e.g. a derivation>  (expected files only)
#   <name>:<type>[?]<TAB><name>:<type>[?]...      (the schema line)
#   <cell><TAB><cell>...                          (one line per row)
#
# The schema entry is the escaped column name, `:`, the type as
# plan_vocabulary's ArrowType spells it without the `ARROW_TYPE_` prefix, in
# lower case, with the parameters komira_arrow's Field carries (decimal
# precision and scale, timestamp time zone, dictionary index type, union type
# ids) and its one level of children (`list<item:int32?>`), then `?` when
# nullable. Cells are in render.mojo; escapes in escape.mojo; floats in
# float_text.mojo.
#
# The order and float lines are the case's comparison policy. Both are
# always written, and a parsed file must carry both. compare uses the
# EXPECTED side's policy.
#
# NaN. The bits of a NaN a computation produces depend on the machine (x86
# makes 0/0 the negative quiet NaN 0xFFF8..., ARM and numpy the positive
# 0x7FF8...). So an expected file writes bare `NaN`, which matches ANY NaN:
# that is the oracle's default. `NaN|0x<bits>` opts in to one exact NaN, for
# a case that pins a payload. The actual side always carries its bits; a NaN
# inside a nested value is written bare `NaN` on both sides (render.mojo), so
# a NaN payload is not compared there.
#
# Floats. A top-level float column (and a dictionary of floats) compares by
# bits within its tolerance; the decimal half of a cell is never compared.
# A float inside a nested value is written as its bits alone, `0x<bits>` (or
# `NaN`), and nested values compare as text, so they compare bit-exact with
# no tolerance; a hand file writes such a float as its bits.
#
# Row order, two known limits of the multiset compare (compare.mojo): under
# a tolerance or bare NaN two rows that both match one expected row may pair
# the wrong way in the sorted walk; the rows left unpaired are then matched
# by a search, which is greedy (first fit), not a maximum matching (and is
# skipped without a tolerance or a bare NaN, where the walk is exact). And
# `order: keys=` compares the key projection positionally, so one missing
# row reports a key mismatch at every later row (it does not resynchronise).
# =============================================================================

from .escape import escape_name
from .float_text import FloatTolerance

comptime CANON_MAGIC = "#! komira-plan-conformance v1"

comptime ORDER_TOTAL: Int = 0
comptime ORDER_KEYS: Int = 1
comptime ORDER_NONE: Int = 2


struct CanonPolicy(Copyable, Movable):
    """How a result is compared: row order, and float tolerance (a default
    and per-column overrides). Column names are held escaped."""

    var order: Int
    var keys: List[String]
    var tolerance: FloatTolerance
    var override_names: List[String]
    var override_tolerances: List[FloatTolerance]

    def __init__(out self):
        """`order: total`, `float: ulps=0`."""
        self.order = ORDER_TOTAL
        self.keys = List[String]()
        self.tolerance = FloatTolerance()
        self.override_names = List[String]()
        self.override_tolerances = List[FloatTolerance]()

    @staticmethod
    def total() -> CanonPolicy:
        return CanonPolicy()

    @staticmethod
    def unordered() -> CanonPolicy:
        """`order: none`: the rows compare as a multiset."""
        var p = CanonPolicy()
        p.order = ORDER_NONE
        return p^

    @staticmethod
    def keyed(keys: List[String]) -> CanonPolicy:
        """`order: keys=...`: the key projection is in order; rows that tie
        on it compare as a multiset. `keys` are plain column names."""
        var p = CanonPolicy()
        p.order = ORDER_KEYS
        for k in keys:
            p.keys.append(escape_name(k))
        return p^

    def set_tolerance(mut self, var tolerance: FloatTolerance):
        self.tolerance = tolerance^

    def set_column_tolerance(mut self, column: String, var tolerance: FloatTolerance):
        """Override the tolerance for one float column (a plain name)."""
        var name = escape_name(column)
        for i in range(len(self.override_names)):
            if self.override_names[i] == name:
                self.override_tolerances[i] = tolerance^
                return
        self.override_names.append(name)
        self.override_tolerances.append(tolerance^)

    def tolerance_for(self, escaped_name: String) -> FloatTolerance:
        for i in range(len(self.override_names)):
            if self.override_names[i] == escaped_name:
                return self.override_tolerances[i].copy()
        return self.tolerance.copy()

    def order_text(self) -> String:
        if self.order == ORDER_NONE:
            return String("none")
        if self.order == ORDER_TOTAL:
            return String("total")
        var s = String("keys=")
        for i in range(len(self.keys)):
            if i > 0:
                s += ","
            s += self.keys[i]
        return s

    def write_header[W: Writer](self, mut writer: W):
        writer.write(CANON_MAGIC, "\n")
        writer.write("#  order: ", self.order_text(), "\n")
        writer.write("#  float: ", self.tolerance, "\n")
        for i in range(len(self.override_names)):
            writer.write(
                "#  float[", self.override_names[i], "]: ",
                self.override_tolerances[i], "\n",
            )


struct CanonText(Copyable, Movable, Writable):
    """One result as canonical text: policy, schema and rows of cells.

    `schema[c]` is the full entry (`name:type[?]`), `names[c]` the escaped
    name, `float_widths[c]` 16/32/64 for a float column and 0 otherwise.
    Every float cell is held in canonical form (`FloatCell.canonical`), so two
    float cells with the same bits are the same text.
    """

    var policy: CanonPolicy
    var schema: List[String]
    var names: List[String]
    var float_widths: List[Int]
    var rows: List[List[String]]

    def __init__(out self, var policy: CanonPolicy):
        self.policy = policy^
        self.schema = List[String]()
        self.names = List[String]()
        self.float_widths = List[Int]()
        self.rows = List[List[String]]()

    def num_columns(self) -> Int:
        return len(self.schema)

    def num_rows(self) -> Int:
        return len(self.rows)

    def column_index(self, escaped_name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == escaped_name:
                return i
        return -1

    def row_text(self, r: Int) -> String:
        var s = String()
        for c in range(len(self.rows[r])):
            if c > 0:
                s += "\t"
            s += self.rows[r][c]
        return s

    def write_to[W: Writer](self, mut writer: W):
        self.policy.write_header(writer)
        for c in range(len(self.schema)):
            if c > 0:
                writer.write("\t")
            writer.write(self.schema[c])
        writer.write("\n")
        for r in range(len(self.rows)):
            writer.write(self.row_text(r), "\n")

    def to_text(self) -> String:
        return String(self)
