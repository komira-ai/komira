# =============================================================================
# komira_plan_harness/duckdb_tsv.mojo -- an expected result as DuckDB writes
# it, read by value into canonical text.
# =============================================================================
#
# The oracle (komira_test_oracle) writes each expected answer with DuckDB's
# CSV writer: `COPY (<query>) TO 'expected.tsv' (FORMAT csv, DELIMITER '\t',
# HEADER true)`. The file form, as the pinned DuckDB writes it:
#
#   - a header line of column names, then one line per row, LF line ends,
#     TAB between cells;
#   - NULL is an empty unquoted cell; a cell is quoted with `"` when it is
#     the empty string (`""`) or holds a TAB, LF, CR or `"`, and a `"`
#     inside a quoted cell is doubled; a quoted cell may span lines;
#   - a boolean is `true` or `false`; an integer is its decimal digits; a
#     decimal of scale s has exactly s digits after the point; a float is
#     the shortest decimal that reads back as it (`0.1`, `-0.0`,
#     `1e+300`, `1.5e-07`), `nan` or `-nan` for a NaN and `inf` or `-inf`.
#
# parse_duckdb_tsv reads that form (anything else is refused with its line);
# duckdb_tsv_canon converts it to canonical text by VALUE, given the schema
# of the canonical result it is compared with (a HAND expectation, or a
# rendered engine result): the column names must equal the schema's, and
# each cell is read as a value of its column's type and spelt as canon spells
# that value:
#
#   bool                      true | false, nothing else
#   int8..int64, uint8..64    a decimal integer in the type's range; no sign
#                             on an unsigned type
#   float16/32/64             the float the decimal rounds to (round half to
#                             even, decided in exact arithmetic by
#                             float_text.decimal_rounds_to), as
#                             `<decimal>|0x<bits>`; `nan` and `-nan` are a
#                             bare `NaN` (any NaN: the spelling keeps no
#                             payload); `inf`, `-inf`
#   decimal128(p,s)           `<unscaled>e<-s>`, the cell's digits without
#                             the point, at most p of them
#   date32                    the day number from 1970-01-01, as canon spells
#                             a date32, read from `YYYY-MM-DD` (a year of four
#                             or more digits, a month and a day that exist in
#                             the proleptic Gregorian calendar); a date
#                             DuckDB writes with ` (BC)` is refused
#   string, large_string      the cell's text, escaped as canon escapes it
#   timestamp_s/ms/us/ns      the ticks of the unit from 1970-01-01 00:00:00,
#                             as canon spells a timestamp, read from
#                             `YYYY-MM-DD HH:MM:SS[.f]`: the date as for
#                             date32, a time of day that exists, and a
#                             fraction as DuckDB writes it (no trailing zero,
#                             none on a whole second, at most the unit's
#                             digits); a time zone, ` (BC)` and an infinite
#                             timestamp are refused
#   list, large_list of       DuckDB's list text (`[a, 'b c', NULL]`: items
#   string or large_string    joined by `, `, an item quoted with `'` exactly
#                             when DuckDB quotes it: the empty string, any
#                             case of `null`, leading or trailing whitespace,
#                             or one of `,[]{}():'"=`; `\\` and `\'` inside
#                             quotes; `NULL` bare for a NULL item) as canon
#                             spells a list, `[a,b c,\N]`, `\e` for an empty
#                             string item; any other item type is refused
#
# NULL is `\N` in any column whose schema entry ends in `?`, and refused in
# one that does not. Any other type is refused by name: a value this reader
# cannot read exactly is never compared as text. The policy (row order, float
# tolerance) is the schema side's; compare_canon then compares the two by
# value under it, so `1.50` in one and `1.5` in the other are the same float.
# =============================================================================

from std.memory import bitcast

from .canon_text import CanonText
from .escape import escape_name, escape_string, find_unescaped
from .float_text import (
    _inf_bits,
    decimal_rounds_to,
    float_cell_text,
    float_is_inf,
    float_is_nan,
    parse_decimal,
)


struct DuckdbTsv(Movable):
    """A DuckDB TSV as read: the header's names and the rows' cells, each
    None for NULL (an empty unquoted cell) or the cell's text unquoted."""

    var names: List[String]
    var rows: List[List[Optional[String]]]

    def __init__(out self):
        self.names = List[String]()
        self.rows = List[List[Optional[String]]]()


