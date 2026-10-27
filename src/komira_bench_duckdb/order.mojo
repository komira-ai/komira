# The row-order check of a query with a top-level ORDER BY: the rows must be
# monotone in the sort keys. The signature (signature.mojo) ignores order on
# purpose, so this check is separate.
#
# NULLs sort after every other value in both directions (DuckDB's default),
# unless a key says otherwise. Two integers compare as integers (exactly, past
# 2^53 too); NaN sorts after every number and ties with NaN, as DuckDB sorts it.

from .cells import Cell, KIND_INT, KIND_NULL, KIND_TEXT, ResultSet


struct OrderKey(Copyable, Movable):
    """One ORDER BY key: a zero-based column, a direction and where NULLs go."""

    var column: Int
    var descending: Bool
    var nulls_first: Bool

    def __init__(out self, column: Int, descending: Bool = False, nulls_first: Bool = False):
        self.column = column
        self.descending = descending
        self.nulls_first = nulls_first


struct OrderVerdict(Copyable, Movable):
    """`ok`, or the first row that sorts before the row above it."""

    var ok: Bool
    var row: Int
    var reason: String

    def __init__(out self):
        self.ok = True
        self.row = -1
        self.reason = String("")

    def label(self) -> String:
        if self.ok:
            return String("OK")
        return String("VIOLATED: row ") + String(self.row) + String(" ") + self.reason


def _compare_cells(a: Cell, b: Cell) raises -> Int:
    """-1, 0 or 1 for two non-null cells of one column. Raises for a number
    against a text."""
    if a.kind == KIND_TEXT or b.kind == KIND_TEXT:
        if a.kind != b.kind:
            raise Error("a sort key column holds a number and a text")
        var x = a.s.as_bytes()
        var y = b.s.as_bytes()
        var n = len(x)
        if len(y) < n:
            n = len(y)
        for i in range(n):
            if x[i] != y[i]:
                return -1 if x[i] < y[i] else 1
        if len(x) == len(y):
            return 0
        return -1 if len(x) < len(y) else 1
    if a.kind == KIND_INT and b.kind == KIND_INT:
        if a.i < b.i:
            return -1
        return 1 if a.i > b.i else 0
    var p = a.as_float()
    var q = b.as_float()
    if p != p or q != q:
        if p != p and q != q:
            return 0
        return 1 if p != p else -1
    if p < q:
        return -1
    if p > q:
        return 1
    return 0


def _compare_rows(
    a: List[Cell], b: List[Cell], keys: List[OrderKey]
) raises -> Int:
    """The order of row `a` against row `b` under the keys: negative when `a`
    sorts first, zero when the keys tie, positive when `b` sorts first."""
    for k in range(len(keys)):
        var key = keys[k].copy()
        var ca = a[key.column].copy()
        var cb = b[key.column].copy()
        var an = ca.kind == KIND_NULL
        var bn = cb.kind == KIND_NULL
        if an and bn:
            continue
        if an != bn:
            var a_first = an == key.nulls_first
            return -1 if a_first else 1
        var c = _compare_cells(ca, cb)
        if key.descending:
            c = -c
        if c != 0:
            return c
    return 0


def check_order(rs: ResultSet, keys: List[OrderKey]) raises -> OrderVerdict:
    """Whether the rows of `rs` are in the order of `keys`. A key naming a
    column the result does not have raises."""
    var v = OrderVerdict()
    for k in range(len(keys)):
        if keys[k].column < 0 or keys[k].column >= rs.column_count():
            raise Error(String("sort key column ") + String(keys[k].column) + String(" is out of range"))
    for r in range(1, rs.row_count()):
        if _compare_rows(rs.rows[r - 1], rs.rows[r], keys) > 0:
            v.ok = False
            v.row = r
            v.reason = String("sorts before the row above it")
            return v^
    return v^
