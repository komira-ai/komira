"""The answer check of the TPC-H conformance run through the installed wheel
(test_tpch_installed.py), a Python rendering of the rules of bench_duckdb
(src/bench_duckdb): the order-independent signature of a result set, its
comparison with a recorded DuckDB answer, and the row-order check.

The recorded answers are the text of `komira//src/tpch_answers:tpch_sf1[answers.txt]`
(`format 3`, src/bench_duckdb/reference.mojo). What a result column adds up to
and how two are compared is what src/bench_duckdb/signature.mojo and
compare.mojo say:

- integers: count, nulls, and the sum, sum of squares, minimum and maximum
  exactly (the sums modulo 2^64, as signed 64-bit numbers);
- doubles: the same four with a tolerance (the larger of 1e-6 absolute and 1e-9
  of the larger magnitude); an integer column against a double column compares
  as numbers with that tolerance;
- exact decimals (DECIMAL): count, exact sum, smallest, largest and the hash
  sum of the canonical texts, exactly; never as doubles;
- texts (and DATE as `YYYY-MM-DD`): byte length, smallest, largest and the hash
  sum, exactly;
- the declared type of each column (`BIGINT`, `DECIMAL(15,2)`, ...) must be the
  same text, except HUGEINT against DECIMAL(38,0), which Arrow cannot tell apart
  (an allowed departure when the values are equal).

Column names are not compared. This module imports pyarrow only to read a
`pyarrow.Table` (`result_of_table`); everything else is the standard library.
"""

import decimal
import math
import struct

REL_TOL = 1e-9
ABS_FLOOR = 1e-6

KIND_NULL = 0
KIND_INT = 1
KIND_FLOAT = 2
KIND_TEXT = 3
KIND_DECIMAL = 4

_MASK = (1 << 64) - 1
_NAMES = {KIND_NULL: "no value", KIND_INT: "integer", KIND_FLOAT: "double", KIND_TEXT: "text", KIND_DECIMAL: "exact decimal"}

# A decimal context wide enough to add any number of 38-digit decimals exactly.
_EXACT = decimal.Context(prec=400, traps=[decimal.InvalidOperation, decimal.Inexact])


class Refused(Exception):
    """A result column the conversion has no cell for; the message starts with
    the token `RESULT_TYPE_UNSUPPORTED`."""


def wrap64(v):
    """`v` as a signed 64-bit number, wrapping as Int64 arithmetic does."""
    v &= _MASK
    return v - (1 << 64) if v >= (1 << 63) else v


def cell_hash(s):
    """FNV-1a over the UTF-8 bytes of `s`, then the bit mixer, as a signed
    64-bit number (bench_duckdb.signature.cell_hash)."""
    h = 0xCBF29CE484222325
    for c in s.encode("utf-8"):
        h = ((h ^ c) * 0x100000001B3) & _MASK
    h = ((h ^ (h >> 30)) * 0xBF58476D1CE4E5B9) & _MASK
    h = ((h ^ (h >> 27)) * 0x94D049BB133111EB) & _MASK
    h ^= h >> 31
    return wrap64(h)


def canonical_decimal(text):
    """`text` (`[-]digits[.digits]`) without leading zeros, trailing fraction
    zeros, an empty point or a sign on zero."""
    neg = text.startswith("-")
    body = text[1:] if neg else text
    whole, _, frac = body.partition(".")
    if not whole.isdigit() or (frac and not frac.isdigit()) or ("." in body and not frac):
        raise ValueError("not a decimal number: " + text)
    whole = whole.lstrip("0") or "0"
    frac = frac.rstrip("0")
    if len(frac) > 38:
        raise ValueError("a decimal with more than 38 fractional digits: " + text)
    out = whole + ("." + frac if frac else "")
    return "-" + out if neg and out != "0" else out


def decimal_text(d):
    """A `decimal.Decimal` as canonical decimal text, never in exponent form."""
    return canonical_decimal(format(d, "f"))


class Cell:
    """One value: a kind and, by kind, an int, a float or a text (a decimal's
    canonical text)."""

    __slots__ = ("kind", "value")

    def __init__(self, kind, value=None):
        self.kind = kind
        self.value = value


def null():
    return Cell(KIND_NULL)


def integer(v):
    return Cell(KIND_INT, v)


def real(v):
    return Cell(KIND_FLOAT, float(v))