def _cell_text(bs: Span[UInt8, _], start: Int, end: Int) -> String:
    var out = List[UInt8](capacity=end - start)
    for k in range(start, end):
        out.append(bs[k])
    return String(unsafe_from_utf8=Span(out))


def parse_duckdb_tsv(text: String) raises -> DuckdbTsv:
    """Read DuckDB's CSV writer output with a TAB delimiter and a header
    (the module header gives the form). Refused: no header, an unterminated
    quoted cell, anything but a TAB or a line end after a closing quote, a
    `"` or CR in an unquoted cell, a row whose cell count is not the
    header's, a last line without its LF, a header cell that is NULL."""
    var bs = text.as_bytes()
    var n = len(bs)
    var res = DuckdbTsv()
    var records = List[List[Optional[String]]]()
    var i = 0
    var line = 1
    while i < n:
        var rec = List[Optional[String]]()
        var rec_line = line
        while True:
            if i < n and bs[i] == 34:  # '"': a quoted cell
                var q = List[UInt8]()
                i += 1
                var closed = False
                while i < n:
                    if bs[i] == 34:
                        if i + 1 < n and bs[i + 1] == 34:
                            q.append(34)
                            i += 2
                            continue
                        i += 1
                        closed = True
                        break
                    if bs[i] == 10:
                        line += 1
                    q.append(bs[i])
                    i += 1
                if not closed:
                    raise Error(
                        "duckdb_tsv: line " + String(rec_line)
                        + ": a quoted cell is not closed"
                    )
                if i < n and bs[i] != 9 and bs[i] != 10:
                    raise Error(
                        "duckdb_tsv: line " + String(line)
                        + ": a closing quote is followed by something other than a TAB or a line end"
                    )
                rec.append(Optional(String(unsafe_from_utf8=Span(q))))
            else:
                var start = i
                while i < n and bs[i] != 9 and bs[i] != 10:
                    if bs[i] == 34 or bs[i] == 13:
                        raise Error(
                            "duckdb_tsv: line " + String(line)
                            + ": an unquoted cell holds a quote or a CR"
                        )
                    i += 1
                if i == start:
                    rec.append(Optional[String](None))
                else:
                    rec.append(Optional(_cell_text(bs, start, i)))
            if i >= n:
                raise Error(
                    "duckdb_tsv: line " + String(line) + " does not end in LF"
                )
            if bs[i] == 9:
                i += 1
                continue
            # LF: the record ends.
            i += 1
            line += 1
            break
        records.append(rec^)
    if len(records) == 0:
        raise Error("duckdb_tsv: no header line")
    for c in range(len(records[0])):
        if not records[0][c]:
            raise Error(
                "duckdb_tsv: header cell " + String(c + 1) + " is empty"
            )
        res.names.append(records[0][c].value())
    var ncols = len(res.names)
    for r in range(1, len(records)):
        if len(records[r]) != ncols:
            raise Error(
                "duckdb_tsv: row " + String(r) + " has " + String(len(records[r]))
                + " cells, the header " + String(ncols)
            )
        res.rows.append(records[r].copy())
    return res^


# ---------------------------------------------------------------------------
# Cells by value
# ---------------------------------------------------------------------------


def _type_of(entry: String) raises -> String:
    """The type part of a schema entry, without the trailing `?`."""
    var colon = find_unescaped(entry, 58)  # ':'
    if colon < 0:
        raise Error("duckdb_tsv: schema entry '" + entry + "' has no ':'")
    var end = entry.byte_length()
    if entry.endswith("?"):
        end -= 1
    return String(entry[byte = colon + 1 : end])


def _is_digits(bs: Span[UInt8, _], start: Int, end: Int) -> Bool:
    if start >= end:
        return False
    for k in range(start, end):
        if bs[k] < 48 or bs[k] > 57:
            return False
    return True


def _strip_zeros(s: String) -> String:
    var bs = s.as_bytes()
    var k = 0
    while k < len(bs) - 1 and bs[k] == 48:
        k += 1
    return String(s[byte = k : s.byte_length()])


