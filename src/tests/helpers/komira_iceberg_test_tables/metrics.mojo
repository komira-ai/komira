# =============================================================================
# metrics.mojo -- per-column counts and bounds of a file's rows, and the
# single-value serialization Iceberg stores a bound in (table spec, Appendix D).
# =============================================================================
#
#   boolean  1 byte, 0 or 1
#   int      4 bytes, little-endian two's complement
#   date     the int, days since the Unix epoch
#   long     8 bytes, little-endian two's complement
#   double   8 bytes, little-endian IEEE-754 binary64
#   string   the UTF-8 bytes, no length
#
# A null is no bound and a NaN is no bound; a column whose every value is null
# (or NaN) has no bounds. Strings compare as unsigned bytes. Bounds are exact
# (never truncated).
# =============================================================================

from std.memory import bitcast

from .table_model import (
    ColumnMetrics,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    TableCell,
    TableColumn,
    TableRow,
    null_cell,
)


def _le_bytes(bits: UInt64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(width):
        out.append(UInt8((bits >> UInt64(8 * k)) & UInt64(0xFF)))
    return out^


def single_value_bytes(type_tag: Int, cell: TableCell) -> List[UInt8]:
    """The serialization of a non-null `cell` of a column of `type_tag`."""
    if type_tag == TT_LONG:
        return _le_bytes(bitcast[DType.uint64, 1](cell.i), 8)
    if type_tag == TT_INT or type_tag == TT_DATE:
        return _le_bytes(UInt64(bitcast[DType.uint32, 1](Int32(cell.i))), 4)
    if type_tag == TT_DOUBLE:
        return _le_bytes(bitcast[DType.uint64, 1](cell.f), 8)
    if type_tag == TT_STRING:
        var out = List[UInt8]()
        var bytes = cell.s.as_bytes()
        for k in range(len(bytes)):
            out.append(bytes[k])
        return out^
    var flag = List[UInt8]()
    flag.append(UInt8(1) if cell.i != 0 else UInt8(0))
    return flag^


def bytes_less(a: String, b: String) -> Bool:
    """Whether `a` sorts before `b` as unsigned bytes."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = len(x) if len(x) < len(y) else len(y)
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def _less(type_tag: Int, a: TableCell, b: TableCell) -> Bool:
    """Whether `a` is lower than `b`; both are non-null and, for a double, not NaN."""
    if type_tag == TT_DOUBLE:
        return a.f < b.f
    if type_tag == TT_STRING:
        return bytes_less(a.s, b.s)
    return a.i < b.i


def column_metrics(
    column: TableColumn, rows: List[TableRow], index: Int
) -> ColumnMetrics:
    """The metrics of column number `index` over `rows`."""
    var nulls = Int64(0)
    var nans = Int64(0)
    var have = False
    var lowest = null_cell()
    var highest = null_cell()
    for r in range(len(rows)):
        ref cell = rows[r].cells[index]
        if cell.is_null:
            nulls += 1
            continue
        if column.type_tag == TT_DOUBLE and cell.f != cell.f:
            nans += 1
            continue
        if not have:
            lowest = cell.copy()
            highest = cell.copy()
            have = True
            continue
        if _less(column.type_tag, cell, lowest):
            lowest = cell.copy()
        if _less(column.type_tag, highest, cell):
            highest = cell.copy()
    var lower = List[UInt8]()
    var upper = List[UInt8]()
    if have:
        lower = single_value_bytes(column.type_tag, lowest)
        upper = single_value_bytes(column.type_tag, highest)
    return ColumnMetrics(
        column.id,
        Int64(len(rows)),
        nulls,
        nans if column.type_tag == TT_DOUBLE else Int64(-1),
        have,
        lower^,
        upper^,
    )


def file_metrics(columns: List[TableColumn], rows: List[TableRow]) -> List[ColumnMetrics]:
    """The metrics of every column of `rows`, in column order."""
    var out = List[ColumnMetrics]()
    for c in range(len(columns)):
        out.append(column_metrics(columns[c], rows, c))
    return out^
