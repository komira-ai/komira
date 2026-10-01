# =============================================================================
# numeric_dict_lut_scan — Phase 2 of the numeric-dictionary filter LUT
# =============================================================================
#
# `numeric_dict_filter_bool_mask` (compiler_eval_predicate.mojo) answers
# `col OP literal` over a NUMERIC dictionary column in two phases: Phase 1
# compares each DISTINCT dictionary entry once and records a keep bit per CODE;
# Phase 2 scans the N per-row codes against that table and packs one output bit
# per row. Phase 1 is O(dict size). Phase 2 is O(rows), and it is what this
# module is.
#
# ⭐ MEASURED BEFORE BUILDING (`perf record --call-graph lbr`, ClickBench
# cbq07 `WHERE adv_engine_id <> 0 GROUP BY adv_engine_id`):
# `_numeric_dict_filter_dispatch` was 19.32% of
# the cell's cycles, all of it the Phase-2 loop. The loop it replaces called
# `Column.dict_code_at(row)` once per ROW — a method call that re-reads the
# code width and the slice offset and bounds-checks the buffer every time —
# and then indexed a `List[Bool]` (another bounds check) behind a data-
# dependent `code < d and keep[code]` branch. DuckDB's equivalent
# (`DictionaryDecoder::Filter`, v1.5.5) is a flat
# `filter_result[offset]` byte load per row.
#
# THE KERNEL. The keep bits become a BYTE table with ONE SENTINEL entry at
# index `d` that is always 0. Each code is widened to unsigned and clamped with
# `min(code, d)`, so a code outside `[0, d)` — negative, or past the dictionary
# — reads the sentinel and drops the row, exactly as the old `code < d` test
# did (and a negative code, which the old loop would have used as a List
# index, now also drops rather than reading out of bounds). The width
# dispatch is hoisted out of the loop and the 8 rows of each output byte are
# unrolled at compile time, so the inner loop is load, clamp, load, shift, or —
# no branch on the data.
#
# BYTE-IDENTICAL OUTPUT: same bit per row, LSB-first within each byte, the
# same `Bitmap.create(num_rows)` (zero-initialised, so the unwritten padding
# bits of the last byte stay 0), the same non-nullable `BooleanArray`.
#
# Hard-rule audit: the raw pointers below are derived INSIDE `_pack_codes` from
# the column's own code buffer and a local List and never leave it — no
# UnsafePointer appears in any signature. No wildcard origin.
# =============================================================================

from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.io.heap_region import HeapRegion


@always_inline
def _pack_codes[
    code_dtype: DType
](
    col_ptr: Column[HeapRegion],
    lut: List[UInt8],
    num_rows: Int,
    mut bm: Bitmap[HeapRegion],
):
    """Pack one keep bit per row of `col_ptr`'s codes (width `code_dtype`).
    `lut` holds `d + 1` bytes, the last being the 0 sentinel. PRECONDITION
    (checked by the caller): the code buffer covers `_offset + num_rows`
    codes."""
    var d = UInt64(len(lut) - 1)
    # SAFETY: the caller checked `code_view` covers
    # `[0, (_offset + num_rows) * size_of(code_dtype))`; `lut` holds `d + 1`
    # bytes and every index is clamped to `<= d`. Both pointers are derived and
    # dropped inside this function.
    var code_view = col_ptr._data.view_ro()
    var codes = code_view._unsafe_ptr().bitcast[Scalar[code_dtype]]() + col_ptr._offset
    var lp = lut.unsafe_ptr()
    var bm_view = bm.buffer.view_mut()
    var full_bytes = num_rows >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        comptime for bit in range(8):
            # Signed -> Int64 -> UInt64: a negative code becomes huge and
            # clamps to the sentinel.
            var c = UInt64(Int64((codes + base + bit)[]))
            var k = (lp + Int(min(c, d)))[]
            byte_val = byte_val | (k << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)
    var remaining = num_rows & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var c = UInt64(Int64((codes + base + bit)[]))
            var k = (lp + Int(min(c, d)))[]
            byte_val = byte_val | (k << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)


def numeric_dict_codes_to_mask(
    col_ptr: Column[HeapRegion], keep: List[Bool]
) raises -> BooleanArray:
    """Phase 2 of the numeric-dict filter LUT: one output bit per row, set iff
    the row's code `c` satisfies `0 <= c < len(keep)` and `keep[c]`.

    Precondition: `col_ptr.is_numeric_dict` (the dispatcher gates on it)."""
    var num_rows = col_ptr.length()
    var d = len(keep)
    var lut = List[UInt8](capacity=d + 1)
    for c in range(d):
        lut.append(UInt8(1) if keep[c] else UInt8(0))
    lut.append(UInt8(0))  # the sentinel every out-of-range code reads
    var bm = Bitmap.create(num_rows)
    if num_rows == 0:
        return BooleanArray.from_bitmap(bm^)
    var width = col_ptr._dict_index_byte_width
    if width != 4 and width != 8:
        raise Error(
            "numeric-dict LUT: unsupported code width " + String(width)
        )
    var need_bytes = (col_ptr._offset + num_rows) * width
    var code_view = col_ptr._data.view_ro()
    if code_view.len() < need_bytes:
        raise Error(
            "numeric-dict LUT: code buffer holds "
            + String(code_view.len())
            + " bytes, the slice needs "
            + String(need_bytes)
        )
    if width == 8:
        _pack_codes[DType.int64](col_ptr, lut, num_rows, bm)
    else:
        _pack_codes[DType.int32](col_ptr, lut, num_rows, bm)
    return BooleanArray.from_bitmap(bm^)