def _digits_le(a: String, b: String) -> Bool:
    """Two digit strings without leading zeros: a <= b as numbers."""
    if a.byte_length() != b.byte_length():
        return a.byte_length() < b.byte_length()
    return a <= b


def _int_bounds(t: String) -> Tuple[Bool, String, String]:
    """(known, the largest magnitude below zero, the largest above), the
    first "" for an unsigned type."""
    if t == "int8":
        return (True, String("128"), String("127"))
    if t == "int16":
        return (True, String("32768"), String("32767"))
    if t == "int32":
        return (True, String("2147483648"), String("2147483647"))
    if t == "int64":
        return (True, String("9223372036854775808"), String("9223372036854775807"))
    if t == "uint8":
        return (True, String(""), String("255"))
    if t == "uint16":
        return (True, String(""), String("65535"))
    if t == "uint32":
        return (True, String(""), String("4294967295"))
    if t == "uint64":
        return (True, String(""), String("18446744073709551615"))
    return (False, String(""), String(""))


def _int_cell(cell: String, t: String, lo: String, hi: String) raises -> String:
    var bs = cell.as_bytes()
    var negative = len(bs) > 0 and bs[0] == 45
    var start = 1 if negative else 0
    if not _is_digits(bs, start, len(bs)):
        raise Error("'" + cell + "' is not an integer")
    var mag = _strip_zeros(String(cell[byte = start : cell.byte_length()]))
    if mag == "0":
        return mag
    if negative:
        if lo.byte_length() == 0:
            raise Error("'" + cell + "' is negative, and " + t + " is unsigned")
        if not _digits_le(mag, lo):
            raise Error("'" + cell + "' is below the range of " + t)
        return "-" + mag
    if not _digits_le(mag, hi):
        raise Error("'" + cell + "' is above the range of " + t)
    return mag


def _decimal_params(t: String) raises -> Tuple[Int, Int]:
    # decimal128(<p>,<s>)
    var open = t.find("(")
    var comma = t.find(",")
    if open < 0 or comma < open or not t.endswith(")"):
        raise Error("duckdb_tsv: decimal type '" + t + "' has no (p,s)")
    var p = atol(String(t[byte = open + 1 : comma]))
    var s = atol(String(t[byte = comma + 1 : t.byte_length() - 1]))
    return (p, s)


def _decimal_cell(cell: String, p: Int, s: Int) raises -> String:
    var bs = cell.as_bytes()
    var negative = len(bs) > 0 and bs[0] == 45
    var start = 1 if negative else 0
    var point = cell.find(".")
    var int_end = len(bs) if point < 0 else point
    if not _is_digits(bs, start, int_end):
        raise Error("'" + cell + "' is not a decimal")
    var frac = String("")
    if point >= 0:
        if not _is_digits(bs, point + 1, len(bs)):
            raise Error("'" + cell + "' is not a decimal")
        frac = String(cell[byte = point + 1 : cell.byte_length()])
    if frac.byte_length() != s:
        raise Error(
            "'" + cell + "' has " + String(frac.byte_length())
            + " digits after the point, the scale is " + String(s)
        )
    var digits = _strip_zeros(String(cell[byte=start:int_end]) + frac)
    if digits.byte_length() > p:
        raise Error("'" + cell + "' has more than " + String(p) + " digits")
    var res = digits
    if negative and digits != "0":
        res = "-" + digits
    return res + "e" + String(-s)


def _days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        var leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
        return 29 if leap else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _date_cell(cell: String) raises -> String:
    """The day number of `YYYY-MM-DD` from 1970-01-01, as decimal text."""
    return String(_date_days(cell))


