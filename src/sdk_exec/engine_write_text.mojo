# =============================================================================
# engine_write_text -- a query's result as CSV or newline-delimited JSON bytes
# =============================================================================
#
# `COPY ... TO '<file>.csv'` and `COPY ... TO '<file>.json'` write the bytes
# DuckDB's own COPY writes for the same result, so DuckDB reads either file
# back to the same rows and types. `encode_csv` and `encode_ndjson` build the
# file in memory; `compress_text` wraps it for a `.gz` or `.zst` destination;
# `engine_write.write_copy_result` writes it all or nothing.
#
# CSV, in the `csv.csv_write_dialect.CsvWriteDialect` the COPY gives
# (DuckDB's defaults when it gives none: delimiter `,`, quote and escape `"`,
# NULL as nothing, a header row), with `\n` after every line:
#   header     the column names, each written as a cell (below); no header
#              line for HEADER false
#   NULL       the NULL text, as it is (nothing by default)
#   a cell     the text below, quoted by DuckDB's rule (`csv_field_into`):
#              when it equals the NULL text (the empty string, by default) or
#              holds the delimiter, the quote, `\n` or `\r`, with the escape
#              before each quote and escape inside (`"` doubled, by default);
#              never with QUOTE ''. Numbers, dates and timestamps are cells
#              too: `1.5` is quoted with DELIMITER '.'
#   string     as is
#   integer    decimal digits
#   BOOLEAN    true / false
#   DOUBLE     the shortest digits that read back to the value, fixed
#              notation from 1e-4 up to 1e16 (`3.0`, `0.0001`,
#              `1000000000000000.0`) and otherwise `<d>[.<ddd>]e<sign><dd>`
#              (`1e+16`, `1.25e-07`); `nan`, `inf`, `-inf`; `-0.0`
#   FLOAT      the same, with a FLOAT's own shortest digits (`0.1`)
#   DECIMAL    exact, with all of its scale (`12.50`, `-0.05`, `42`)
#   DATE       `YYYY-MM-DD` (four digits at least), a year before 1 as
#              `0044-03-15 (BC)`
#   TIMESTAMP  the DATE text, a space, `HH:MM:SS`, then `.` and the fraction
#              of a second with its trailing zeros removed when it is not
#              zero (`2015-09-04 12:30:45.12`, `1970-01-01 00:00:00`,
#              `0001-12-31 (BC) 00:00:00`), at the column's unit: up to 3
#              digits for TIMESTAMP_MS, 6 for TIMESTAMP_US (and the legacy
#              tag), 9 for TIMESTAMP_NS, none for TIMESTAMP_S; `+00` after
#              it when the field carries a time zone (an instant, DuckDB's
#              TIMESTAMPTZ, shown in UTC); the largest INT64 as `infinity`
#              and its negation as `-infinity`, at every unit and with no
#              `+00`
#   DATEFORMAT a DATE in that format (`csv_temporal_format`)
#   TIMESTAMPFORMAT  a TIMESTAMP or TIMESTAMPTZ (TIMESTAMP_US or the legacy
#              tag) in that format, a zoned one in UTC; DuckDB writes a
#              TIMESTAMP_S or _NS in its own text whatever the format, and
#              so does this writer. `engine_write` refuses a TIMESTAMP_MS
#              (DuckDB reads a Parquet one as a TIMESTAMP, which it formats,
#              and writes a TIMESTAMP_MS in its own text) and a zoned
#              TIMESTAMP_S or _NS.
# A format is parsed only when the result has a column it applies to, as
# DuckDB does, so a format no column uses is never refused.
# An empty result is the header row alone (no byte with HEADER false).
#
# JSON, one object per row, each followed by `\n` (DuckDB's `FORMAT json`,
# `ARRAY false`): `{"<name>":<value>,...}` in column order, NULL as `null`.
#   string     quoted; `"` and `\` escaped, `\b \f \n \r \t` short, other
#              bytes below 0x20 as `\u00XX` (upper-case hex), every other
#              byte as is
#   integer    decimal digits; BOOLEAN true / false
#   DOUBLE     the shortest digits, fixed notation from 1e-6 up to 1e21
#              (`0.000001`, `100000000000000000000.0`), otherwise
#              `<d>[.<ddd>]e[-]<d...>` (`1.25e-7`, `1e300`); `NaN`,
#              `Infinity`, `-Infinity`; `-0.0`
#   FLOAT      widened to DOUBLE first (`0.10000000149011612`), as DuckDB
#   DECIMAL    as the DOUBLE nearest its value (`12.5`, `42.0`), as DuckDB;
#              DECIMAL(38, 0), komira's type for the integer sum() that
#              DuckDB types HUGEINT, as its exact digits (`42`)
#   DATE, TIMESTAMP  a string holding the CSV text
# An empty result is an empty file.
#
# The NULL type is written as NULL in every row. A column of a type not
# listed is refused before encoding by `engine_write`, using
# `text_writable`.

