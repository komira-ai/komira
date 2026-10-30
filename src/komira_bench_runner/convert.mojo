# The komira engine's result batches as the runner's typed rows (`ResultSet`),
# in the form the comparison against DuckDB reads: the cells that
# `komira_bench_duckdb.DuckDbSession.fetch` makes from DuckDB's JSON output, so
# the two signatures are built from the same kinds of cell.
#
# What DuckDB's JSON prints, and so what a cell is here. DuckDB's shell quotes
# the values of DECIMAL, HUGEINT, UHUGEINT and UBIGINT columns (and of every type
# but BIGINT and DOUBLE); the session reads those quoted values by the column
# types `DESCRIBE` gives, so the cells below are the ones it makes:
#
#   engine column          DuckDB JSON            cell
#   DECIMAL(p, s)          "123.4567" (quoted)    exact decimal, canonical text (any scale, scale 0 included)
#   DOUBLE                 1.5                    real
#   FLOAT                  0.1                    real, from the shortest text of the float (as DuckDB prints it)
#   TINYINT .. BIGINT      7                      integer
#   UTINYINT .. UINTEGER   7                      integer
#   UBIGINT                "7" (quoted)           integer when it fits 63 bits, else exact decimal (scale 0)
#   VARCHAR                "abc" (quoted)         text
#   DATE                   "1994-01-01"           text, `YYYY-MM-DD`
#   NULL (any type)        null                   null
#
# The same columns carry a declared type, in the vocabulary of
# `komira_bench_duckdb.declared_types` (the mapping from Arrow types is the
# table in the README of komira_bench_duckdb): DECIMAL128(p, s) is
# DECIMAL(p,s), INT8 .. INT64 are TINYINT, SMALLINT, INTEGER and BIGINT, UINT8
# .. UINT64 are UTINYINT, USMALLINT, UINTEGER and UBIGINT, FLOAT32 is FLOAT,
# FLOAT64 is DOUBLE, BOOL is BOOLEAN, STRING and LARGE_STRING are VARCHAR and
# DATE32 is DATE. An Arrow type outside that list is `UNMAPPED(arrow type N)`.
# The declared type is not the cell kind: an INT32 and an INT64 column both
# give integer cells and still differ as INTEGER and BIGINT. All batches of a
# result must declare the same types.
#
# A DECIMAL is never divided as a float and never rounded to a double: the
# unscaled integer is written as exact decimal text (`decimal_to_string`) and
# kept as that text, so a sum that differs in its last digit is a different
# answer. A column type this file does not list (a dictionary-encoded string, a
# timestamp, a boolean, a nested type) is an error whose message starts with
# `RESULT_TYPE_UNSUPPORTED`; the arm turns that into a refusal, never into a
# wrong value.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch
from komira_bench_duckdb import Cell, ResultSet, decimal_type, duckdb_declared_type, unmapped_type
from komira_buffer.heap_region import HeapRegion
from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import decimal_to_string

comptime RESULT_TYPE_UNSUPPORTED: String = "RESULT_TYPE_UNSUPPORTED"
"""The start of the message of a result column the conversion does not map."""


def decimal_cell(v: I128, scale: Int) raises -> Cell:
    """The cell for the DECIMAL value `v` with `scale` fractional digits: the
    exact decimal of its text, whatever the scale (DuckDB's JSON quotes every
    DECIMAL, scale 0 included, and the session reads it as this same cell)."""
    return Cell.decimal(decimal_to_string(v, scale))


