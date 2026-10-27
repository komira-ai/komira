# =============================================================================
# subrg_columns — flat columns built from a sub-row-group cursor's fixed buffer
# =============================================================================
#
# A column cursor fills a worker's fixed buffer with one chunk of a column:
# int32 dictionary codes, or PLAIN little-endian values. These build the
# chunk's flat column from it.
#
# Two families:
#   * the aggregate builders widen for aggregand state: INT32 -> INT64 and
#     FLOAT -> FLOAT64 (`resolve_flat_int64_col`, `resolve_flat_f64_col`,
#     `build_flat_plain_col`);
#   * the scan builders keep the column's own type, as the whole-row-group
#     decode does: INT32 stays INT32 and FLOAT stays FLOAT32
#     (`build_one_scan_col` picks among them). A widened 8-byte buffer under
#     an INT32 schema field would be read at the wrong stride downstream.
#
# Every builder fills all `n_rows` rows: the first `min(n_rows, v_total)`
# from the buffer, the rest (never reached: every caller declines a short
# fill before building) with dictionary entry 0 or 0. That total fill is what
# makes `allocate_uninitialized` sound here: an arm that could leave a gap must
# allocate zeroed. A dictionary code outside the dictionary resolves to entry
# 0 (the cursor already refused a chunk whose codes it could not check).
# =============================================================================

from std.sys import size_of

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.decode_arm_trace import (
    dict_resolve_fused_enabled,
    incr_flat_gather_fused,
    incr_flat_gather_legacy,
)
from komira_parquet.dict_gather_fused import gather_flat_clamped
from komira_parquet_api.types import ParquetType


def _resolve_codes[dt: DType](
    vcodes_buf: OwnedAlignedBuffer, n_rows: Int, v_total: Int, col_dict: List[Scalar[dt]]
) raises -> Column[HeapRegion]:
    """`n_rows` codes of the buffer resolved through `col_dict` (an
    out-of-range code to entry 0), as a `dt` column."""
    var col_dict_size = len(col_dict)
    var arr = PrimitiveArray[dt].allocate_uninitialized(n_rows)
    var vout = arr._typed_ptr_mut()
    var vview = vcodes_buf.view_range_ro(0, n_rows * 4)
    # SAFETY: `vview` covers `n_rows * 4` bytes (the caller filled the fixed
    # buffer with at least `n_rows` codes) and `vout` the `n_rows` slots of
    # `arr`; every index below is in `[0, n_rows)`, and both pointers stay in
    # this function while `vview` and `arr` live.
    var vptr = vview._unsafe_ptr().bitcast[Int32]()
    var rows_val = min(n_rows, v_total)
    for r in range(rows_val):
        var code = Int((vptr + r)[])
        if code < 0 or code >= col_dict_size:
            code = 0
        (vout + r)[] = col_dict[code]
    for r in range(rows_val, n_rows):
        (vout + r)[] = col_dict[0] if col_dict_size > 0 else Scalar[dt](0)
    _ = vview
    return Column.from_primitive_shared[dt](arr^)


def _narrow[src: DType, dst: DType](values: List[Scalar[src]]) -> List[Scalar[dst]]:
    var out = List[Scalar[dst]](capacity=len(values))
    for i in range(len(values)):
        out.append(values[i].cast[dst]())
    return out^


def resolve_flat_int64_col(vcodes_buf: OwnedAlignedBuffer, n_rows: Int, v_total: Int, col_dict: List[Int64]) raises -> Column[HeapRegion]:
    """Codes resolved to an INT64 column. With the fused-resolve gate on
    (`komira_parquet.decode_arm_trace`), the bounds check runs per SIMD block
    (`gather_flat_clamped`), with the same output."""
    if dict_resolve_fused_enabled():
        incr_flat_gather_fused()
        return Column.from_primitive_shared[DType.int64](
            gather_flat_clamped[DType.int64](vcodes_buf, n_rows, min(n_rows, v_total), col_dict)
        )
    incr_flat_gather_legacy()
    return _resolve_codes[DType.int64](vcodes_buf, n_rows, v_total, col_dict)