def text(v):
    return Cell(KIND_TEXT, v)


def exact(v):
    return Cell(KIND_DECIMAL, canonical_decimal(v))


class Column:
    """What one column of a result adds up to (signature.mojo,
    ColumnSignature)."""

    def __init__(self):
        self.count = 0
        self.nulls = 0
        self.nans = 0
        self.has_numeric = False
        self.has_text = False
        self.has_decimal = False
        self.all_int = True
        self.sum = 0.0
        self.sumsq = 0.0
        self.min_v = 0.0
        self.max_v = 0.0
        self.isum = 0
        self.isumsq = 0
        self.imin = 0
        self.imax = 0
        self.text_bytes = 0
        self.text_hash = 0
        self.text_min = ""
        self.text_max = ""
        self.dcount = 0
        self.dsum = decimal.Decimal(0)
        self.dmin = "0"
        self.dmax = "0"
        self.dhash = 0

    def mixed(self):
        if self.has_decimal and (self.has_text or not self.all_int):
            return True
        return self.has_numeric and self.has_text

    def kind(self):
        if self.has_text:
            return KIND_TEXT
        if self.has_decimal:
            return KIND_DECIMAL
        if not self.has_numeric:
            return KIND_NULL
        return KIND_INT if self.all_int else KIND_FLOAT

    def add(self, cell):
        if cell.kind == KIND_NULL:
            self.nulls += 1
        elif cell.kind == KIND_DECIMAL:
            s = cell.value
            d = decimal.Decimal(s)
            if self.dcount == 0 or d < decimal.Decimal(self.dmin):
                self.dmin = s
            if self.dcount == 0 or d > decimal.Decimal(self.dmax):
                self.dmax = s
            self.dsum = _EXACT.add(self.dsum, d)
            self.dhash = wrap64(self.dhash + cell_hash(s))
            self.has_decimal = True
            self.dcount += 1
            self.count += 1
        elif cell.kind == KIND_TEXT:
            s = cell.value
            b = s.encode("utf-8")
            if self.count == 0 or b < self.text_min.encode("utf-8"):
                self.text_min = s
            if self.count == 0 or b > self.text_max.encode("utf-8"):
                self.text_max = s
            self.has_text = True
            self.count += 1
            self.text_bytes += len(b)
            self.text_hash = wrap64(self.text_hash + cell_hash(s))
        else:
            v = float(cell.value)
            if cell.kind == KIND_FLOAT:
                self.all_int = False
                if math.isnan(v):
                    self.nans += 1
                    return
            first = self.count == 0
            if first or v < self.min_v:
                self.min_v = v
            if first or v > self.max_v:
                self.max_v = v
            self.sum += v
            self.sumsq += v * v
            self.has_numeric = True
            if cell.kind == KIND_INT:
                i = cell.value
                self.isum = wrap64(self.isum + i)
                self.isumsq = wrap64(self.isumsq + i * i)
                if first or i < self.imin:
                    self.imin = i
                if first or i > self.imax:
                    self.imax = i
            self.count += 1


class Signature:
    """The row count, one `Column` per column and the declared types."""

    def __init__(self, rows=0, columns=None, types=None):
        self.rows = rows
        self.columns = columns if columns is not None else []
        self.types = types if types is not None else []


class Result:
    """Rows of cells and the declared type of each column."""

    def __init__(self, rows, types):
        self.rows = rows
        self.types = types


def signature_of(result):
    width = len(result.types) if result.types else (len(result.rows[0]) if result.rows else 0)
    if result.rows and result.types and len(result.types) != width:
        raise ValueError("the result has {} columns and {} declared types".format(width, len(result.types)))
    sig = Signature(len(result.rows), [Column() for _ in range(width)], list(result.types))
    for r, row in enumerate(result.rows):
        if len(row) != width:
            raise ValueError("row {} has {} cells, expected {}".format(r, len(row), width))
        for c, cell in enumerate(row):
            sig.columns[c].add(cell)
    return sig


def _float32_text(x):
    """The shortest decimal text that reads back as the same float32, the way
    DuckDB prints a FLOAT."""
    for p in range(1, 10):
        s = "{:.{}g}".format(x, p)
        if struct.unpack("f", struct.pack("f", float(s)))[0] == x:
            return s
    return repr(x)


