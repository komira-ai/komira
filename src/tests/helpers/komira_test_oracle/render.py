"""A pyarrow Table as the canonical result text of komira_plan_harness.

The Mojo harness (`komira_plan_harness`: `canon_text.mojo` the format,
`render.mojo` the cells, `escape.mojo` the escapes, `float_text.mojo` the
floats) renders the actual side of a conformance case; this module renders
the expected side from a pyarrow table, so that the two texts are the same
bytes for the same result. Flat types only: a nested or dictionary column,
an interval or a view type is refused by name, never spelt by code no case
exercises. The file:

    #! komira-plan-conformance v1
    #  order: total | none | keys=<c1>,<c2>
    #  float: ulps=<n> | rel=<x>
    #  float[<column>]: ulps=<n> | rel=<x>        (zero or more)
    # <comment>                                   (zero or more)
    <name>:<type>[?]<TAB>...                      (schema_text.py)
    <cell><TAB><cell>...                          (one line per row)

Cells (NULL is `\\N` for every type, from the column's validity alone):

    bool                      true | false
    int8..int64, uint8..64    the decimal integer
    float16, float32, float64 <shortest decimal>|0x<IEEE bits, upper case,
                              width/4 digits>; `-0.0`, `inf`, `-inf` spelt so.
                              A NaN is bare `NaN`: the harness's expected-side
                              default, which matches any NaN, because the bits
                              of a NaN a computation makes depend on the
                              machine (canon_text.mojo).
    string, large_string      the UTF-8 bytes, escaped: `\\\\`, `\\t`, `\\n`,
                              `\\r`, `\\xHH` for any other control byte, DEL
                              and a byte that is not well-formed UTF-8
    binary, large_binary,
    fixed_size_binary         lower-case hex, two digits a byte
    date32, date64, time32_*,
    time64_*, timestamp_*,
    duration_*                the stored integer, in the column's unit
    decimal128, decimal256    <unscaled integer>e<-scale> (`12345e-2`)
    null                      \\N

The shortest decimal is what Mojo's float formatting writes (the harness
calls `String(Float64)`, `String(Float32)`, and widens float16 to float32):
the shortest digits that read back as the same float of that width, nearest
the exact value, laid out as Python's `repr` lays out a float (scientific
below 1e-4 and from 1e16, `e+NN` / `e-NN` with at least two exponent
digits, a trailing `.0` on an integral value).
"""

import struct
from fractions import Fraction

import pyarrow as pa

import schema_text

CANON_MAGIC = "#! komira-plan-conformance v1"
NULL = "\\N"


# ---------------------------------------------------------------------------
# Floats
# ---------------------------------------------------------------------------

_LAYOUT = {16: (5, 10), 32: (8, 23), 64: (11, 52)}  # width -> (exponent bits, mantissa bits)


def _layout(width):
    if width not in _LAYOUT:
        raise ValueError("render: no float of width %r" % (width,))
    return _LAYOUT[width]


def float_is_nan(bits, width):
    e, m = _layout(width)
    return (bits >> m) & ((1 << e) - 1) == (1 << e) - 1 and bits & ((1 << m) - 1) != 0


def float_is_inf(bits, width):
    e, m = _layout(width)
    return (bits >> m) & ((1 << e) - 1) == (1 << e) - 1 and bits & ((1 << m) - 1) == 0


def float_fraction(bits, width):
    """The exact value of a finite bit pattern."""
    e, m = _layout(width)
    bias = (1 << (e - 1)) - 1
    field = (bits >> m) & ((1 << e) - 1)
    frac = bits & ((1 << m) - 1)
    if field == 0:
        mag = Fraction(frac) * Fraction(2) ** (1 - bias - m)
    else:
        mag = Fraction(frac | (1 << m)) * Fraction(2) ** (field - bias - m)
    return -mag if bits >> (width - 1) else mag


