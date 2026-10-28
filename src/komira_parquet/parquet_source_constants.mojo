# =============================================================================
# parquet_source_constants — columns a file does not hold, made to measure
# =============================================================================
#
# A scan over many files reads each by column NAME into one result schema.
# Two kinds of result column come from no column chunk:
#
#   * a column absent from this file (`_build_typed_all_null_column`): a
#     column of the result's declared type, every row null;
#   * a Hive partition column (`_build_constant_column`): its value is in
#     the file's path (`dt=2026-10-11/f.parquet`) and every row of the file
#     holds it, cast to the declared type. The value arrives as canonical
#     text: STRING / BINARY as is, integers as signed decimal digits,
#     DATE32 as YYYY-MM-DD, TIMESTAMP* as YYYY-MM-DD HH:MM:SS (scaled to the
#     unit; TIMESTAMP without a unit is microseconds), floats as decimal
#     text. The empty string is the NULL partition and gives an all-null
#     column. Text that is not a value of the declared type raises, naming
#     the column, the value and the file.
# =============================================================================

from std.memory import bitcast
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_plan_expr.col_expr import date_to_days


def _build_typed_all_null_column(
    arrow_type: ArrowType, n_rows: Int
) raises -> Column[HeapRegion]:
    """`n_rows` nulls typed `arrow_type` (zeroed data, every validity bit
    clear).

    Raises:
        Error for a type other than the fixed-width numerics and
        temporals, BOOL, STRING and BINARY.
    """
    if arrow_type == ArrowType.INT8 or arrow_type == ArrowType.UINT8:
        return _typed_null_prim[DType.int8](arrow_type, n_rows)
    elif arrow_type == ArrowType.INT16 or arrow_type == ArrowType.UINT16:
        return _typed_null_prim[DType.int16](arrow_type, n_rows)
    elif (
        arrow_type == ArrowType.INT32
        or arrow_type == ArrowType.UINT32
        or arrow_type == ArrowType.DATE32
        or arrow_type == ArrowType.TIME32_S
        or arrow_type == ArrowType.TIME32_MS
    ):
        return _typed_null_prim[DType.int32](arrow_type, n_rows)
    elif (
        arrow_type == ArrowType.INT64
        or arrow_type == ArrowType.UINT64
        or arrow_type == ArrowType.DATE64
        or arrow_type == ArrowType.TIME64_US
        or arrow_type == ArrowType.TIME64_NS
        or arrow_type == ArrowType.TIMESTAMP
        or arrow_type == ArrowType.TIMESTAMP_S
        or arrow_type == ArrowType.TIMESTAMP_MS
        or arrow_type == ArrowType.TIMESTAMP_US
        or arrow_type == ArrowType.TIMESTAMP_NS
    ):
        return _typed_null_prim[DType.int64](arrow_type, n_rows)
    elif arrow_type == ArrowType.FLOAT32:
        return _typed_null_prim[DType.float32](arrow_type, n_rows)
    elif arrow_type == ArrowType.FLOAT64:
        return _typed_null_prim[DType.float64](arrow_type, n_rows)
    elif arrow_type == ArrowType.BOOL:
        var bytes = (n_rows + 7) // 8
        var data = OwnedAlignedBuffer(max(bytes, 1))
        data.zero()
        data.set_length(Int64(bytes))
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data^,
            offsets=None,
            validity=Bitmap.create(n_rows),
            length=n_rows,
            null_count=n_rows,
            offset=0,
        )
    elif arrow_type == ArrowType.STRING or arrow_type == ArrowType.BINARY:
        var offsets = OwnedAlignedBuffer((n_rows + 1) * 4)
        offsets.zero()
        offsets.set_length(Int64((n_rows + 1) * 4))
        var data = OwnedAlignedBuffer(1)
        data.set_length(0)
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data^,
            offsets=offsets^,
            validity=Bitmap.create(n_rows),
            length=n_rows,
            null_count=n_rows,
            offset=0,
        )
    raise Error(
        "all-null column: no null column is built for result type "
        + String(arrow_type)
    )


def _typed_null_prim[
    dtype: DType
](arrow_type: ArrowType, n_rows: Int) raises -> Column[HeapRegion]:
    comptime elem_size = size_of[Scalar[dtype]]()
    var data = OwnedAlignedBuffer(max(n_rows, 1) * elem_size)
    data.zero()
    data.set_length(Int64(n_rows * elem_size))
    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=None,
        validity=Bitmap.create(n_rows),
        length=n_rows,
        null_count=n_rows,
        offset=0,
    )