def _declared_type(t):
    import pyarrow

    types = pyarrow.types
    if types.is_decimal128(t):
        return "DECIMAL({},{})".format(t.precision, t.scale)
    for test, name in (
        (types.is_boolean, "BOOLEAN"),
        (types.is_int8, "TINYINT"),
        (types.is_int16, "SMALLINT"),
        (types.is_int32, "INTEGER"),
        (types.is_int64, "BIGINT"),
        (types.is_uint8, "UTINYINT"),
        (types.is_uint16, "USMALLINT"),
        (types.is_uint32, "UINTEGER"),
        (types.is_uint64, "UBIGINT"),
        (types.is_float32, "FLOAT"),
        (types.is_float64, "DOUBLE"),
        (types.is_string, "VARCHAR"),
        (types.is_large_string, "VARCHAR"),
        (types.is_date32, "DATE"),
    ):
        if test(t):
            return name
    return "UNMAPPED(arrow type {})".format(t)


def _cell_of(t, v):
    import pyarrow

    types = pyarrow.types
    if v is None:
        return null()
    if types.is_decimal128(t):
        return exact(decimal_text(v))
    if types.is_float64(t):
        return real(v)
    if types.is_float32(t):
        return real(float(_float32_text(v)) if math.isfinite(v) else v)
    if types.is_uint64(t):
        return integer(v) if v <= (1 << 63) - 1 else exact(str(v))
    if types.is_integer(t):
        return integer(v)
    if types.is_date32(t):
        if not (1 <= v.year <= 9999):
            raise Refused("RESULT_TYPE_UNSUPPORTED: DATE {} is outside the years 0001 to 9999".format(v))
        return text(v.isoformat())
    if types.is_string(t) or types.is_large_string(t):
        return text(v)
    raise Refused("RESULT_TYPE_UNSUPPORTED: arrow type {}".format(t))


def result_of_table(table):
    """A `pyarrow.Table` as a `Result`: the cells and declared types of
    src/bench_runner/convert.mojo. A column of an Arrow type that has no cell
    raises `Refused` (`RESULT_TYPE_UNSUPPORTED`)."""
    fields = [table.schema.field(i).type for i in range(table.num_columns)]
    types = [_declared_type(t) for t in fields]
    for t in fields:
        if not _cell_of_supported(t):
            raise Refused("RESULT_TYPE_UNSUPPORTED: arrow type {}".format(t))
    columns = [table.column(i).to_pylist() for i in range(table.num_columns)]
    rows = []
    for r in range(table.num_rows):
        rows.append([_cell_of(fields[c], columns[c][r]) for c in range(table.num_columns)])
    return Result(rows, types)


def _cell_of_supported(t):
    import pyarrow

    types = pyarrow.types
    return (
        types.is_decimal128(t)
        or types.is_float32(t)
        or types.is_float64(t)
        or types.is_integer(t)
        or types.is_date32(t)
        or types.is_string(t)
        or types.is_large_string(t)
    )


# ---- Comparison -----------------------------------------------------------


def numbers_close(a, b, rel_tol=REL_TOL, abs_floor=ABS_FLOOR):
    if a == b:
        return True
    if math.isnan(a) or math.isnan(b) or math.isinf(a) or math.isinf(b):
        return False
    allowed = max(abs_floor, rel_tol * max(abs(a), abs(b)))
    return abs(a - b) <= allowed


_DEPARTURES = {frozenset(("HUGEINT", "DECIMAL(38,0)")): "Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)"}