from std.memory import bitcast

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from arrow.write_target import WCOMP_GZIP, WCOMP_ZSTD
from compression.compression_codecs import Gzip
from csv.csv_temporal_format import TemporalFormat
from csv.csv_write_dialect import CsvWriteDialect, csv_field_into
from compression.zstd_frame import (
    ZSTD_DEFAULT_LEVEL,
    zstd_compress_bound,
    zstd_compress_into,
)

comptime _COMMA: UInt8 = 0x2C
comptime _QUOTE: UInt8 = 0x22
comptime _NEWLINE: UInt8 = 0x0A
comptime _RETURN: UInt8 = 0x0D
comptime _BACKSLASH: UInt8 = 0x5C


def text_writable(at: ArrowType) -> Bool:
    """True for a type `encode_csv` and `encode_ndjson` write."""
    return (
        at == ArrowType.NULL
        or at == ArrowType.BOOL
        or at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.UINT8
        or at == ArrowType.UINT16
        or at == ArrowType.UINT32
        or at == ArrowType.UINT64
        or at == ArrowType.FLOAT32
        or at == ArrowType.FLOAT64
        or at == ArrowType.STRING
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.DICTIONARY
        or at == ArrowType.DATE32
        or at == ArrowType.DECIMAL128
        or at.is_timestamp()
    )


# --- cells -------------------------------------------------------------------


struct _Cells(Copyable, Movable):
    """One column's cells, encoded and laid end to end: cell `r` is
    `data[ends[r - 1] : ends[r]]` (from 0 for the first)."""

    var data: List[UInt8]
    var ends: List[Int]

    def __init__(out self, rows: Int):
        self.data = List[UInt8]()
        self.ends = List[Int](capacity=rows)

    def text(mut self, s: String):
        """Append a cell holding the bytes of `s`."""
        self.data.extend(Span(s.as_bytes()))
        self.ends.append(len(self.data))

    def bytes(mut self, var b: List[UInt8]):
        """Append a cell holding `b`."""
        self.data.extend(Span(b))
        self.ends.append(len(self.data))

    def put(mut self, s: String, json: Bool, dialect: CsvWriteDialect):
        """Append a cell holding `s`: as it is for JSON, and for CSV quoted
        and escaped when `dialect` says so (`csv_field_into`)."""
        if json:
            self.data.extend(Span(s.as_bytes()))
        else:
            csv_field_into(self.data, s, dialect)
        self.ends.append(len(self.data))

    def copy_to(self, mut out: List[UInt8], row: Int):
        """Append cell `row` to `out`."""
        var start = 0 if row == 0 else self.ends[row - 1]
        out.extend(Span(self.data)[start : self.ends[row]])


def _pad(n: Int, width: Int) -> String:
    """`n` (not negative) in decimal, zero-padded to `width` digits."""
    var s = String(n)
    while s.byte_length() < width:
        s = "0" + s
    return s^


