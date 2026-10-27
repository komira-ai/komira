# The order-independent signature of a result set: per column the count of
# non-null cells, the sum, the sum of squares, the minimum and the maximum. Two
# result sets with the same rows in any order have the same signature, so
# engines that return rows in different orders can be compared without sorting.
#
# Integer columns also keep their sums as 64-bit integers. The sum stays exact
# while every partial sum of absolute values stays below 2^53 (the largest
# range a double holds exactly), and the sum of squares likewise; past that the
# field is compared with the relative tolerance instead (see compare.mojo). The
# minimum and maximum of an integer column are always exact. Text columns keep
# the byte length of all cells, and the smallest and largest cell by byte
# order.

from std.math import isnan

from .cells import Cell, KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT, ResultSet

comptime EXACT_LIMIT: Float64 = 9007199254740992.0
"""2^53: below it every integer is a double, so sums of integers are exact."""


def _bytes_less(a: String, b: String) -> Bool:
    """Byte-wise order of two texts."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = len(x)
    if len(y) < n:
        n = len(y)
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


struct ColumnSignature(Copyable, Movable):
    """What one column of a result set adds up to."""

    var count: Int
    var nulls: Int
    var nans: Int
    var has_numeric: Bool
    var has_text: Bool
    var all_int: Bool
    var sum_exact: Bool
    var sumsq_exact: Bool
    var sum: Float64
    var sumsq: Float64
    var min_v: Float64
    var max_v: Float64
    var abs_sum: Float64
    var isum: Int64
    var isumsq: Int64
    var imin: Int64
    var imax: Int64
    var text_bytes: Int
    var text_min: String
    var text_max: String

    def __init__(out self):
        self.count = 0
        self.nulls = 0
        self.nans = 0
        self.has_numeric = False
        self.has_text = False
        self.all_int = True
        self.sum_exact = True
        self.sumsq_exact = True
        self.sum = Float64(0)
        self.sumsq = Float64(0)
        self.min_v = Float64(0)
        self.max_v = Float64(0)
        self.abs_sum = Float64(0)
        self.isum = Int64(0)
        self.isumsq = Int64(0)
        self.imin = Int64(0)
        self.imax = Int64(0)
        self.text_bytes = 0
        self.text_min = String("")
        self.text_max = String("")

    def mixed(self) -> Bool:
        """Numbers and texts in one column."""
        return self.has_numeric and self.has_text

    def kind(self) -> Int:
        """KIND_NULL for a column with no value, KIND_INT for integers only,
        KIND_FLOAT for numbers with a double among them, KIND_TEXT for texts
        (and for a mixed column, which never compares equal to anything)."""
        if self.has_text:
            return KIND_TEXT
        if not self.has_numeric:
            return KIND_NULL
        if self.all_int:
            return KIND_INT
        return KIND_FLOAT

    def add(mut self, cell: Cell):
        if cell.kind == KIND_NULL:
            self.nulls += 1
            return
        if cell.kind == KIND_TEXT:
            self._add_text(cell.s)
            return
        var v = cell.as_float()
        if cell.kind == KIND_FLOAT:
            self.all_int = False
            if isnan(v):
                self.nans += 1
                return
        self._add_number(cell, v)

    def _add_text(mut self, s: String):
        if self.count == 0 or _bytes_less(s, self.text_min):
            self.text_min = s
        if self.count == 0 or _bytes_less(self.text_max, s):
            self.text_max = s
        self.has_text = True
        self.count += 1
        self.text_bytes += s.byte_length()

    def _add_number(mut self, cell: Cell, v: Float64):
        var first = self.count == 0
        if first or v < self.min_v:
            self.min_v = v
        if first or v > self.max_v:
            self.max_v = v
        self.sum += v
        self.sumsq += v * v
        self.has_numeric = True
        if cell.kind == KIND_INT:
            var av = abs(v)
            self.abs_sum += av
            if av >= EXACT_LIMIT or self.abs_sum >= EXACT_LIMIT:
                self.sum_exact = False
            if av >= EXACT_LIMIT or self.sumsq >= EXACT_LIMIT:
                self.sumsq_exact = False
            if self.sum_exact:
                self.isum += cell.i
            if self.sumsq_exact:
                self.isumsq += cell.i * cell.i
            if first or cell.i < self.imin:
                self.imin = cell.i
            if first or cell.i > self.imax:
                self.imax = cell.i
        self.count += 1


struct ResultSignature(Copyable, Movable):
    """The row count and one `ColumnSignature` per column."""

    var rows: Int
    var columns: List[ColumnSignature]

    def __init__(out self):
        self.rows = 0
        self.columns = List[ColumnSignature]()


def signature_of(rs: ResultSet) raises -> ResultSignature:
    """The signature of `rs`. Raises when a row has a different number of cells
    than the result has columns."""
    var out = ResultSignature()
    out.rows = rs.row_count()
    var width = rs.column_count()
    if width == 0 and rs.row_count() > 0:
        width = len(rs.rows[0])
    for _ in range(width):
        out.columns.append(ColumnSignature())
    for r in range(rs.row_count()):
        if len(rs.rows[r]) != width:
            raise Error(
                String("row ") + String(r) + String(" has ")
                + String(len(rs.rows[r])) + String(" cells, expected ")
                + String(width)
            )
        for c in range(width):
            out.columns[c].add(rs.rows[r][c])
    return out^