def _build_constant_column(
    arrow_type: ArrowType,
    value: String,
    n_rows: Int,
    col_name: String,
    file_path: String,
) raises -> Column[HeapRegion]:
    """`n_rows` copies of partition value `value` (canonical text) as
    `arrow_type`; all null for the empty string. `col_name` and
    `file_path` name the source in an error.

    Raises:
        Error if `value` is not a value of `arrow_type`, or the type is not
        STRING, BINARY, INT32/64, UINT32/64, DATE32, TIMESTAMP*, FLOAT32/64.
    """
    if value.byte_length() == 0:
        return _build_typed_all_null_column(arrow_type, n_rows)
    if arrow_type == ArrowType.STRING or arrow_type == ArrowType.BINARY:
        return _constant_varlen_column(arrow_type, value, n_rows)
    elif arrow_type == ArrowType.INT64 or arrow_type == ArrowType.UINT64:
        return _constant_prim_column[DType.int64](
            arrow_type, _parse_signed_int(value, col_name, file_path, arrow_type), n_rows
        )
    elif arrow_type == ArrowType.INT32 or arrow_type == ArrowType.UINT32:
        var v = _parse_signed_int(value, col_name, file_path, arrow_type)
        var lo = 0 if arrow_type == ArrowType.UINT32 else -(1 << 31)
        var hi = (1 << 32) - 1 if arrow_type == ArrowType.UINT32 else (1 << 31) - 1
        if v < lo or v > hi:
            raise _partition_cast_error(col_name, value, file_path, arrow_type)
        return _constant_prim_column[DType.int32](arrow_type, v, n_rows)
    elif arrow_type == ArrowType.DATE32:
        return _constant_prim_column[DType.int32](
            arrow_type, _parse_date32_days(value, col_name, file_path), n_rows
        )
    elif (
        arrow_type == ArrowType.TIMESTAMP
        or arrow_type == ArrowType.TIMESTAMP_S
        or arrow_type == ArrowType.TIMESTAMP_MS
        or arrow_type == ArrowType.TIMESTAMP_US
        or arrow_type == ArrowType.TIMESTAMP_NS
    ):
        return _constant_prim_column[DType.int64](
            arrow_type,
            _parse_timestamp_ticks(value, arrow_type, col_name, file_path),
            n_rows,
        )
    elif arrow_type == ArrowType.FLOAT64:
        var f = _parse_float(value, col_name, file_path)
        return _constant_prim_column[DType.float64](
            arrow_type, Int(bitcast[DType.int64](f)), n_rows
        )
    elif arrow_type == ArrowType.FLOAT32:
        var f = Float32(_parse_float(value, col_name, file_path))
        return _constant_prim_column[DType.float32](
            arrow_type, Int(bitcast[DType.int32](f)), n_rows
        )
    raise Error(
        "partition column '"
        + col_name
        + "' in file '"
        + file_path
        + "': no constant column is built for declared type "
        + String(arrow_type)
        + " (STRING/BINARY, INT32/64, UINT32/64, DATE32, TIMESTAMP*,"
        " FLOAT32/64)"
    )


def _bits_to_scalar[dtype: DType](raw_bits: Int) -> Scalar[dtype]:
    """`raw_bits` as a `dtype` value: narrowed for an integer, the IEEE
    bit pattern for a float."""
    comptime if dtype == DType.float64:
        return rebind[Scalar[dtype]](bitcast[DType.float64](Int64(raw_bits)))
    elif dtype == DType.float32:
        return rebind[Scalar[dtype]](bitcast[DType.float32](Int32(raw_bits)))
    else:
        return Scalar[dtype](raw_bits)


def _constant_prim_column[
    dtype: DType
](arrow_type: ArrowType, raw_bits: Int, n_rows: Int) raises -> Column[HeapRegion]:
    comptime elem_size = size_of[Scalar[dtype]]()
    var data = OwnedAlignedBuffer(max(n_rows, 1) * elem_size)
    data.set_length(Int64(n_rows * elem_size))
    var v = _bits_to_scalar[dtype](raw_bits)
    for i in range(n_rows):
        data.set_typed[Scalar[dtype]](i, v)
    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=None,
        validity=Bitmap.create_all_valid(n_rows),
        length=n_rows,
        null_count=0,
        offset=0,
    )


def _constant_varlen_column(
    arrow_type: ArrowType, value: String, n_rows: Int
) raises -> Column[HeapRegion]:
    var vbytes = value.as_bytes()
    var vlen = len(vbytes)
    var offsets = OwnedAlignedBuffer((n_rows + 1) * 4)
    offsets.set_length(Int64((n_rows + 1) * 4))
    for i in range(n_rows + 1):
        offsets.set_typed[Int32](i, Int32(i * vlen))
    var data = OwnedAlignedBuffer(max(n_rows * vlen, 1))
    data.set_length(Int64(n_rows * vlen))
    for i in range(n_rows):
        for b in range(vlen):
            data.write_u8_at(i * vlen + b, vbytes[b])
    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=offsets^,
        validity=Bitmap.create_all_valid(n_rows),
        length=n_rows,
        null_count=0,
        offset=0,
    )