def _date_days(cell: String) raises -> Int:
    """The day number of `YYYY-MM-DD` from 1970-01-01."""
    var bs = cell.as_bytes()
    var n = len(bs)
    if (
        n < 10
        or bs[n - 3] != 45
        or bs[n - 6] != 45
        or not _is_digits(bs, 0, n - 6)
        or not _is_digits(bs, n - 5, n - 3)
        or not _is_digits(bs, n - 2, n)
    ):
        raise Error("'" + cell + "' is not a date YYYY-MM-DD")
    var y = atol(String(cell[byte = 0 : n - 6]))
    var m = atol(String(cell[byte = n - 5 : n - 3]))
    var d = atol(String(cell[byte = n - 2 : n]))
    if m < 1 or m > 12 or d < 1 or d > _days_in_month(y, m):
        raise Error("'" + cell + "' is not a day of the calendar")
    # Days from civil (proleptic Gregorian), the year starting in March.
    var yy = y - 1 if m <= 2 else y
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _timestamp_digits(t: String) -> Int:
    """The fraction digits a timestamp type without a time zone holds (0, 3,
    6, 9), or -1 for any other type."""
    if t == "timestamp_s":
        return 0
    if t == "timestamp_ms":
        return 3
    if t == "timestamp_us":
        return 6
    if t == "timestamp_ns":
        return 9
    return -1


def _timestamp_cell(cell: String, digits: Int) raises -> String:
    """`YYYY-MM-DD HH:MM:SS[.f]` as the count of the unit's ticks from
    1970-01-01 00:00:00 (`digits` fraction digits a second), as decimal text.
    The fraction is DuckDB's: no trailing zero, none at all on a whole
    second, at most the unit's digits."""
    if cell == "infinity" or cell == "-infinity":
        raise Error("'" + cell + "' is not read: an infinite timestamp")
    if " (BC)" in cell:
        raise Error("'" + cell + "' is not read: a timestamp before year 1")
    var sp = cell.find(" ")
    if sp < 0:
        raise Error("'" + cell + "' is not a timestamp YYYY-MM-DD HH:MM:SS")
    var days = _date_days(String(cell[byte=0:sp]))
    var time = String(cell[byte = sp + 1 : cell.byte_length()])
    var bs = time.as_bytes()
    var n = len(bs)
    if (
        n < 8
        or bs[2] != 58
        or bs[5] != 58
        or not _is_digits(bs, 0, 2)
        or not _is_digits(bs, 3, 5)
        or not _is_digits(bs, 6, 8)
    ):
        raise Error("'" + cell + "' is not a timestamp YYYY-MM-DD HH:MM:SS")
    var h = atol(String(time[byte=0:2]))
    var mi = atol(String(time[byte=3:5]))
    var sec = atol(String(time[byte=6:8]))
    if h > 23 or mi > 59 or sec > 59:
        raise Error("'" + cell + "' is not a time of day")
    var frac = String("")
    if n > 8:
        if bs[8] != 46 or not _is_digits(bs, 9, n):
            raise Error("'" + cell + "' is not a timestamp YYYY-MM-DD HH:MM:SS[.f]")
        frac = String(time[byte=9:n])
        if bs[n - 1] == 48:
            raise Error("'" + cell + "' has a trailing zero in its fraction")
        if n - 9 > digits:
            raise Error(
                "'" + cell + "' has " + String(n - 9) + " fraction digits, the unit "
                + String(digits)
            )
    var scale = 1
    for _ in range(digits):
        scale *= 10
    var sub = 0
    if frac.byte_length() > 0:
        sub = atol(frac)
        for _ in range(digits - frac.byte_length()):
            sub *= 10
    var secs = days * 86400 + h * 3600 + mi * 60 + sec
    # The Int64 range in the unit (a nanosecond timestamp spans 1677 to
    # 2262), checked before any product can overflow.
    var out_of_range = Error("'" + cell + "' is outside the unit's 64-bit range")
    if secs >= 0:
        if secs > (Int(Int64.MAX) - sub) // scale:
            raise out_of_range^
        return String(secs * scale + sub)
    # Below the epoch: the magnitude secs * scale - sub, in UInt64.
    var m = UInt64(-secs)
    if m > UInt64.MAX // UInt64(scale):
        raise out_of_range^
    var mag = m * UInt64(scale) - UInt64(sub)
    if mag > UInt64(1) << 63:
        raise out_of_range^
    return "-" + String(mag)


def _list_item_type(t: String) -> String:
    """The item type of `list<...>` or `large_list<...>`, else ""."""
    if not t.endswith(">"):
        return String("")
    var open = t.find("<")
    if open < 0:
        return String("")
    var base = String(t[byte=0:open])
    if base != "list" and base != "large_list":
        return String("")
    return String(t[byte = open + 1 : t.byte_length() - 1])