def round_to_float(q, width):
    """The bits of the float of `width` nearest the Fraction `q`, ties to the
    even mantissa (IEEE round-to-nearest); an overflow is the infinity."""
    e, m = _layout(width)
    bias = (1 << (e - 1)) - 1
    sign = (1 << (width - 1)) if q < 0 else 0
    a = abs(q)
    if a == 0:
        return sign
    exp = a.numerator.bit_length() - a.denominator.bit_length()
    if Fraction(2) ** exp > a:
        exp -= 1
    exp = max(exp, 1 - bias)  # below the normal range: the subnormal grid
    scaled = a / Fraction(2) ** (exp - m)
    mant = scaled.numerator // scaled.denominator
    rest = scaled - mant
    if rest > Fraction(1, 2) or (rest == Fraction(1, 2) and mant % 2 == 1):
        mant += 1
    if mant == 1 << (m + 1):
        mant >>= 1
        exp += 1
    if mant < (1 << m):
        return sign | mant  # subnormal (or zero)
    if exp > bias:
        return sign | (((1 << e) - 1) << m)
    return sign | ((exp + bias) << m) | (mant - (1 << m))


def _f32_bits_of_f16(bits):
    """float16 bits widened exactly to float32 bits."""
    if float_is_nan(bits, 16) or float_is_inf(bits, 16):
        sign = (bits >> 15) << 31
        return sign | (0xFF << 23) | ((bits & 0x3FF) << 13)
    return round_to_float(float_fraction(bits, 16), 32)


def shortest_digits(bits, width):
    """(digits, exponent) of a finite non-zero float: the fewest significant
    digits whose decimal reads back as the same float of `width`, the one
    nearest the exact value when there are several (ties to the even last
    digit). The value is `d.ddd x 10**exponent`, `digits` without trailing
    zeros."""
    v = float_fraction(bits, width)
    a = abs(v)
    # e10: the decimal exponent of the leading digit, 10**e10 <= a < 10**(e10+1).
    e10 = len(str(a.numerator)) - len(str(a.denominator))
    while Fraction(10) ** e10 > a:
        e10 -= 1
    while Fraction(10) ** (e10 + 1) <= a:
        e10 += 1
    target = bits & ~(1 << (width - 1))
    for p in range(1, 40):
        unit = Fraction(10) ** (e10 - p + 1)
        lo = (a / unit).numerator // (a / unit).denominator
        best = None
        for d in (lo, lo + 1):
            if d <= 0 or round_to_float(d * unit, width) != target:
                continue
            dist = abs(d * unit - a)
            if best is None or dist < best[0] or (dist == best[0] and d % 2 == 0):
                best = (dist, d)
        if best is not None:
            d = best[1]
            s = str(d)
            exp = e10 + len(s) - p  # d may have carried to p + 1 digits
            return s.rstrip("0") or "0", exp
    raise AssertionError("render: no shortest decimal for 0x%x" % bits)


def layout_decimal(negative, digits, exp):
    """`digits` (d.ddd x 10**exp) laid out as Mojo's float writer (and
    Python's repr) lays it out."""
    sign = "-" if negative else ""
    if exp < -4 or exp > 15:
        mant = digits[0] + ("." + digits[1:] if len(digits) > 1 else "")
        return "%s%se%s%02d" % (sign, mant, "-" if exp < 0 else "+", abs(exp))
    if exp < 0:
        return sign + "0." + "0" * (-exp - 1) + digits
    whole = digits[: exp + 1].ljust(exp + 1, "0")
    frac = digits[exp + 1 :] or "0"
    return sign + whole + "." + frac


def float_decimal_text(bits, width):
    """The readable half of a float cell, as the harness writes it."""
    if float_is_nan(bits, width):
        return "NaN"
    negative = bool(bits >> (width - 1))
    if float_is_inf(bits, width):
        return "-inf" if negative else "inf"
    if bits & ~(1 << (width - 1)) == 0:
        return "-0.0" if negative else "0.0"
    if width == 16:
        bits, width = _f32_bits_of_f16(bits), 32
    digits, exp = shortest_digits(bits, width)
    return layout_decimal(negative, digits, exp)


