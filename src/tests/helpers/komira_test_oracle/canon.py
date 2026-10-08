"""Canonical result text, read back in Python: parse, check, compare.

The Mojo harness's `parse.mojo` and `compare.mojo` are the authority; this
module follows them for the flat types render.py writes, so that the oracle's
tests can read an expected file without Mojo:

- `parse(text)` refuses what `parse.mojo` refuses (the magic line; exactly
  one `order:` and one `float:` line, overrides naming float columns, keys
  naming one column each; a raw CR; a row with the wrong number of cells; a
  scalar escape canon does not write; a float cell `float_text.mojo`
  refuses) and normalizes each float cell to its canonical text (a
  decimal-only cell exactly representable, or a decimal that rounds to its
  bits, becomes `<shortest decimal>|0x<bits>`; bare `NaN` stays).
- It also checks each cell against its column's type, which `parse.mojo`
  leaves to the compare: `true`/`false` for bool, an integer in range for
  the integer and temporal types, `<unscaled>e<-scale>` within the precision
  for a decimal, lower-case hex for binary, and `\\N` only where the column
  is nullable. A nested or other type this module does not render is refused.
- `emit(parsed)` writes a parsed file back; text equal to `emit(parse(text))`
  is in canonical form (render.py's output always is).
- `compare(expected, actual)` lists every difference under the expected
  side's policy: the policy lines, the schema line, then the rows (`total`
  row by row; `none` as multisets, by a maximum matching; `keys=` the key
  projection in order and each run of equal keys as a multiset). Float
  cells match as `float_text.mojo` matches them: bits for NaN, zeros and
  infinities, otherwise within the tolerance.
"""

from fractions import Fraction

import render

MAGIC = render.CANON_MAGIC
NULL = render.NULL

_INT_RANGE = {
    "int8": (-(2**7), 2**7 - 1),
    "int16": (-(2**15), 2**15 - 1),
    "int32": (-(2**31), 2**31 - 1),
    "int64": (-(2**63), 2**63 - 1),
    "uint8": (0, 2**8 - 1),
    "uint16": (0, 2**16 - 1),
    "uint32": (0, 2**32 - 1),
    "uint64": (0, 2**64 - 1),
    "date32": (-(2**31), 2**31 - 1),
    "date64": (-(2**63), 2**63 - 1),
    "time32_s": (-(2**31), 2**31 - 1),
    "time32_ms": (-(2**31), 2**31 - 1),
    "time64_us": (-(2**63), 2**63 - 1),
    "time64_ns": (-(2**63), 2**63 - 1),
}
_FLOAT_WIDTH = {"float16": 16, "float32": 32, "float64": 64}


class CanonError(ValueError):
    pass


# ---------------------------------------------------------------------------
# Splitting on unescaped separators (escape.mojo)
# ---------------------------------------------------------------------------


def find_unescaped(s, sep, start=0):
    i = start
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == sep:
            return i
        i += 1
    return -1


def split_unescaped(s, sep):
    out = []
    start = 0
    while True:
        at = find_unescaped(s, sep, start)
        if at < 0:
            out.append(s[start:])
            return out
        out.append(s[start:at])
        start = at + 1


# ---------------------------------------------------------------------------
# Cells
# ---------------------------------------------------------------------------


def _canon_hex_escape(s, i):
    h = s[i + 2 : i + 4]
    if len(h) != 2 or any(c not in "0123456789abcdef" for c in h):
        return False
    v = int(h, 16)
    return v not in (9, 10, 13) and (v < 32 or v >= 127)


def check_scalar_cell(cell):
    """escape.mojo's check_scalar_cell: `\\N` is the whole cell or nothing."""
    if cell == NULL:
        return
    i = 0
    while i < len(cell):
        if cell[i] != "\\":
            i += 1
            continue
        if i + 1 >= len(cell):
            raise CanonError("cell %r ends inside an escape" % cell)
        c = cell[i + 1]
        if c in "\\tnr":
            i += 2
        elif c == "x":
            if not _canon_hex_escape(cell, i):
                raise CanonError("cell %r has a \\x escape canon does not write" % cell)
            i += 4
        elif c == "N":
            raise CanonError("cell %r holds \\N inside a value" % cell)
        else:
            raise CanonError("cell %r has an unknown escape" % cell)