def date32_text(days: Int) raises -> String:
    """`days` since 1970-01-01 as `YYYY-MM-DD` (proleptic Gregorian, civil
    from days). Raises outside the years 0001 to 9999: DuckDB prints year 0
    and earlier as BC dates and later ones with more digits."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    if y < 1 or y > 9999:
        raise Error(String(RESULT_TYPE_UNSUPPORTED) + ": DATE " + String(days) + " is outside the years 0001 to 9999")
    return _pad(y, 4) + "-" + _pad(m, 2) + "-" + _pad(d, 2)


def _pad(v: Int, width: Int) -> String:
    var s = String(v)
    while s.byte_length() < width:
        s = "0" + s
    return s^


def _append_signed[
    dt: DType
](ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    var arr = col.as_primitive[dt]()
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
        else:
            rows[base + r].append(Cell.integer(arr.get(r).cast[DType.int64]()))


def _append_unsigned_small[
    dt: DType
](ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    """Unsigned integers of at most 32 bits: always inside the signed range."""
    _append_signed[dt](col, rows, base)


def _append_u64(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    var arr = col.as_primitive[DType.uint64]()
    var limit = UInt64(9223372036854775807)
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
            continue
        var v = arr.get(r)
        if v <= limit:
            rows[base + r].append(Cell.integer(Int64(v)))
        else:
            rows[base + r].append(Cell.decimal(String(v)))


def _append_f64(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    var arr = col.as_primitive[DType.float64]()
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
        else:
            rows[base + r].append(Cell.real(arr.get(r)))


def _append_f32(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    """A FLOAT is read from its shortest text, the way DuckDB prints it, not
    widened (0.1f widened is not the double 0.1)."""
    var arr = col.as_primitive[DType.float32]()
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
        else:
            var v = arr.get(r)
            if v != v or v - v != Float32(0):
                rows[base + r].append(Cell.real(Float64(v)))
            else:
                rows[base + r].append(Cell.real(atof(String(v))))


def _append_decimal(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    var arr = col.as_decimal128()
    var scale = col.decimal_scale()
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
        else:
            rows[base + r].append(decimal_cell(arr.get_i128(r), scale))


def _append_date32(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    var arr = col.as_primitive[DType.int32]()
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
        else:
            rows[base + r].append(Cell.text(date32_text(Int(arr.get(r)))))


def _append_text(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    for r in range(col.length()):
        if col.is_null_at(r):
            rows[base + r].append(Cell.null())
        else:
            rows[base + r].append(Cell.text(col.utf8_value_at(r)))


def arrow_declared_type(ref col: Column[HeapRegion]) -> String:
    """The declared type of an Arrow column in the shared vocabulary, or the
    unmapped entry for an Arrow type with no name there."""
    var t = col.arrow_type
    if t == ArrowType.DECIMAL128:
        return decimal_type(col.decimal_precision(), col.decimal_scale())
    var name = String("")
    if t == ArrowType.BOOL:
        name = String("BOOLEAN")
    elif t == ArrowType.INT8:
        name = String("TINYINT")
    elif t == ArrowType.INT16:
        name = String("SMALLINT")
    elif t == ArrowType.INT32:
        name = String("INTEGER")
    elif t == ArrowType.INT64:
        name = String("BIGINT")
    elif t == ArrowType.UINT8:
        name = String("UTINYINT")
    elif t == ArrowType.UINT16:
        name = String("USMALLINT")
    elif t == ArrowType.UINT32:
        name = String("UINTEGER")
    elif t == ArrowType.UINT64:
        name = String("UBIGINT")
    elif t == ArrowType.FLOAT32:
        name = String("FLOAT")
    elif t == ArrowType.FLOAT64:
        name = String("DOUBLE")
    elif t == ArrowType.STRING or t == ArrowType.LARGE_STRING:
        name = String("VARCHAR")
    elif t == ArrowType.DATE32:
        name = String("DATE")
    else:
        return unmapped_type(String("arrow type ") + String(t))
    return duckdb_declared_type(name)


def _append_column(ref col: Column[HeapRegion], mut rows: List[List[Cell]], base: Int) raises:
    var t = col.arrow_type
    if t == ArrowType.DECIMAL128:
        _append_decimal(col, rows, base)
    elif t == ArrowType.FLOAT64:
        _append_f64(col, rows, base)
    elif t == ArrowType.FLOAT32:
        _append_f32(col, rows, base)
    elif t == ArrowType.INT64:
        _append_signed[DType.int64](col, rows, base)
    elif t == ArrowType.INT32:
        _append_signed[DType.int32](col, rows, base)
    elif t == ArrowType.INT16:
        _append_signed[DType.int16](col, rows, base)
    elif t == ArrowType.INT8:
        _append_signed[DType.int8](col, rows, base)
    elif t == ArrowType.UINT32:
        _append_unsigned_small[DType.uint32](col, rows, base)
    elif t == ArrowType.UINT16:
        _append_unsigned_small[DType.uint16](col, rows, base)
    elif t == ArrowType.UINT8:
        _append_unsigned_small[DType.uint8](col, rows, base)
    elif t == ArrowType.UINT64:
        _append_u64(col, rows, base)
    elif t == ArrowType.DATE32:
        _append_date32(col, rows, base)
    elif t == ArrowType.STRING or t == ArrowType.LARGE_STRING:
        _append_text(col, rows, base)
    else:
        raise Error(String(RESULT_TYPE_UNSUPPORTED) + ": arrow type " + String(t))


def result_set_of(batches: List[RecordBatch]) raises -> ResultSet:
    """The rows of `batches` in order, one `Cell` per column, with the first
    batch's column names. No batch is an empty result with no names (as an
    empty DuckDB answer has). Raises (`RESULT_TYPE_UNSUPPORTED...`) on a
    column type the table at the top of this file does not list."""
    var out = ResultSet()
    if len(batches) == 0:
        return out^
    var width = batches[0].num_columns()
    for c in range(width):
        out.names.append(batches[0].schema.field_name(c))
        out.types.append(arrow_declared_type(batches[0].column_at(c)))
    for b in range(len(batches)):
        ref batch = batches[b]
        if batch.num_columns() != width:
            raise Error("result batch " + String(b) + " has " + String(batch.num_columns()) + " columns, the first has " + String(width))
        for c in range(width):
            var declared = arrow_declared_type(batch.column_at(c))
            if declared != out.types[c]:
                raise Error(
                    "result batch " + String(b) + " declares column " + String(c) + " as " + declared
                    + ", the first batch as " + out.types[c]
                )
        var base = len(out.rows)
        var n = batch.num_rows()
        for _ in range(n):
            out.rows.append(List[Cell](capacity=width))
        for c in range(width):
            _append_column(batch.column_at(c), out.rows, base)
    return out^