def _compare_column(reasons, c, a, b):
    col = "column {}".format(c)
    if a.mixed() or b.mixed():
        reasons.append(col + " mixes values that cannot be compared (numbers and texts, or exact decimals and doubles)")
        return
    numeric_mix = {a.kind(), b.kind()} == {KIND_INT, KIND_FLOAT}
    if a.kind() != b.kind() and not numeric_mix:
        reasons.append("{} has kind {} ({}) against {} ({})".format(col, a.kind(), _NAMES[a.kind()], b.kind(), _NAMES[b.kind()]))
        return
    for what, x, y in (("count", a.count, b.count), ("null count", a.nulls, b.nulls), ("NaN count", a.nans, b.nans)):
        if x != y:
            reasons.append("{} {} differs: {} against {}".format(col, what, x, y))
    kind = a.kind()
    if kind == KIND_NULL:
        return
    if kind == KIND_TEXT:
        if a.text_bytes != b.text_bytes:
            reasons.append("{} text length differs: {} against {}".format(col, a.text_bytes, b.text_bytes))
        if a.text_min != b.text_min:
            reasons.append(col + " smallest text differs")
        if a.text_max != b.text_max:
            reasons.append(col + " largest text differs")
        if a.text_hash != b.text_hash:
            reasons.append(col + " texts differ (the hash sum of the cells)")
        return
    if kind == KIND_DECIMAL:
        if a.dcount != b.dcount:
            reasons.append("{} decimal count differs: {} against {}".format(col, a.dcount, b.dcount))
        if a.dsum != b.dsum:
            reasons.append("{} sum differs: {} against {}".format(col, decimal_text(a.dsum), decimal_text(b.dsum)))
        if decimal.Decimal(a.dmin) != decimal.Decimal(b.dmin):
            reasons.append("{} minimum differs: {} against {}".format(col, a.dmin, b.dmin))
        if decimal.Decimal(a.dmax) != decimal.Decimal(b.dmax):
            reasons.append("{} maximum differs: {} against {}".format(col, a.dmax, b.dmax))
        if a.dhash != b.dhash:
            reasons.append(col + " decimals differ (the hash sum of the cells)")
        _exact_ints(reasons, col, a, b)
        return
    if kind == KIND_INT and not numeric_mix:
        _exact_ints(reasons, col, a, b)
        return
    for what, x, y in (
        ("sum", a.sum, b.sum),
        ("sum of squares", a.sumsq, b.sumsq),
        ("minimum", a.min_v, b.min_v),
        ("maximum", a.max_v, b.max_v),
    ):
        if not numbers_close(x, y):
            reasons.append("{} {} differs: {} against {}".format(col, what, x, y))


def _exact_ints(reasons, col, a, b):
    for what, x, y in (
        ("sum", a.isum, b.isum),
        ("sum of squares", a.isumsq, b.isumsq),
        ("minimum", a.imin, b.imin),
        ("maximum", a.imax, b.imax),
    ):
        if x != y:
            reasons.append("{} {} differs: {} against {}".format(col, what, x, y))


def compare(actual, expected):
    """The reasons `actual` (a `Signature` of the wheel's answer) differs from
    the recorded `expected`: an empty list when they agree, and the allowed
    departures of the declared types when they agree except for those, as the
    second value."""
    reasons = []
    departures = []
    if actual.rows != expected.rows:
        reasons.append("row count differs: {} against {}".format(actual.rows, expected.rows))
    if len(actual.columns) != len(expected.columns):
        reasons.append("column count differs: {} against {}".format(len(actual.columns), len(expected.columns)))
        return reasons, departures
    if len(actual.types) != len(expected.types):
        reasons.append("declared type count differs: {} against {}".format(len(actual.types), len(expected.types)))
    else:
        for c, (x, y) in enumerate(zip(actual.types, expected.types)):
            if x.startswith("UNMAPPED("):
                reasons.append("column {} declared type {} is not in the mapping".format(c, x))
            elif x != y:
                why = _DEPARTURES.get(frozenset((x, y)))
                if why:
                    if why not in departures:
                        departures.append(why)
                else:
                    reasons.append("column {} declared type differs: {} against {}".format(c, x, y))
    for c, (x, y) in enumerate(zip(actual.columns, expected.columns)):
        _compare_column(reasons, c, x, y)
    if reasons:
        departures = []
    return reasons, departures


# ---- Order ----------------------------------------------------------------


def _order_cells(a, b):
    if a.kind == KIND_TEXT or b.kind == KIND_TEXT:
        if a.kind != b.kind:
            raise ValueError("a sort key column holds a number and a text")
        x, y = a.value.encode("utf-8"), b.value.encode("utf-8")
        return (x > y) - (x < y)
    if a.kind == KIND_DECIMAL or b.kind == KIND_DECIMAL:
        if a.kind not in (KIND_DECIMAL, KIND_INT) or b.kind not in (KIND_DECIMAL, KIND_INT):
            raise ValueError("a sort key column holds a decimal and a double")
        x, y = decimal.Decimal(str(a.value)), decimal.Decimal(str(b.value))
        return (x > y) - (x < y)
    if a.kind == KIND_INT and b.kind == KIND_INT:
        return (a.value > b.value) - (a.value < b.value)
    p, q = float(a.value), float(b.value)
    if math.isnan(p) or math.isnan(q):
        if math.isnan(p) and math.isnan(q):
            return 0
        return 1 if math.isnan(p) else -1
    return (p > q) - (p < q)