def _parse_decimal(text):
    """float_text.mojo's grammar `[-]digits[.digits][(e|E)[+|-]digits]`,
    exactly, as (negative, Fraction)."""
    i, n = 0, len(text)
    neg = text.startswith("-")
    if neg:
        i = 1
    digits, frac_digits, seen_point, nd = 0, 0, False, 0
    while i < n:
        c = text[i]
        if "0" <= c <= "9":
            digits = digits * 10 + ord(c) - 48
            nd += 1
            if seen_point:
                frac_digits += 1
        elif c == "." and not seen_point:
            seen_point = True
        else:
            break
        i += 1
    if nd == 0:
        raise CanonError("%r is not a decimal number" % text)
    exp = 0
    if i < n and text[i] in "eE":
        i += 1
        eneg = False
        if i < n and text[i] in "+-":
            eneg = text[i] == "-"
            i += 1
        start = i
        while i < n and "0" <= text[i] <= "9":
            i += 1
        if i == start:
            raise CanonError("%r has an empty exponent" % text)
        exp = int(text[start:i]) * (-1 if eneg else 1)
    if i != n:
        raise CanonError("%r is not a decimal number" % text)
    if abs(exp - frac_digits) > 1200 or nd > 1200:
        # float_text.mojo's bounds; no float of any width needs more.
        raise CanonError("%r is out of range" % text)
    return neg, Fraction(digits) * Fraction(10) ** (exp - frac_digits)


def _inf_bits(negative, width):
    e, m = render._layout(width)
    return ((1 << (width - 1)) if negative else 0) | (((1 << e) - 1) << m)