def _civil_from_days(days: Int) -> Tuple[Int, Int, Int]:
    """(year, month, day) of the proleptic Gregorian date `days` after
    1970-01-01; year 0 is 1 BC."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + 3 if mp < 10 else mp - 9
    var year = yoe + era * 400 + (1 if month <= 2 else 0)
    return (year, month, day)


def date_text(days: Int32) -> String:
    """A DATE as DuckDB renders it: `YYYY-MM-DD`, the year at least four
    digits, and a year before 1 as `<1 - year>-MM-DD (BC)`."""
    return _date_text(Int(days))


def _date_text(days: Int) -> String:
    """`date_text` of a day count past the INT32 range a DATE holds (a
    timestamp's day)."""
    var ymd = _civil_from_days(days)
    var year = ymd[0]
    var bc = year <= 0
    if bc:
        year = 1 - year
    var s = _pad(year, 4) + "-" + _pad(ymd[1], 2) + "-" + _pad(ymd[2], 2)
    if bc:
        s += " (BC)"
    return s^


comptime _SECONDS_PER_DAY = 86_400


def _timestamp_text(value: Int64, at: ArrowType, aware: Bool) -> String:
    """A timestamp of the Arrow type `at` as DuckDB renders it (the module
    header says how); `aware` for a field that carries a time zone."""
    if value == Int64.MAX:
        return "infinity"
    if value == -Int64.MAX:
        return "-infinity"
    var per = 1_000_000
    var digits = 6
    if at == ArrowType.TIMESTAMP_S:
        per = 1
        digits = 0
    elif at == ArrowType.TIMESTAMP_MS:
        per = 1_000
        digits = 3
    elif at == ArrowType.TIMESTAMP_NS:
        per = 1_000_000_000
        digits = 9
    var v = Int(value)
    # Floor division and modulo: a time before 1970 is the day before at a
    # positive time of day.
    var secs = v // per
    var frac = v % per
    var days = secs // _SECONDS_PER_DAY
    var sod = secs % _SECONDS_PER_DAY
    var s = (
        _date_text(days) + " " + _pad(sod // 3600, 2) + ":"
        + _pad((sod // 60) % 60, 2) + ":" + _pad(sod % 60, 2)
    )
    if frac != 0:
        var f = _pad(frac, digits)
        var b = f.as_bytes()
        var end = len(b)
        while b[end - 1] == 0x30:
            end -= 1
        s += "." + String(f[byte = 0:end])
    if aware:
        s += "+00"
    return s^


def decimal_text(value: Scalar[DType.int128], scale: Int) -> String:
    """A DECIMAL's exact text: its digits with a point before the last
    `scale` of them (`12.50`, `-0.05`, `0.00`, `42`)."""
    var neg = value < 0
    var mag = -value if neg else value
    var rev = List[UInt8]()
    while mag > 0:
        var q = mag // 10
        rev.append(UInt8(0x30 + Int((mag - q * 10).cast[DType.int64]())))
        mag = q
    while len(rev) <= scale:
        rev.append(UInt8(0x30))
    var out = List[UInt8]()
    if neg:
        out.append(UInt8(0x2D))
    var n = len(rev)
    for i in range(n):
        if i == n - scale:
            out.append(UInt8(0x2E))
        out.append(rev[n - 1 - i])
    return String(unsafe_from_utf8=out)


# --- doubles -----------------------------------------------------------------


def _bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64, 1](v)


def _is_nan(v: Float64) -> Bool:
    var b = _bits(v)
    return ((b >> 52) & 0x7FF) == 0x7FF and (b & 0xFFFFFFFFFFFFF) != 0


def _is_inf(v: Float64) -> Bool:
    var b = _bits(v)
    return ((b >> 52) & 0x7FF) == 0x7FF and (b & 0xFFFFFFFFFFFFF) == 0


def _sign_bit(v: Float64) -> Bool:
    return (_bits(v) >> 63) == 1


def _zeros(n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += "0"
    return s^


def _exponent(s: String) raises -> Int:
    """The integer `s` (`16`, `+16`, `-07`)."""
    var b = s.as_bytes()
    var i = 0
    var neg = False
    if len(b) > 0 and (b[0] == 0x2B or b[0] == 0x2D):
        neg = b[0] == 0x2D
        i = 1
    var n = 0
    while i < len(b):
        n = n * 10 + Int(b[i] - 0x30)
        i += 1
    return -n if neg else n


struct _Digits(Movable):
    """A finite non-zero magnitude as its shortest significant digits
    `digits` (no leading or trailing zero) and `point`, where the decimal
    point falls: the value is `0.<digits> * 10^point`."""

    var digits: String
    var point: Int

    def __init__(out self, shortest: String) raises:
        """Read the digits out of a stdlib shortest rendering of a positive
        value (`12.5`, `0.0001`, `1e+16`, `1.25e-07`)."""
        var mantissa = shortest
        var exp = 0
        var e = shortest.find("e")
        if e >= 0:
            mantissa = String(shortest[byte = 0:e])
            exp = _exponent(String(shortest[byte = e + 1 :]))
        var dot = mantissa.find(".")
        var ds = mantissa
        var point = mantissa.byte_length()
        if dot >= 0:
            ds = String(mantissa[byte = 0:dot])
            ds += String(mantissa[byte = dot + 1 :])
            point = dot
        var b = ds.as_bytes()
        var first = 0
        while first < len(b) - 1 and b[first] == 0x30:
            first += 1
        var last = len(b)
        while last > first + 1 and b[last - 1] == 0x30:
            last -= 1
        self.digits = String(ds[byte = first:last])
        self.point = point - first + exp


def _fixed(d: _Digits) -> String:
    """`d` in fixed notation, with `.0` when it has no fraction."""
    var n = d.digits.byte_length()
    if d.point <= 0:
        return "0." + _zeros(-d.point) + d.digits
    if d.point >= n:
        return d.digits + _zeros(d.point - n) + ".0"
    return (
        String(d.digits[byte = 0 : d.point]) + "."
        + String(d.digits[byte = d.point :])
    )


def _mantissa(d: _Digits) -> String:
    """`<d>[.<ddd>]`: the first digit, then a point and the rest if any."""
    if d.digits.byte_length() == 1:
        return d.digits
    return String(d.digits[byte = 0:1]) + "." + String(d.digits[byte = 1:])


def csv_double_text[dtype: DType](v: Scalar[dtype]) raises -> String:
    """A DOUBLE or FLOAT as DuckDB's CSV writer renders it (the module
    header says how)."""
    var w = v.cast[DType.float64]()
    if _is_nan(w):
        return "nan"
    if _is_inf(w):
        return String("-inf") if w < 0 else String("inf")
    if w == 0:
        return String("-0.0") if _sign_bit(w) else String("0.0")
    var mag = -v if w < 0 else v
    var d = _Digits(String(mag))
    var sign = String("-") if w < 0 else String("")
    var exp = d.point - 1
    if exp >= -4 and exp < 16:
        return sign + _fixed(d)
    var digits = String(exp if exp >= 0 else -exp)
    if digits.byte_length() < 2:
        digits = "0" + digits
    var e = String("e+") if exp >= 0 else String("e-")
    return sign + _mantissa(d) + e + digits


def json_double_text(v: Float64) raises -> String:
    """A DOUBLE as DuckDB's JSON writer renders it (the module header says
    how)."""
    if _is_nan(v):
        return "NaN"
    if _is_inf(v):
        return String("-Infinity") if v < 0 else String("Infinity")
    if v == 0:
        return String("-0.0") if _sign_bit(v) else String("0.0")
    var d = _Digits(String(-v if v < 0 else v))
    var sign = String("-") if v < 0 else String("")
    if d.point > -6 and d.point <= 21:
        return sign + _fixed(d)
    return sign + _mantissa(d) + "e" + String(d.point - 1)


# --- strings -----------------------------------------------------------------


def _hex_upper(n: UInt8) -> UInt8:
    return UInt8(0x30) + n if n < 10 else UInt8(0x41 - 10) + n


def _json_quoted(s: String) -> List[UInt8]:
    """`s` as a JSON string, escaped as DuckDB escapes it."""
    var src = s.as_bytes()
    var out = List[UInt8](capacity=len(src) + 2)
    out.append(_QUOTE)
    for i in range(len(src)):
        var b = src[i]
        if b == _QUOTE or b == _BACKSLASH:
            out.append(_BACKSLASH)
            out.append(b)
        elif b == 0x08:
            out.append(_BACKSLASH)
            out.append(UInt8(0x62))
        elif b == 0x0C:
            out.append(_BACKSLASH)
            out.append(UInt8(0x66))
        elif b == _NEWLINE:
            out.append(_BACKSLASH)
            out.append(UInt8(0x6E))
        elif b == _RETURN:
            out.append(_BACKSLASH)
            out.append(UInt8(0x72))
        elif b == 0x09:
            out.append(_BACKSLASH)
            out.append(UInt8(0x74))
        elif b < 0x20:
            out.append(_BACKSLASH)
            out.append(UInt8(0x75))
            out.append(UInt8(0x30))
            out.append(UInt8(0x30))
            out.append(_hex_upper(b >> 4))
            out.append(_hex_upper(b & 0x0F))
        else:
            out.append(b)
    out.append(_QUOTE)
    return out^


# --- columns -----------------------------------------------------------------


def _string_cell(
    mut cells: _Cells, s: String, json: Bool, dialect: CsvWriteDialect
):
    if json:
        cells.bytes(_json_quoted(s))
    else:
        cells.put(s, False, dialect)


def _null_text(json: Bool, dialect: CsvWriteDialect) -> String:
    return String("null") if json else dialect.null_text


def _int_cells[
    dtype: DType
](
    batch: RecordBatch,
    c: Int,
    json: Bool,
    dialect: CsvWriteDialect,
    mut cells: _Cells,
) raises:
    var arr = batch.column_at(c).as_primitive[dtype]()
    var null = _null_text(json, dialect)
    for r in range(batch.num_rows()):
        if arr.is_null(r):
            cells.text(null)
        else:
            cells.put(String(arr.get(r)), json, dialect)


def _float_cells[
    dtype: DType
](
    batch: RecordBatch,
    c: Int,
    json: Bool,
    dialect: CsvWriteDialect,
    mut cells: _Cells,
) raises:
    var arr = batch.column_at(c).as_primitive[dtype]()
    var null = _null_text(json, dialect)
    for r in range(batch.num_rows()):
        if arr.is_null(r):
            cells.text(null)
        elif json:
            cells.text(json_double_text(arr.get(r).cast[DType.float64]()))
        else:
            cells.put(csv_double_text[dtype](arr.get(r)), False, dialect)


def formatted_timestamp(at: ArrowType) -> Bool:
    """True for the timestamp types TIMESTAMPFORMAT applies to: DuckDB's
    TIMESTAMP and TIMESTAMPTZ, which hold microseconds (TIMESTAMP_US and the
    legacy tag). DuckDB writes a TIMESTAMP_S or TIMESTAMP_NS in its own text
    whatever the format (`engine_write` refuses a TIMESTAMP_MS)."""
    return at == ArrowType.TIMESTAMP_US or at == ArrowType.TIMESTAMP


def _date_cells(
    batch: RecordBatch,
    c: Int,
    json: Bool,
    dialect: CsvWriteDialect,
    mut cells: _Cells,
) raises:
    var arr = batch.column_at(c).as_primitive[DType.int32]()
    var null = _null_text(json, dialect)
    var fmt = Optional[TemporalFormat]()
    if not json and dialect.date_format:
        fmt = TemporalFormat("DATEFORMAT", dialect.date_format.value())
    for r in range(batch.num_rows()):
        if arr.is_null(r):
            cells.text(null)
        elif json:
            cells.text("\"" + date_text(arr.get(r)) + "\"")
        elif fmt:
            cells.put(fmt.value().date_text(Int(arr.get(r))), False, dialect)
        else:
            cells.put(date_text(arr.get(r)), False, dialect)


def _timestamp_cells(
    batch: RecordBatch,
    c: Int,
    json: Bool,
    dialect: CsvWriteDialect,
    mut cells: _Cells,
) raises:
    var at = batch.schema.field_arrow_type(c)
    var arr = batch.column_at(c).as_primitive[DType.int64]()
    var aware = batch.schema.field_tz(c) != ""
    var null = _null_text(json, dialect)
    var fmt = Optional[TemporalFormat]()
    if not json and dialect.timestamp_format and formatted_timestamp(at):
        fmt = TemporalFormat(
            "TIMESTAMPFORMAT", dialect.timestamp_format.value()
        )
    for r in range(batch.num_rows()):
        if arr.is_null(r):
            cells.text(null)
        elif json:
            cells.text("\"" + _timestamp_text(arr.get(r), at, aware) + "\"")
        elif fmt:
            cells.put(
                fmt.value().timestamp_text(arr.get(r), aware), False, dialect
            )
        else:
            cells.put(_timestamp_text(arr.get(r), at, aware), False, dialect)


def _column_cells(
    batch: RecordBatch, c: Int, json: Bool, dialect: CsvWriteDialect
) raises -> _Cells:
    """Column `c` of `batch` encoded cell by cell, for JSON when `json` and
    for CSV in `dialect` otherwise."""
    var rows = batch.num_rows()
    var cells = _Cells(rows)
    var null = _null_text(json, dialect)
    var at = batch.schema.field_arrow_type(c)
    ref col = batch.column_at(c)
    if at == ArrowType.INT64:
        _int_cells[DType.int64](batch, c, json, dialect, cells)
    elif at == ArrowType.INT32:
        _int_cells[DType.int32](batch, c, json, dialect, cells)
    elif at == ArrowType.INT16:
        _int_cells[DType.int16](batch, c, json, dialect, cells)
    elif at == ArrowType.INT8:
        _int_cells[DType.int8](batch, c, json, dialect, cells)
    elif at == ArrowType.UINT64:
        _int_cells[DType.uint64](batch, c, json, dialect, cells)
    elif at == ArrowType.UINT32:
        _int_cells[DType.uint32](batch, c, json, dialect, cells)
    elif at == ArrowType.UINT16:
        _int_cells[DType.uint16](batch, c, json, dialect, cells)
    elif at == ArrowType.UINT8:
        _int_cells[DType.uint8](batch, c, json, dialect, cells)
    elif at == ArrowType.FLOAT64:
        _float_cells[DType.float64](batch, c, json, dialect, cells)
    elif at == ArrowType.FLOAT32:
        _float_cells[DType.float32](batch, c, json, dialect, cells)
    elif at == ArrowType.BOOL:
        var arr = col.as_boolean()
        for r in range(rows):
            if arr.is_null(r):
                cells.text(null)
            else:
                cells.put(
                    String("true") if arr.get(r) else String("false"),
                    json,
                    dialect,
                )
    elif at == ArrowType.DATE32:
        _date_cells(batch, c, json, dialect, cells)
    elif at.is_timestamp():
        _timestamp_cells(batch, c, json, dialect, cells)
    elif at == ArrowType.DECIMAL128:
        var arr = col.as_decimal128()
        # 10^scale as the double nearest it (exact through 1e22), as
        # DuckDB's table of powers of ten holds it.
        var power = Scalar[DType.int128](1)
        for _ in range(arr.scale):
            power *= 10
        var divisor = power.cast[DType.float64]()
        # DECIMAL(38, 0) is what an integer sum() answers where DuckDB
        # answers HUGEINT, which DuckDB's JSON writer writes as an integer.
        var hugeint = arr.precision == 38 and arr.scale == 0
        for r in range(rows):
            if arr.is_null(r):
                cells.text(null)
            elif json and hugeint:
                cells.text(decimal_text(arr.get_i128(r), 0))
            elif json:
                var v = arr.get_i128(r).cast[DType.float64]() / divisor
                cells.text(json_double_text(v))
            else:
                cells.put(decimal_text(arr.get_i128(r), arr.scale), False, dialect)
    elif at == ArrowType.NULL:
        for _ in range(rows):
            cells.text(null)
    elif col.arrow_type == ArrowType.DICTIONARY:
        # A STRING or DICTIONARY field over dictionary codes: the codes are
        # not offsets, so the values are decoded through the dictionary.
        var arr = batch.column_as_string(c)
        for r in range(rows):
            if arr.is_null(r):
                cells.text(null)
            else:
                _string_cell(cells, arr.get(r), json, dialect)
    else:
        # STRING or LARGE_STRING: each row's bytes, at the column's own
        # offset width.
        for r in range(rows):
            if col.utf8_is_null_at(r):
                cells.text(null)
            else:
                _string_cell(cells, col.utf8_value_at(r), json, dialect)
    return cells^


def _all_cells(
    batch: RecordBatch, json: Bool, dialect: CsvWriteDialect
) raises -> List[_Cells]:
    var out = List[_Cells](capacity=batch.num_columns())
    for c in range(batch.num_columns()):
        out.append(_column_cells(batch, c, json, dialect))
    return out^


# --- files -------------------------------------------------------------------


def encode_csv(
    batch: RecordBatch, dialect: CsvWriteDialect = CsvWriteDialect()
) raises -> List[UInt8]:
    """`batch` as the CSV file DuckDB's COPY writes in `dialect` (DuckDB's
    defaults when it is not given): the header line when the dialect has one,
    then a line per row. Every column's type must be `text_writable`.

    Raises:
        `csv_temporal_format`'s refusal of the dialect's DATEFORMAT when
        `batch` has a DATE column, or of its TIMESTAMPFORMAT when it has a
        column `formatted_timestamp` holds.
    """
    var cols = _all_cells(batch, False, dialect)
    var out = List[UInt8]()
    if dialect.header:
        for c in range(batch.num_columns()):
            if c > 0:
                out.append(dialect.delimiter)
            csv_field_into(out, batch.schema.field_name(c), dialect)
        out.append(_NEWLINE)
    for r in range(batch.num_rows()):
        for c in range(len(cols)):
            if c > 0:
                out.append(dialect.delimiter)
            cols[c].copy_to(out, r)
        out.append(_NEWLINE)
    return out^


def encode_ndjson(batch: RecordBatch) raises -> List[UInt8]:
    """`batch` as the newline-delimited JSON file DuckDB's COPY writes: one
    object per row, keys in column order. Every column's type must be
    `text_writable`."""
    var cols = _all_cells(batch, True, CsvWriteDialect())
    var keys = List[List[UInt8]](capacity=batch.num_columns())
    for c in range(batch.num_columns()):
        var k = _json_quoted(batch.schema.field_name(c))
        k.append(UInt8(0x3A))
        keys.append(k^)
    var out = List[UInt8]()
    for r in range(batch.num_rows()):
        out.append(UInt8(0x7B))
        for c in range(len(cols)):
            if c > 0:
                out.append(_COMMA)
            out.extend(Span(keys[c]))
            cols[c].copy_to(out, r)
        out.append(UInt8(0x7D))
        out.append(_NEWLINE)
    return out^


def compress_text(var bytes: List[UInt8], codec: UInt8) raises -> List[UInt8]:
    """`bytes` as the file a WCOMP_* `codec` makes of them: a gzip member
    (level 6) for WCOMP_GZIP, a zstd frame (level 3) for WCOMP_ZSTD, and
    `bytes` themselves for any other code."""
    if codec == WCOMP_GZIP:
        return Gzip[6].compress_gzip_file(Span(bytes))
    if codec == WCOMP_ZSTD:
        var bound = zstd_compress_bound(len(bytes))
        var out = List[UInt8](capacity=bound)
        out.resize(unsafe_uninit_length=bound)
        var n = zstd_compress_into(Span(out), Span(bytes), ZSTD_DEFAULT_LEVEL)
        out.resize(n, UInt8(0))
        return out^
    return bytes^
