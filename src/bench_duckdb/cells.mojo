# The values a query returns, as the value checks see them: a typed cell and a
# result set of rows. A result set comes from `parse_json_rows` (DuckDB's JSON
# output mode) or is built directly by a test or by another engine's adapter.
#
# A DECIMAL is an exact decimal cell (`KIND_DECIMAL`): `s` holds its canonical
# decimal text (decimal_text.mojo), so equal values are equal texts whatever
# scale either engine printed. So is an integer past 64 bits (UBIGINT,
# HUGEINT, UHUGEINT), as a decimal with no fraction. A decimal is never turned
# into a double.

from .decimal_text import canonical_decimal

comptime KIND_NULL: Int = 0
comptime KIND_INT: Int = 1
comptime KIND_FLOAT: Int = 2
comptime KIND_TEXT: Int = 3
comptime KIND_DECIMAL: Int = 4


struct Cell(Copyable, Movable):
    """One value: NULL, a 64-bit integer, a double, a text or an exact
    decimal."""

    var kind: Int
    var i: Int64
    var f: Float64
    var s: String

    def __init__(out self, kind: Int, i: Int64, f: Float64, var s: String):
        self.kind = kind
        self.i = i
        self.f = f
        self.s = s^

    @staticmethod
    def null() -> Cell:
        return Cell(KIND_NULL, Int64(0), Float64(0), String(""))

    @staticmethod
    def integer(v: Int64) -> Cell:
        return Cell(KIND_INT, v, Float64(v), String(""))

    @staticmethod
    def real(v: Float64) -> Cell:
        return Cell(KIND_FLOAT, Int64(0), v, String(""))

    @staticmethod
    def text(var v: String) -> Cell:
        return Cell(KIND_TEXT, Int64(0), Float64(0), v^)

    @staticmethod
    def decimal(text: String) raises -> Cell:
        """The exact decimal written `text` (`[-]digits[.digits]`, at most 38
        fractional digits). Raises on any other text."""
        return Cell(KIND_DECIMAL, Int64(0), Float64(0), canonical_decimal(text))

    def is_null(self) -> Bool:
        return self.kind == KIND_NULL

    def is_numeric(self) -> Bool:
        return self.kind == KIND_INT or self.kind == KIND_FLOAT

    def as_float(self) -> Float64:
        """The numeric value as a double (an integer converts; others, a
        decimal included, give 0: a decimal is compared exactly, never as a
        double)."""
        if self.kind == KIND_INT:
            return Float64(self.i)
        return self.f


struct ResultSet(Copyable, Movable):
    """Column names and the rows, each row one `Cell` per column. `types` holds
    the declared type of each column in the shared vocabulary
    (declared_types.mojo), or is empty when the types were not recorded."""

    var names: List[String]
    var rows: List[List[Cell]]
    var types: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.rows = List[List[Cell]]()
        self.types = List[String]()

    def column_count(self) -> Int:
        return len(self.names)

    def row_count(self) -> Int:
        return len(self.rows)

    def add_row(mut self, var row: List[Cell]):
        self.rows.append(row^)