def bits_hex(bits, width):
    return "0x%0*X" % (width // 4, bits)


def float_cell(bits, width):
    """`<decimal>|0x<bits>`, or bare `NaN` for any NaN."""
    if float_is_nan(bits, width):
        return "NaN"
    return float_decimal_text(bits, width) + "|" + bits_hex(bits, width)


# ---------------------------------------------------------------------------
# Escapes (escape.mojo)
# ---------------------------------------------------------------------------

def _utf8_len(bs, i):
    """Length of the well-formed UTF-8 sequence at `i`, or 0 (RFC 3629: no
    overlong form, no surrogate, nothing above U+10FFFF)."""
    b0 = bs[i]
    if b0 < 0x80:
        return 1
    lo, hi = 0x80, 0xBF
    if 0xC2 <= b0 <= 0xDF:
        need = 2
    elif 0xE0 <= b0 <= 0xEF:
        need = 3
        if b0 == 0xE0:
            lo = 0xA0
        elif b0 == 0xED:
            hi = 0x9F
    elif 0xF0 <= b0 <= 0xF4:
        need = 4
        if b0 == 0xF0:
            lo = 0x90
        elif b0 == 0xF4:
            hi = 0x8F
    else:
        return 0
    if i + need > len(bs):
        return 0
    if not lo <= bs[i + 1] <= hi:
        return 0
    for k in range(2, need):
        if not 0x80 <= bs[i + k] <= 0xBF:
            return 0
    return need


def escape_bytes(bs):
    """A scalar value's bytes as escaped text (names: schema_text.escape_name)."""
    out = []
    i = 0
    while i < len(bs):
        b = bs[i]
        if b == 0x5C:
            out.append("\\\\")
        elif b == 9:
            out.append("\\t")
        elif b == 10:
            out.append("\\n")
        elif b == 13:
            out.append("\\r")
        elif b < 32 or b == 127:
            out.append("\\x%02x" % b)
        elif b < 0x80:
            out.append(chr(b))
        else:
            k = _utf8_len(bs, i)
            if k == 0:
                out.append("\\x%02x" % b)
            else:
                out.append(bytes(bs[i : i + k]).decode("utf-8"))
                i += k
                continue
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# Columns
# ---------------------------------------------------------------------------

_INTEGER_VIEW = [
    (pa.types.is_date32, pa.int32()),
    (pa.types.is_date64, pa.int64()),
    (pa.types.is_time32, pa.int32()),
    (pa.types.is_time64, pa.int64()),
    (pa.types.is_timestamp, pa.int64()),
    (pa.types.is_duration, pa.int64()),
]

_FLOATS = [
    (pa.types.is_float16, 16, pa.uint16()),
    (pa.types.is_float32, 32, pa.uint32()),
    (pa.types.is_float64, 64, pa.uint64()),
]


def _decimal_cells(arr):
    t = arr.type
    width = 16 if pa.types.is_decimal128(t) else 32
    buf = arr.buffers()[1]
    raw = memoryview(buf) if buf is not None else memoryview(b"")
    out = []
    for i in range(len(arr)):
        if not arr[i].is_valid:
            out.append(NULL)
            continue
        at = (arr.offset + i) * width
        unscaled = int.from_bytes(raw[at : at + width], "little", signed=True)
        out.append("%de%d" % (unscaled, -t.scale))
    return out


def render_column(arr):
    """One cell per row of a flat pyarrow Array (render.mojo, flat part)."""
    t = arr.type
    if pa.types.is_null(t):
        return [NULL] * len(arr)
    if pa.types.is_boolean(t):
        return [NULL if v is None else ("true" if v else "false") for v in arr.to_pylist()]
    if pa.types.is_integer(t):
        return [NULL if v is None else str(v) for v in arr.to_pylist()]
    for is_kind, width, as_bits in _FLOATS:
        if is_kind(t):
            return [NULL if v is None else float_cell(v, width) for v in arr.view(as_bits).to_pylist()]
    for is_kind, as_int in _INTEGER_VIEW:
        if is_kind(t):
            return [NULL if v is None else str(v) for v in arr.view(as_int).to_pylist()]
    if pa.types.is_decimal128(t) or pa.types.is_decimal256(t):
        return _decimal_cells(arr)
    if pa.types.is_string(t) or pa.types.is_large_string(t):
        raw = arr.view(pa.binary() if pa.types.is_string(t) else pa.large_binary())
        return [NULL if v is None else escape_bytes(v) for v in raw.to_pylist()]
    if pa.types.is_binary(t) or pa.types.is_large_binary(t) or pa.types.is_fixed_size_binary(t):
        return [NULL if v is None else v.hex() for v in arr.to_pylist()]
    raise ValueError("render: column type %s is not rendered (flat types only)" % t)


# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------


class Policy:
    """How a result is compared: `order` is "total", "none" or "keys" with
    `keys` (plain column names); `tolerance` and each of `overrides`
    ({plain column name: tolerance}) spelt `ulps=<n>` or `rel=<x>`."""

    def __init__(self, order="total", keys=(), tolerance="ulps=0", overrides=None):
        if order not in ("total", "none", "keys"):
            raise ValueError("render: order %r is not total, none or keys" % (order,))
        if (order == "keys") != bool(keys):
            raise ValueError("render: keys are given exactly with order keys")
        self.order = order
        self.keys = list(keys)
        self.tolerance = tolerance
        self.overrides = dict(overrides or {})

    def header_lines(self):
        if self.order == "keys":
            order = "keys=" + ",".join(schema_text.escape_name(k) for k in self.keys)
        else:
            order = self.order
        lines = [CANON_MAGIC, "#  order: " + order, "#  float: " + self.tolerance]
        for name in self.overrides:
            lines.append("#  float[%s]: %s" % (schema_text.escape_name(name), self.overrides[name]))
        return lines


def render_table(table, policy, comments=(), not_null=None):
    """The canonical text of `table` under `policy`, `comments` written as
    `# <comment>` lines after the header. Nullability is the schema's own,
    or, with `not_null` (a set of plain names), nullable for every column but
    those: DuckDB's result types carry no nullability, so a case declares
    it. A column declared not nullable that holds a NULL is refused (that
    declaration would be a defect), as is a name in `not_null`, a key or an
    override that names no column, or an override on a column that is not a
    float."""
    names = table.column_names
    if len(set(names)) != len(names):
        raise ValueError("render: duplicate column names %r" % (names,))
    for what, given in (("not_null", not_null or ()), ("order key", policy.keys), ("float override", policy.overrides)):
        for name in given:
            if name not in names:
                raise ValueError("render: %s %r names no column of %r" % (what, name, names))
    for name in policy.overrides:
        if not pa.types.is_floating(table.schema.field(name).type):
            raise ValueError("render: float override %r names a column of type %s" % (name, table.schema.field(name).type))
    lines = policy.header_lines()
    for c in comments:
        if "\n" in c or "\r" in c:
            raise ValueError("render: a comment holds a line end: %r" % (c,))
        lines.append("# " + c)
    entries = []
    columns = []
    for field in table.schema:
        nullable = field.nullable if not_null is None else field.name not in not_null
        col = table.column(field.name)
        if not nullable and col.null_count:
            raise ValueError("render: column %r is declared not nullable and holds %d NULLs" % (field.name, col.null_count))
        entries.append(schema_text.escape_name(field.name) + ":" + schema_text.type_spelling(field.type) + ("?" if nullable else ""))
        cells = []
        for chunk in col.chunks:
            cells.extend(render_column(chunk))
        columns.append(cells)
    lines.append("\t".join(entries))
    for r in range(table.num_rows):
        lines.append("\t".join(cells[r] for cells in columns))
    return "\n".join(lines) + "\n"