def _is_space(b: UInt8) -> Bool:
    return b == 32 or (b >= 9 and b <= 13)


def _duckdb_quotes(s: String) -> Bool:
    """Does DuckDB write `s` quoted inside a list: the empty string, any case
    of `null`, a string that starts or ends with whitespace, or one holding
    one of `,[]{}():'"=`?"""
    var bs = s.as_bytes()
    var n = len(bs)
    if n == 0 or s.lower() == "null":
        return True
    if _is_space(bs[0]) or _is_space(bs[n - 1]):
        return True
    for i in range(n):
        var b = bs[i]
        if (
            b == 44 or b == 91 or b == 93 or b == 123 or b == 125 or b == 40
            or b == 41 or b == 58 or b == 39 or b == 34 or b == 61
        ):
            return True
    return False


def _list_cell(cell: String) raises -> String:
    """A list of strings as DuckDB writes it (`[a, 'b c', NULL]`: items
    joined by `, `, an item quoted with `'` exactly when _duckdb_quotes says
    so, `\\` and `\'` inside the quotes, `NULL` bare for a NULL item) as
    canon spells it (`[a,b c,\\N]`)."""
    var bs = cell.as_bytes()
    var n = len(bs)
    if n < 2 or bs[0] != 91 or bs[n - 1] != 93:
        raise Error("'" + cell + "' is not a list [...]")
    if n == 2:
        return String("[]")
    var items = String("[")
    var i = 1
    var first = True
    while True:
        if not first:
            items += ","
        first = False
        if bs[i] == 39:  # a quoted item
            var raw = List[UInt8]()
            var j = i + 1
            var closed = False
            while j < n - 1:
                var b = bs[j]
                if b == 92:
                    if j + 1 >= n - 1 or (bs[j + 1] != 92 and bs[j + 1] != 39):
                        raise Error("'" + cell + "' has an escape DuckDB does not write")
                    raw.append(bs[j + 1])
                    j += 2
                    continue
                if b == 39:
                    closed = True
                    j += 1
                    break
                raw.append(b)
                j += 1
            if not closed:
                raise Error("'" + cell + "' has an unterminated quoted item")
            var item = String(unsafe_from_utf8=Span(raw))
            if not _duckdb_quotes(item):
                raise Error("'" + cell + "' quotes an item DuckDB writes bare")
            items += escape_string(item, True)
            i = j
        else:  # a bare item: up to the next `,` or the closing bracket
            var j = i
            while j < n - 1 and bs[j] != 44:
                j += 1
            var item = _cell_text(bs, i, j)
            if item == "NULL":
                items += "\\N"
            elif _duckdb_quotes(item):
                raise Error("'" + cell + "' has a bare item DuckDB would quote")
            else:
                items += escape_string(item, True)
            i = j
        if i == n - 1:
            break
        if i + 2 >= n - 1 or bs[i] != 44 or bs[i + 1] != 32:
            raise Error("'" + cell + "' does not separate its items with ', '")
        i += 2
    return items + "]"


def _float_width(t: String) -> Int:
    if t == "float16":
        return 16
    if t == "float32":
        return 32
    if t == "float64":
        return 64
    return 0


def _bits_of(x: Float64, width: Int) -> UInt64:
    if width == 64:
        return bitcast[DType.uint64](x)
    if width == 32:
        return UInt64(bitcast[DType.uint32](x.cast[DType.float32]()))
    return UInt64(bitcast[DType.uint16](x.cast[DType.float16]()))


def _guess_text(cell: String, exp10: Int) -> String:
    """`cell`'s value cut to its first 17 significant digits, as
    `[-]0.<digits>e<exp>`: within one Float64 ulp of the value, and short
    enough for the standard library's parse, which refuses a long digit
    string. `exp10` is parse_decimal's (the value is the cell's digits
    times 10^exp10)."""
    var bs = cell.as_bytes()
    var sig = String()
    var nsig = 0
    var negative = False
    for i in range(len(bs)):
        var b = bs[i]
        if b == 45:  # '-'
            negative = True
        elif b == 101 or b == 69:  # 'e' / 'E': the digits end here
            break
        elif b >= 48 and b <= 57 and (nsig > 0 or b != 48):
            if nsig < 17:
                sig += chr(Int(b))
            nsig += 1
    var res = String("-0.") if negative else String("0.")
    return res + sig + "e" + String(exp10 + nsig)