def check_order(result, keys):
    """None when the rows of `result` are in the order of `keys` (tuples
    `(column, descending, nulls_first)`), else the reason of the first row that
    sorts before the row above it. NULLs sort last unless a key says first."""
    width = len(result.types)
    for column, _, _ in keys:
        if column < 0 or column >= width:
            raise ValueError("sort key column {} is out of range".format(column))
    for r in range(1, len(result.rows)):
        if _compare_rows(result.rows[r - 1], result.rows[r], keys) > 0:
            return "row {} sorts before the row above it".format(r)
    return None


def _compare_rows(a, b, keys):
    for column, descending, nulls_first in keys:
        ca, cb = a[column], b[column]
        an, bn = ca.kind == KIND_NULL, cb.kind == KIND_NULL
        if an and bn:
            continue
        if an != bn:
            return -1 if an == nulls_first else 1
        c = _order_cells(ca, cb)
        if descending:
            c = -c
        if c:
            return c
    return 0


# ---- The recorded answers ---------------------------------------------------


class Answer:
    def __init__(self, query):
        self.query = query
        self.signature = Signature()
        self.order = []


def _unhex(token):
    if not token.startswith("x"):
        raise ValueError("not a hex text: " + token)
    return bytes.fromhex(token[1:]).decode("utf-8")


def _column_of(tokens):
    if len(tokens) != 23:
        raise ValueError("a column line has 23 fields, got {}".format(len(tokens)))
    kind = int(tokens[1])
    if not KIND_NULL <= kind <= KIND_DECIMAL:
        raise ValueError("unknown column kind " + tokens[1])
    col = Column()
    col.has_numeric = kind in (KIND_INT, KIND_FLOAT)
    col.has_text = kind == KIND_TEXT
    col.has_decimal = kind == KIND_DECIMAL
    col.all_int = kind != KIND_FLOAT
    col.count, col.nulls, col.nans = int(tokens[2]), int(tokens[3]), int(tokens[4])
    col.isum, col.isumsq, col.imin, col.imax = (int(t) for t in tokens[5:9])
    col.sum, col.sumsq, col.min_v, col.max_v = (float(t) for t in tokens[9:13])
    col.text_bytes, col.text_hash = int(tokens[13]), int(tokens[14])
    col.text_min, col.text_max = _unhex(tokens[15]), _unhex(tokens[16])
    col.dcount = int(tokens[17])
    col.dsum = decimal.Decimal(tokens[18])
    col.dmin, col.dmax = canonical_decimal(tokens[19]), canonical_decimal(tokens[20])
    col.dhash = int(tokens[21])
    return col


def parse_answers(path):
    """The recorded answers of the file at `path`, by query id (`q1` ..).
    Reads `format 3` only and raises on anything it does not know."""
    answers = {}
    current = None
    have_format = False
    have_rows = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            tokens = line.split()
            if not tokens or tokens[0].startswith("#"):
                continue
            head = tokens[0]
            if head == "format":
                if current is not None or len(tokens) != 2 or tokens[1] != "3":
                    raise ValueError("the reference answers are not in format 3: " + line.strip())
                have_format = True
            elif head == "query":
                if not have_format or current is not None or len(tokens) != 2 or tokens[1] in answers:
                    raise ValueError("bad query line: " + line.strip())
                current = Answer(tokens[1])
                have_rows = False
            elif current is None:
                raise ValueError("a line outside a record: " + line.strip())
            elif head == "rows":
                current.signature.rows = int(tokens[1])
                have_rows = True
            elif head == "order":
                for item in tokens[1].split(","):
                    column, direction, nulls = item.split(":")
                    if direction not in ("a", "d") or nulls not in ("f", "l"):
                        raise ValueError("bad order key: " + item)
                    current.order.append((int(column), direction == "d", nulls == "f"))
            elif head == "column":
                current.signature.columns.append(_column_of(tokens))
                current.signature.types.append(tokens[22])
            elif head == "end":
                if not have_rows:
                    raise ValueError("record {} has no rows line".format(current.query))
                answers[current.query] = current
                current = None
            else:
                raise ValueError("unknown line: " + line.strip())
    if current is not None:
        raise ValueError("record {} has no end line".format(current.query))
    return answers