def resolve_flat_f64_col(vcodes_buf: OwnedAlignedBuffer, n_rows: Int, v_total: Int, col_dict: List[Float64]) raises -> Column[HeapRegion]:
    """Codes resolved to a FLOAT64 column (fused gate as
    `resolve_flat_int64_col`)."""
    if dict_resolve_fused_enabled():
        incr_flat_gather_fused()
        return Column.from_primitive_shared[DType.float64](
            gather_flat_clamped[DType.float64](vcodes_buf, n_rows, min(n_rows, v_total), col_dict)
        )
    incr_flat_gather_legacy()
    return _resolve_codes[DType.float64](vcodes_buf, n_rows, v_total, col_dict)


def _copy_plain[src: DType, dst: DType](vbuf: OwnedAlignedBuffer, n_rows: Int, v_total: Int) raises -> Column[HeapRegion]:
    """`n_rows` PLAIN `src` values of the buffer as a `dst` column (0 past
    `v_total`)."""
    var rows_val = min(n_rows, v_total)
    var arr = PrimitiveArray[dst].allocate_uninitialized(n_rows)
    var out = arr._typed_ptr_mut()
    var vview = vbuf.view_range_ro(0, rows_val * size_of[Scalar[src]]())
    # SAFETY: the cursor filled `rows_val` values of `src` (the view covers
    # exactly them) and `out` holds `n_rows >= rows_val` slots of `arr`; both
    # pointers stay in this function while `vview` and `arr` live.
    var sp = vview._unsafe_ptr().bitcast[Scalar[src]]()
    for r in range(rows_val):
        (out + r)[] = (sp + r)[].cast[dst]()
    for r in range(rows_val, n_rows):
        (out + r)[] = Scalar[dst](0)
    _ = vview
    return Column.from_primitive_shared[dst](arr^)


def build_flat_plain_col(vbuf: OwnedAlignedBuffer, n_rows: Int, v_total: Int, ptype: ParquetType) raises -> Column[HeapRegion]:
    """PLAIN values as an aggregand column: DOUBLE and FLOAT as FLOAT64,
    INT64 and INT32 as INT64."""
    if ptype == ParquetType.DOUBLE:
        return _copy_plain[DType.float64, DType.float64](vbuf, n_rows, v_total)
    if ptype == ParquetType.FLOAT:
        return _copy_plain[DType.float32, DType.float64](vbuf, n_rows, v_total)
    if ptype == ParquetType.INT64:
        return _copy_plain[DType.int64, DType.int64](vbuf, n_rows, v_total)
    return _copy_plain[DType.int32, DType.int64](vbuf, n_rows, v_total)


def build_int32_codes_col(vbuf: OwnedAlignedBuffer, n_rows: Int) raises -> Column[HeapRegion]:
    """The buffer's `n_rows` codes as an INT32 column (the placeholder of a
    dictionary string column)."""
    return _copy_plain[DType.int32, DType.int32](vbuf, n_rows, n_rows)


def build_one_scan_col(
    vbuf: OwnedAlignedBuffer,
    n_rows: Int,
    v_total: Int,
    is_dict: Bool,
    is_float: Bool,
    ptype: ParquetType,
    col_dict_i: List[Int64],
    col_dict_f: List[Float64],
) raises -> Column[HeapRegion]:
    """One scan column of the column's own type: a dictionary chunk's codes
    resolved through its dictionary (the cursor widened the dictionary to
    Int64 / Float64; narrowing back to INT32 / FLOAT32 is exact), a PLAIN
    chunk's values copied."""
    if is_dict:
        if is_float:
            if ptype == ParquetType.FLOAT:
                return _resolve_codes[DType.float32](
                    vbuf, n_rows, v_total, _narrow[DType.float64, DType.float32](col_dict_f)
                )
            return resolve_flat_f64_col(vbuf, n_rows, v_total, col_dict_f)
        if ptype == ParquetType.INT32:
            return _resolve_codes[DType.int32](vbuf, n_rows, v_total, _narrow[DType.int64, DType.int32](col_dict_i))
        return resolve_flat_int64_col(vbuf, n_rows, v_total, col_dict_i)
    if ptype == ParquetType.FLOAT:
        return _copy_plain[DType.float32, DType.float32](vbuf, n_rows, v_total)
    if ptype == ParquetType.INT32:
        return _copy_plain[DType.int32, DType.int32](vbuf, n_rows, v_total)
    return build_flat_plain_col(vbuf, n_rows, v_total, ptype)
