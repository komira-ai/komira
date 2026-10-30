# The order-independent signature of a result set: per column the count of
# non-null cells, the sum, the sum of squares, the minimum and the maximum. Two
# result sets with the same rows in any order have the same signature, so
# engines that return rows in different orders can be compared without sorting.
#
# Integer columns also keep their sum and sum of squares modulo 2^64 (the
# 64-bit wrapping sum): those are exact for any integers, however large, and
# do not depend on the order the rows are added in. The minimum and maximum of
# an integer column are exact too. The double sums are kept for every numeric
# column and are what the comparison uses when the other side is not an integer
# column. Text columns keep the byte length of all cells, the smallest and
# largest cell by byte order, and the sum modulo 2^64 of a hash of each cell,
# so a change to any one cell shows even when the length and the extremes do
# not.

from std.math import isnan

from .cells import Cell, KIND_DECIMAL, KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT, ResultSet
from .decimal_text import ExactSum, canonical_decimal, compare_decimals


def cell_hash(s: String) -> Int64:
    """A 64-bit hash of the bytes of `s` (FNV-1a, then a bit mixer)."""
    var h = UInt64(0xCBF29CE484222325)
    for c in s.as_bytes():
        h = (h ^ UInt64(c)) * UInt64(0x100000001B3)
    h = (h ^ (h >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
    h = (h ^ (h >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    h = h ^ (h >> UInt64(31))
    return h.cast[DType.int64]()


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
    var sum: Float64
    var sumsq: Float64
    var min_v: Float64
    var max_v: Float64
    var isum: Int64
    var isumsq: Int64
    var imin: Int64
    var imax: Int64
    var text_bytes: Int
    var text_hash: Int64
    var text_min: String
    var text_max: String
    var has_decimal: Bool
    var dcount: Int
    var dsum: ExactSum
    var dmin: String
    var dmax: String
    var dhash: Int64

    def __init__(out self):
        self.count = 0
        self.nulls = 0
        self.nans = 0
        self.has_numeric = False
        self.has_text = False
        self.all_int = True
        self.sum = Float64(0)
        self.sumsq = Float64(0)
        self.min_v = Float64(0)
        self.max_v = Float64(0)
        self.isum = Int64(0)
        self.isumsq = Int64(0)
        self.imin = Int64(0)
        self.imax = Int64(0)
        self.text_bytes = 0
        self.text_hash = Int64(0)
        self.text_min = String("")
        self.text_max = String("")
        self.has_decimal = False
        self.dcount = 0
        self.dsum = ExactSum()
        self.dmin = String("0")
        self.dmax = String("0")
        self.dhash = Int64(0)

    def mixed(self) -> Bool:
        """Numbers and texts in one column, or exact decimals and doubles (a
        double has no exact value to put against a decimal)."""
        if self.has_decimal and (self.has_text or not self.all_int):
            return True
        return self.has_numeric and self.has_text

    def kind(self) -> Int:
        """KIND_NULL for a column with no value, KIND_INT for integers only,
        KIND_FLOAT for numbers with a double among them, KIND_DECIMAL for exact
        decimals (integers may be among them), KIND_TEXT for texts (and for a
        mixed column, which never compares equal to anything)."""
        if self.has_text:
            return KIND_TEXT
        if self.has_decimal:
            return KIND_DECIMAL
        if not self.has_numeric:
            return KIND_NULL
        if self.all_int:
            return KIND_INT
        return KIND_FLOAT

    def add(mut self, cell: Cell) raises:
        if cell.kind == KIND_NULL:
            self.nulls += 1
            return
        if cell.kind == KIND_DECIMAL:
            self._add_decimal(cell.s)
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

    def _add_decimal(mut self, text: String) raises:
        var s = canonical_decimal(text)
        if self.dcount == 0 or compare_decimals(s, self.dmin) < 0:
            self.dmin = s
        if self.dcount == 0 or compare_decimals(s, self.dmax) > 0:
            self.dmax = s
        self.dsum.add(s)
        self.dhash += cell_hash(s)
        self.has_decimal = True
        self.dcount += 1
        self.count += 1

    def _add_text(mut self, s: String):
        if self.count == 0 or _bytes_less(s, self.text_min):
            self.text_min = s
        if self.count == 0 or _bytes_less(self.text_max, s):
            self.text_max = s
        self.has_text = True
        self.count += 1
        self.text_bytes += s.byte_length()
        self.text_hash += cell_hash(s)

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
            # The sums wrap modulo 2^64 on purpose: that is the signature.
            self.isum += cell.i
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
