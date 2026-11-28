# =============================================================================
# temporal_names: the calendar name of a date or a timestamp
# =============================================================================
#
# DuckDB's `dayname(x)` and `monthname(x)` (EXTRACT_DAYNAME and
# EXTRACT_MONTHNAME): a DATE or TIMESTAMP in, the English name of its weekday
# ('Sunday' .. 'Saturday') or month ('January' .. 'December') out, whatever the
# locale (https://duckdb.org/docs/stable/sql/functions/date). The names are
# read off the integer kernels `dayofweek` (Sunday = 0) and `month` (1..12)
# already compute, so a name and its number never disagree: the day of a
# timestamp is the floor of its ticks over a day, so a time part (and a tick
# count before 1970) names the day of its date. NULL in is NULL out: the
# kernels carry the validity of their input and this module keeps it.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from kernels.temporal_extract import (
    extract_day_index_date32,
    extract_day_index_ts,
    extract_month_date32,
    extract_month_ts,
)
from plan_expr.expr import EXTRACT_DAYNAME, EXTRACT_DAYOFWEEK, EXTRACT_MONTHNAME


def _day_names() -> List[String]:
    """The English weekday names, indexed by `dayofweek` (Sunday = 0)."""
    return List[String](
        [
            "Sunday",
            "Monday",
            "Tuesday",
            "Wednesday",
            "Thursday",
            "Friday",
            "Saturday",
        ]
    )


def _month_names() -> List[String]:
    """The English month names, indexed by `month - 1` (January = 0)."""
    return List[String](
        [
            "January",
            "February",
            "March",
            "April",
            "May",
            "June",
            "July",
            "August",
            "September",
            "October",
            "November",
            "December",
        ]
    )


def _names_of(
    idx: PrimitiveArray[DType.int64], unit: UInt8
) raises -> Column[HeapRegion]:
    """A STRING column of the name of each index of `idx` (a weekday number
    for EXTRACT_DAYNAME, a month number for EXTRACT_MONTHNAME), NULL where
    `idx` is NULL."""
    # The kernels answer `dayofweek` in 0..6 and `month` in 1..12 for every
    # value, so `first` shifts the index onto the table.
    var names = _day_names() if unit == EXTRACT_DAYNAME else _month_names()
    var first = 0 if unit == EXTRACT_DAYNAME else 1
    var n = idx.length
    var values = List[String](capacity=n)
    var valid = List[Bool](capacity=n)
    for i in range(n):
        if idx.is_null(i):
            values.append(String(""))
            valid.append(False)
            continue
        values.append(names[Int(idx.get(i)) - first])
        valid.append(True)
    var sa = StringArray.from_strings_with_validity(
        values, valid, "temporal_names._names_of"
    )
    return Column.from_string(sa^)


def calendar_name_column(
    child_col: Column[HeapRegion], src_at: ArrowType, unit: UInt8
) raises -> Column[HeapRegion]:
    """`dayname` / `monthname` of `child_col`, a DATE32 column or a
    TIMESTAMP_* one whose unit is `src_at`: a STRING column of English names,
    NULL where the value is NULL.

    Raises when `unit` is neither EXTRACT_DAYNAME nor EXTRACT_MONTHNAME."""
    if unit != EXTRACT_DAYNAME and unit != EXTRACT_MONTHNAME:
        raise Error(
            "PipelineCompiler: EXPR_EXTRACT unit "
            + String(Int(unit))
            + " is not a calendar name unit"
        )
    var idx: PrimitiveArray[DType.int64]
    if src_at == ArrowType.DATE32:
        var arr32 = child_col.as_primitive[DType.int32]()
        if unit == EXTRACT_DAYNAME:
            idx = extract_day_index_date32(arr32, EXTRACT_DAYOFWEEK)
        else:
            idx = extract_month_date32(arr32)
    else:
        # ⚠ `src_at`, NOT A CONSTANT: the kernels floor-divide the ticks by
        # THIS unit's ticks per day, so a millisecond column names the right
        # day too.
        var arr64 = child_col.as_primitive[DType.int64]()
        if unit == EXTRACT_DAYNAME:
            idx = extract_day_index_ts(arr64, src_at, EXTRACT_DAYOFWEEK)
        else:
            idx = extract_month_ts(arr64, src_at)
    return _names_of(idx, unit)