def _float_cell(cell: String, width: Int) raises -> String:
    if cell == "nan" or cell == "-nan":
        return String("NaN")
    var sign = UInt64(1) << UInt64(width - 1)
    if cell == "inf":
        return float_cell_text(_inf_bits(False, width), width)
    if cell == "-inf":
        return float_cell_text(_inf_bits(True, width), width)
    var dec = parse_decimal(cell)
    if dec.digits.is_zero():
        return float_cell_text(sign if dec.negative else UInt64(0), width)
    # The standard library's parse is a first guess only: the float the
    # decimal rounds to is decided exactly, among the guess's neighbours.
    # (A float32 or float16 guess is the Float64 cast, rounded twice, so it
    # can be a neighbour off next to a midpoint.)
    var guess = _bits_of(atof(_guess_text(cell, dec.exp10)), width)
    var neg_bit = guess & sign
    var mag = Int(guess & ~sign)
    var deltas: List[Int] = [0, -1, 1, -2, 2, -3, 3]
    for delta in deltas:
        var m = mag + delta
        if m < 0:
            continue
        var bits = neg_bit | UInt64(m)
        if float_is_nan(bits, width) or float_is_inf(bits, width):
            continue
        if decimal_rounds_to(dec, bits, width):
            return float_cell_text(bits, width)
    raise Error(
        "'" + cell + "' is not a finite float" + String(width)
    )


def duckdb_tsv_canon(tsv: DuckdbTsv, like: CanonText) raises -> CanonText:
    """`tsv` as canonical text under `like`'s policy and schema (the module
    header says how each cell is read). Raises naming the row and column of
    the first cell it cannot read, or the first name that differs."""
    var res = CanonText(like.policy.copy())
    var ncols = like.num_columns()
    if len(tsv.names) != ncols:
        raise Error(
            "duckdb_tsv: " + String(len(tsv.names)) + " columns, the schema "
            + String(ncols)
        )
    var types = List[String]()
    var nullable = List[Bool]()
    for c in range(ncols):
        if escape_name(tsv.names[c]) != like.names[c]:
            raise Error(
                "duckdb_tsv: column " + String(c + 1) + " is '"
                + escape_name(tsv.names[c]) + "', the schema's '"
                + like.names[c] + "'"
            )
        res.schema.append(like.schema[c])
        res.names.append(like.names[c])
        res.float_widths.append(like.float_widths[c])
        types.append(_type_of(like.schema[c]))
        nullable.append(like.schema[c].endswith("?"))
    for r in range(len(tsv.rows)):
        var row = List[String](capacity=ncols)
        for c in range(ncols):
            ref t = types[c]
            try:
                if not tsv.rows[r][c]:
                    if not nullable[c]:
                        raise Error("NULL in a column that is not nullable")
                    row.append(String("\\N"))
                    continue
                var cell = tsv.rows[r][c].value()
                var bounds = _int_bounds(t)
                if t == "bool":
                    if cell != "true" and cell != "false":
                        raise Error("'" + cell + "' is not true or false")
                    row.append(cell)
                elif bounds[0]:
                    row.append(_int_cell(cell, t, bounds[1], bounds[2]))
                elif _float_width(t) > 0:
                    row.append(_float_cell(cell, _float_width(t)))
                elif t.startswith("decimal128("):
                    var ps = _decimal_params(t)
                    row.append(_decimal_cell(cell, ps[0], ps[1]))
                elif t == "string" or t == "large_string":
                    row.append(escape_string(cell, False))
                elif t == "date32":
                    row.append(_date_cell(cell))
                elif _timestamp_digits(t) >= 0:
                    row.append(_timestamp_cell(cell, _timestamp_digits(t)))
                elif (
                    _list_item_type(t) == "string"
                    or _list_item_type(t) == "large_string"
                ):
                    row.append(_list_cell(cell))
                else:
                    raise Error("this reader does not read type " + t)
            except e:
                raise Error(
                    "duckdb_tsv: row " + String(r + 1) + " column "
                    + like.names[c] + ": " + String(e)
                )
        res.rows.append(row^)
    return res^
