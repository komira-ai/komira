# =============================================================================
# sql/sql_series_ast.mojo
#   The parsed call of `generate_series(...)` / `range(...)` in FROM, as plain
#   copyable data. `SqlExpr` is move-only, so the parser reads each argument's
#   literal facts into a `SeriesArg` and keeps no expression tree; an argument
#   that is not a literal is recorded by kind so the binder can refuse it by
#   name (`sql_series_bind`).
# =============================================================================

comptime SERIES_ARG_INT: UInt8 = 0  # an integer literal (`int_val`)
comptime SERIES_ARG_NULL: UInt8 = 1  # NULL
comptime SERIES_ARG_DATE: UInt8 = 2  # `DATE '...'` (raw text in `text`)
comptime SERIES_ARG_TIMESTAMP: UInt8 = 3  # `TIMESTAMP '...'` (text; `aware` False)
comptime SERIES_ARG_TIMESTAMPTZ: UInt8 = 4  # `TIMESTAMPTZ '...'` (text)
comptime SERIES_ARG_INTERVAL: UInt8 = 5  # `INTERVAL n unit` (`int_val` count, `unit` SXIVL_*)
comptime SERIES_ARG_COLUMN: UInt8 = 6  # a column reference (`text` its spelling)
comptime SERIES_ARG_STRING: UInt8 = 7  # a string literal
comptime SERIES_ARG_DECIMAL: UInt8 = 8  # a number literal with a point
comptime SERIES_ARG_OTHER: UInt8 = 9  # any other expression

comptime SERIES_RELATION_PREFIX: String = "series function "
"""The FROM relation name of a series call is this prefix plus the function
name. The space is load-bearing: no tokenizer produces an identifier with a
space, so no catalog table, CTE or derived table can have the name."""


struct SeriesArg(Copyable, Movable):
    """One argument of a series call, reduced to the facts the binder reads."""

    var kind: UInt8  # SERIES_ARG_*
    var int_val: Int64
    var text: String
    var unit: UInt8  # SXIVL_*, for SERIES_ARG_INTERVAL

    def __init__(
        out self,
        kind: UInt8,
        int_val: Int64 = 0,
        text: String = String(""),
        unit: UInt8 = 0,
    ):
        self.kind = kind
        self.int_val = int_val
        self.text = text
        self.unit = unit


struct SeriesCall(Copyable, Movable):
    """`generate_series(args)` or `range(args)` in FROM: the function name
    (`generate_series` / `range`, which is also the output column's name), its
    arguments in order, and the column names of an alias list
    (`AS t(d, ...)`, empty when none was written)."""

    var fn_name: String
    var args: List[SeriesArg]
    var column_names: List[String]

    def __init__(out self, fn_name: String):
        self.fn_name = fn_name
        self.args = List[SeriesArg]()
        self.column_names = List[String]()