def parse_float_cell(text, width):
    """float_text.mojo's parse_float_cell: None for NULL, "NaN" for any NaN,
    else the bits."""
    if text == NULL:
        return None
    if text == "NaN":
        return "NaN"
    sign = 1 << (width - 1)
    bar = text.find("|")
    if bar < 0:
        if text in ("inf", "-inf"):
            return _inf_bits(text == "-inf", width)
        neg, q = _parse_decimal(text)
        if q == 0:
            return sign if neg else 0
        bits = render.round_to_float(-q if neg else q, width)
        if render.float_is_inf(bits, width) or render.float_fraction(bits, width) != (-q if neg else q):
            raise CanonError("%r is not exactly a float%d; write the cell as <decimal>|0x<bits>" % (text, width))
        return bits
    dpart, hpart = text[:bar], text[bar + 1 :]
    if len(hpart) != width // 4 + 2 or hpart[:2] not in ("0x", "0X") or any(c not in "0123456789abcdefABCDEF" for c in hpart[2:]):
        raise CanonError("float bits %r are not 0x and %d hex digits" % (hpart, width // 4))
    bits = int(hpart[2:], 16)
    if dpart == "NaN":
        if not render.float_is_nan(bits, width):
            raise CanonError("%r says NaN but the bits are not a NaN" % text)
        return bits
    if dpart in ("inf", "-inf"):
        if bits != _inf_bits(dpart == "-inf", width):
            raise CanonError("%r says %s but the bits differ" % (text, dpart))
        return bits
    if render.float_is_nan(bits, width) or render.float_is_inf(bits, width):
        raise CanonError("%r gives a number but the bits are NaN or inf" % text)
    neg, q = _parse_decimal(dpart)
    if bits & ~sign == 0:
        ok = q == 0 and neg == bool(bits & sign)
    else:
        ok = q != 0 and neg == bool(bits & sign) and render.round_to_float(-q if neg else q, width) == bits
    if not ok:
        raise CanonError("%r: the decimal does not round to the bits as float%d" % (text, width))
    return bits


def float_canonical(value, width):
    if value is None:
        return NULL
    if value == "NaN":
        return "NaN"
    return render.float_decimal_text(value, width) + "|" + render.bits_hex(value, width)


def _check_integer(cell, lo, hi):
    body = cell[1:] if cell.startswith("-") else cell
    if not body.isdigit() or not body.isascii() or (len(body) > 1 and body[0] == "0") or cell == "-0":
        raise CanonError("%r is not an integer in canonical form" % cell)
    if not lo <= int(cell) <= hi:
        raise CanonError("%r is outside [%d, %d]" % (cell, lo, hi))


def check_typed_cell(type_part, cell):
    """`cell` (not NULL) is a value of the flat type spelt `type_part`;
    returns the cell's canonical text."""
    if type_part in _FLOAT_WIDTH:
        w = _FLOAT_WIDTH[type_part]
        return float_canonical(parse_float_cell(cell, w), w)
    if type_part == "bool":
        if cell not in ("true", "false"):
            raise CanonError("%r is not true or false" % cell)
    elif type_part in _INT_RANGE:
        _check_integer(cell, *_INT_RANGE[type_part])
    elif type_part.startswith("timestamp_") or type_part.startswith("duration_"):
        _check_integer(cell, -(2**63), 2**63 - 1)
    elif type_part.startswith("decimal128(") or type_part.startswith("decimal256("):
        p, s = (int(x) for x in type_part[type_part.index("(") + 1 : -1].split(","))
        at = cell.find("e")
        if at < 0 or cell[at + 1 :] != str(-s):
            raise CanonError("%r is not <unscaled>e%d" % (cell, -s))
        _check_integer(cell[:at], -(10**p) + 1, 10**p - 1)
    elif type_part in ("binary", "large_binary") or type_part.startswith("fixed_size_binary("):
        if len(cell) % 2 or any(c not in "0123456789abcdef" for c in cell):
            raise CanonError("%r is not lower-case hex" % cell)
        if type_part.startswith("fixed_size_binary(") and len(cell) != 2 * int(type_part[18:-1]):
            raise CanonError("%r is not %s bytes" % (cell, type_part[18:-1]))
    elif type_part in ("string", "large_string"):
        check_scalar_cell(cell)
    elif type_part == "null":
        raise CanonError("%r in a null column" % cell)
    else:
        raise CanonError("type %r is not a flat type this module reads" % type_part)
    return cell


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


class Canon:
    def __init__(self):
        self.order = None  # "total" | "none" | "keys"
        self.keys = []  # escaped names
        self.tolerance = None
        self.overrides = []  # [(escaped name, tolerance)]
        self.comments = []  # the `# ...` lines, as written
        self.schema = []  # entries
        self.names = []  # escaped names
        self.types = []  # type parts, without `?`
        self.nullable = []
        self.rows = []

    def tolerance_of(self, c):
        for name, tol in self.overrides:
            if name == self.names[c]:
                return tol
        return self.tolerance


def _parse_tolerance(text):
    if text.startswith("ulps="):
        num = text[5:]
        if not num.isdigit() or not num.isascii() or len(num) > 18:
            raise CanonError("bad tolerance %r" % text)
        return text
    if text.startswith("rel="):
        neg, _ = _parse_decimal(text[4:])
        if neg:
            raise CanonError("negative tolerance %r" % text)
        return text
    raise CanonError("tolerance %r is neither ulps=<n> nor rel=<x>" % text)


def parse(text):
    """Parse and check canonical text (see the module docstring)."""
    if not text.endswith("\n"):
        raise CanonError("the text does not end with a line end")
    lines = text[:-1].split("\n")
    if lines[0] != MAGIC:
        raise CanonError("the first line must be %r" % MAGIC)
    for li, line in enumerate(lines):
        if "\r" in line:
            raise CanonError("line %d holds a raw CR" % (li + 1))
    res = Canon()
    i = 1
    while i < len(lines) and lines[i].startswith("#"):
        line = lines[i]
        where = "line %d: " % (i + 1)
        if line.startswith("#!"):
            raise CanonError(where + "unknown directive %r" % line)
        if line.startswith("#  order: "):
            if res.order is not None:
                raise CanonError(where + "a second order line")
            value = line[10:]
            if value in ("total", "none"):
                res.order = value
            elif value.startswith("keys="):
                res.order = "keys"
                res.keys = split_unescaped(value[5:], ",")
                if any(k == "" for k in res.keys):
                    raise CanonError(where + "an empty key")
            else:
                raise CanonError(where + "order %r is not total, none or keys=" % value)
        elif line.startswith("#  float: "):
            if res.tolerance is not None:
                raise CanonError(where + "a second float line")
            res.tolerance = _parse_tolerance(line[10:])
        elif line.startswith("#  float["):
            close = find_unescaped(line, "]", 9)
            if close < 0 or not line[close:].startswith("]: "):
                raise CanonError(where + "malformed float override %r" % line)
            name = line[9:close]
            if any(n == name for n, _ in res.overrides):
                raise CanonError(where + "a second float override for " + name)
            res.overrides.append((name, _parse_tolerance(line[close + 3 :])))
        elif line.startswith("#  order") or line.startswith("#  float"):
            raise CanonError(where + "malformed directive %r" % line)
        else:
            res.comments.append(line)
        i += 1
    if res.order is None or res.tolerance is None:
        raise CanonError("the header needs both an order line and a float line")
    if i >= len(lines):
        raise CanonError("no schema line")
    if lines[i]:
        for entry in lines[i].split("\t"):
            colon = find_unescaped(entry, ":")
            if colon < 0:
                raise CanonError("schema entry %r has no ':'" % entry)
            type_part = entry[colon + 1 :]
            nullable = type_part.endswith("?")
            res.schema.append(entry)
            res.names.append(entry[:colon])
            res.types.append(type_part[:-1] if nullable else type_part)
            res.nullable.append(nullable)
    ncols = len(res.schema)
    for k in res.keys:
        if res.names.count(k) != 1:
            raise CanonError("order key %r names %d columns, not one" % (k, res.names.count(k)))
    for name, _ in res.overrides:
        if name not in res.names or res.types[res.names.index(name)] not in _FLOAT_WIDTH:
            raise CanonError("float override %r names no float column" % name)
    for li in range(i + 1, len(lines)):
        line = lines[li]
        if ncols == 0:
            if line:
                raise CanonError("line %d: a row of a zero-column result must be empty" % (li + 1))
            res.rows.append([])
            continue
        row = line.split("\t")
        if len(row) != ncols:
            raise CanonError("line %d has %d cells, the schema %d" % (li + 1, len(row), ncols))
        for c in range(ncols):
            try:
                if row[c] == NULL:
                    if not res.nullable[c]:
                        raise CanonError("NULL in a column that is not nullable")
                else:
                    row[c] = check_typed_cell(res.types[c], row[c])
            except CanonError as e:
                raise CanonError("line %d column %s: %s" % (li + 1, res.names[c], e)) from None
        res.rows.append(row)
    return res


def emit(res):
    """The text of a parsed file, every cell in canonical form."""
    keys = "keys=" + ",".join(res.keys) if res.order == "keys" else res.order
    lines = [MAGIC, "#  order: " + keys, "#  float: " + res.tolerance]
    lines += ["#  float[%s]: %s" % o for o in res.overrides]
    lines += res.comments
    lines.append("\t".join(res.schema))
    lines += ["\t".join(r) for r in res.rows]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------


def _ulp_distance(a, b, width):
    sign = 1 << (width - 1)
    ma, mb = a & ~sign, b & ~sign
    if (a & sign) != (b & sign):
        return ma + mb
    return abs(ma - mb)


def float_cells_match(e, a, tol, width):
    """float_text.mojo's float_cells_match, on canonical cells."""
    ev = parse_float_cell(e, width)
    av = parse_float_cell(a, width)
    if ev is None or av is None:
        return ev is None and av is None
    a_nan = av == "NaN" or render.float_is_nan(av, width)
    if ev == "NaN":
        return a_nan
    if render.float_is_nan(ev, width):
        return av != "NaN" and av == ev
    if a_nan:
        return False
    zero = ~(1 << (width - 1))
    if render.float_is_inf(ev, width) or render.float_is_inf(av, width) or (ev & zero == 0 and av & zero == 0):
        return ev == av
    if tol.startswith("rel="):
        x = _parse_decimal(tol[4:])[1]
        fe, fa = render.float_fraction(ev, width), render.float_fraction(av, width)
        return abs(fe - fa) <= x * max(abs(fe), abs(fa))
    return _ulp_distance(ev, av, width) <= int(tol[5:])


def _row_match(exp, act, er, ar):
    for c in range(len(exp.schema)):
        t = exp.types[c]
        if t in _FLOAT_WIDTH:
            if not float_cells_match(er[c], ar[c], exp.tolerance_of(c), _FLOAT_WIDTH[t]):
                return False
        elif er[c] != ar[c]:
            return False
    return True


def _multiset_unmatched(exp, act, erows, arows):
    """A maximum matching of actual rows to expected rows (Kuhn's augmenting
    paths); returns the expected and actual rows left unmatched."""
    adj = [[j for j, ar in enumerate(arows) if _row_match(exp, act, er, ar)] for er in erows]
    owner = [-1] * len(arows)

    def augment(i, seen):
        for j in adj[i]:
            if j in seen:
                continue
            seen.add(j)
            if owner[j] < 0 or augment(owner[j], seen):
                owner[j] = i
                return True
        return False

    matched = set()
    for i in range(len(erows)):
        if augment(i, set()):
            pass
    for j, i in enumerate(owner):
        if i >= 0:
            matched.add(i)
    return [erows[i] for i in range(len(erows)) if i not in matched], [arows[j] for j in range(len(arows)) if owner[j] < 0]


def compare(exp, act):
    """Every difference between parsed `exp` (expected) and `act`, under the
    expected side's policy; [] when they match."""
    diffs = []
    if (exp.order, exp.keys, exp.tolerance, exp.overrides) != (act.order, act.keys, act.tolerance, act.overrides):
        diffs.append("policy: expected order %s %s float %s %s, actual order %s %s float %s %s" % (
            exp.order, exp.keys, exp.tolerance, exp.overrides, act.order, act.keys, act.tolerance, act.overrides))
    if exp.schema != act.schema:
        diffs.append("schema: expected %r, actual %r" % ("\t".join(exp.schema), "\t".join(act.schema)))
        return diffs
    if len(exp.rows) != len(act.rows):
        diffs.append("rows: expected %d, actual %d" % (len(exp.rows), len(act.rows)))
    if exp.order == "total":
        for r in range(min(len(exp.rows), len(act.rows))):
            if not _row_match(exp, act, exp.rows[r], act.rows[r]):
                diffs.append("row %d: expected %r, actual %r" % (r + 1, "\t".join(exp.rows[r]), "\t".join(act.rows[r])))
        return diffs
    if exp.order == "none":
        groups = [(exp.rows, act.rows)]
    else:
        kc = [exp.names.index(k) for k in exp.keys]
        groups = []
        r = 0
        while r < len(exp.rows):
            key = [exp.rows[r][c] for c in kc]
            end = r
            while end < len(exp.rows) and [exp.rows[end][c] for c in kc] == key:
                end += 1
            groups.append((exp.rows[r:end], act.rows[r:end]))
            r = end
    for erows, arows in groups:
        missing, extra = _multiset_unmatched(exp, act, erows, arows)
        for row in missing:
            diffs.append("expected row not in the result: %r" % "\t".join(row))
        for row in extra:
            diffs.append("result row not expected: %r" % "\t".join(row))
    return diffs