def _parse_signed_int(
    value: String, col_name: String, file_path: String, arrow_type: ArrowType
) raises -> Int:
    """Signed decimal digits (an optional sign, then 1 to 18 digits)."""
    var bs = value.as_bytes()
    var neg = False
    var start = 0
    if len(bs) > 0 and (bs[0] == UInt8(ord("-")) or bs[0] == UInt8(ord("+"))):
        neg = bs[0] == UInt8(ord("-"))
        start = 1
    # 18 digits always fit an Int64; a longer value is refused rather than
    # wrapped.
    if start >= len(bs) or len(bs) - start > 18:
        raise _partition_cast_error(col_name, value, file_path, arrow_type)
    var acc = 0
    for i in range(start, len(bs)):
        var b = bs[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            raise _partition_cast_error(col_name, value, file_path, arrow_type)
        acc = acc * 10 + (Int(b) - ord("0"))
    return -acc if neg else acc


def _parse_float(value: String, col_name: String, file_path: String) raises -> Float64:
    try:
        return atof(value)
    except:
        raise _partition_cast_error(col_name, value, file_path, ArrowType.FLOAT64)


def _parse_date32_days(value: String, col_name: String, file_path: String) raises -> Int:
    """YYYY-MM-DD (exactly) as days since 1970-01-01."""
    var bs = value.as_bytes()
    var ymd = _split_ymd_at(bs, 0)
    if ymd[0] < 0 or len(bs) != 10:
        raise _partition_cast_error(col_name, value, file_path, ArrowType.DATE32)
    return date_to_days(ymd[0], ymd[1], ymd[2])


def _parse_timestamp_ticks(
    value: String, arrow_type: ArrowType, col_name: String, file_path: String
) raises -> Int:
    """YYYY-MM-DD HH:MM:SS (exactly) as ticks of `arrow_type`'s unit."""
    var bs = value.as_bytes()
    if len(bs) != 19 or bs[10] != UInt8(ord(" ")):
        raise _partition_cast_error(col_name, value, file_path, arrow_type)
    var ymd = _split_ymd_at(bs, 0)
    var hh = _two_digit(bs, 11)
    var mm = _two_digit(bs, 14)
    var ss = _two_digit(bs, 17)
    if (
        ymd[0] < 0
        or bs[13] != UInt8(ord(":"))
        or bs[16] != UInt8(ord(":"))
        or hh < 0
        or hh > 23
        or mm < 0
        or mm > 59
        or ss < 0
        or ss > 59
    ):
        raise _partition_cast_error(col_name, value, file_path, arrow_type)
    var secs = date_to_days(ymd[0], ymd[1], ymd[2]) * 86400 + hh * 3600 + mm * 60 + ss
    if arrow_type == ArrowType.TIMESTAMP_S:
        return secs
    elif arrow_type == ArrowType.TIMESTAMP_MS:
        return secs * 1_000
    elif arrow_type == ArrowType.TIMESTAMP_NS:
        return secs * 1_000_000_000
    return secs * 1_000_000


def _days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        var leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
        return 29 if leap else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _split_ymd_at(bs: Span[UInt8, _], off: Int) -> Tuple[Int, Int, Int]:
    """YYYY-MM-DD at `off` as (year, month, day), or (-1, -1, -1) when it
    is not a calendar date."""
    if off + 10 > len(bs):
        return (-1, -1, -1)
    if bs[off + 4] != UInt8(ord("-")) or bs[off + 7] != UInt8(ord("-")):
        return (-1, -1, -1)
    var y = _four_digit(bs, off)
    var mo = _two_digit(bs, off + 5)
    var d = _two_digit(bs, off + 8)
    if y < 0 or mo < 1 or mo > 12 or d < 1 or d > _days_in_month(y, mo):
        return (-1, -1, -1)
    return (y, mo, d)


def _four_digit(bs: Span[UInt8, _], off: Int) -> Int:
    if off + 4 > len(bs):
        return -1
    var acc = 0
    for i in range(off, off + 4):
        var b = bs[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return -1
        acc = acc * 10 + (Int(b) - ord("0"))
    return acc


def _two_digit(bs: Span[UInt8, _], off: Int) -> Int:
    if off + 2 > len(bs):
        return -1
    var b0 = bs[off]
    var b1 = bs[off + 1]
    if (
        b0 < UInt8(ord("0"))
        or b0 > UInt8(ord("9"))
        or b1 < UInt8(ord("0"))
        or b1 > UInt8(ord("9"))
    ):
        return -1
    return (Int(b0) - ord("0")) * 10 + (Int(b1) - ord("0"))


def _partition_cast_error(
    col_name: String, value: String, file_path: String, arrow_type: ArrowType
) -> Error:
    return Error(
        "partition column '"
        + col_name
        + "': value '"
        + value
        + "' from file '"
        + file_path
        + "' is not a valid "
        + String(arrow_type)
    )
