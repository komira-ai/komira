# =============================================================================
# merge_dict_columns -- N-way union of DICTIONARY-typed Columns
# =============================================================================
#
# The N-way variant of the pair-wise DICTIONARY concat in
# `concat_dict._concat_dict_columns`, built from the same helpers: it takes a
# list of DICTIONARY Columns that share one layout (code width, and string vs
# numeric dictionary with one value dtype), unions their dictionaries, remaps
# the codes, and returns a single DICTIONARY Column.
#
# Row `i` of an input is code element `_offset + i`, read at the input's
# `_dict_index_byte_width` (4 or 8), and validity bit `_offset + i`. The
# output starts at `_offset == 0` and keeps the inputs' code width and value
# dtype.
#
# Column is Movable-only (owns AlignedBuffers, Bitmap) so the input container
# is a Slab[Column] the caller fills; the helper borrows it.
#
# Algorithm
# ---------
# * Every dictionary equal to input 0's (`_dicts_identical`: size, value
#   dtype, values bytes AND offsets) -> copy every code window through and
#   keep input 0's dictionary.
# * Otherwise seed a `DictInterner` with input 0's dictionary (`seed_append`,
#   so its codes are copied through unchanged), then `find_or_insert` each
#   later input's entries into a per-input remap table, and remap that
#   input's codes. The code under a NULL slot is never looked up; a non-null
#   code outside its dictionary is refused (`ArrowConcatDictCodeOutOfRange`).
# * Validity is carried per row from each input's window.
#
# Complexity: O(sum(len_i) + sum(dict_size_i)) — one hash probe per dictionary
# entry, amortised.
#
# ⛔ An O(K^2) linear scan is NOT fine on the premise that "K = distinct-values
# total is small … typically << 10^4". Common writers emit a dictionary PER
# ROW GROUP, so K is the column's distinct cardinality across the whole file —
# millions for a free-text column, orders of magnitude past that bound, and the
# resulting Σ k·d² comparisons never finish.
# =============================================================================

from komira_collections.slab import Slab

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.concat_dict import (
    _carry_dict_payload,
    _copy_dict_codes,
    _copy_dict_offsets,
    _dict_code_width,
    _dict_remap_table,
    _dicts_identical,
    _merged_dict_data,
    _merged_dict_offsets,
    _numeric_dict_value_width,
    _refuse_dict_layout_disagreement,
    _remap_dict_codes,
    _require_dict_payload,
    _row_is_null,
    _seed_dict_entries,
)
from komira_arrow.dict_interner import DictInterner, dict_merge_probe_add
from komira_arrow.offset_overflow import check_int32_offsets


def merge_dict_columns(cols: Slab[Column[HeapRegion]]) raises -> Column[HeapRegion]:
    """Union the dictionaries of N DICTIONARY Columns and remap their codes.

    Args:
        cols: N DICTIONARY Columns (Slab because Column is Movable-only).
            Borrowed, not consumed.

    Returns:
        A new DICTIONARY Column with length == sum(col._length for col in
        cols), `_offset == 0`, the inputs' code width and value dtype.

    Raises:
        Error if cols is empty or any input is not DICTIONARY;
        `ArrowConcatDictCodeWidth` / `ArrowConcatLayoutDisagreement` if the
        inputs' code widths or dictionary kinds are not one supported layout;
        `ArrowConcatDictMissingPayload` / `ArrowConcatDictMalformed` if a
        dictionary that must be merged does not hold the entries it claims;
        `ArrowConcatDictCodeOutOfRange` if a non-null code of input 1.. lies
        outside its dictionary.
    """
    comptime site = "merge_dict_columns"
    var n_cols = len(cols)
    if n_cols == 0:
        raise Error("merge_dict_columns: empty input list")
    for ci in range(n_cols):
        if cols[ci].arrow_type != ArrowType.DICTIONARY:
            raise Error(
                "merge_dict_columns: input "
                + String(ci)
                + " is "
                + String(cols[ci].arrow_type)
                + ", expected DICTIONARY"
            )
    ref first = cols[0]
    var w = _dict_code_width(site, 0, first)
    var all_identical = True
    for ci in range(1, n_cols):
        _refuse_dict_layout_disagreement(site, ci, first, cols[ci])
        if all_identical and not _dicts_identical(first, cols[ci]):
            all_identical = False

    var total_rows = 0
    var total_nulls = 0
    for ci in range(n_cols):
        total_rows += cols[ci]._length
        total_nulls += cols[ci]._null_count
    var codes = OwnedAlignedBuffer(max(total_rows * w, 1))
    codes.set_length(Int64(total_rows * w))

    if all_identical:
        var row = 0
        for ci in range(n_cols):
            _copy_dict_codes(codes, row, cols[ci], w)
            row += cols[ci]._length
        var out = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=codes^,
            offsets=_copy_dict_offsets(first),
            validity=_concat_validities(cols, total_rows),
            length=total_rows,
            null_count=total_nulls,
            offset=0,
        )
        _carry_dict_payload(out, first, w)
        return out^

    # ⛔ NOT a linear scan (see the header note): a parquet file can carry a
    # dictionary PER ROW GROUP, so K is the column's distinct cardinality —
    # millions, not 10^4.
    var expected_entries = 0
    for ci in range(n_cols):
        _require_dict_payload(site, ci, cols[ci])
        expected_entries += cols[ci]._dict_size
    var numeric = first.is_numeric_dict()
    var vw = _numeric_dict_value_width(first) if numeric else 0
    var interner = DictInterner(expected_entries=expected_entries)
    _seed_dict_entries(interner, first, vw)
    _copy_dict_codes(codes, 0, first, w)
    var row = first._length
    for ci in range(1, n_cols):
        ref c = cols[ci]
        var remap = _dict_remap_table(interner, c, vw)
        _remap_dict_codes(codes, row, c, remap, site, ci, w)
        row += c._length
    dict_merge_probe_add(interner.probes())

    var merged_size = interner.size()
    # Int32-offset ceiling on the MERGED dictionary values buffer.
    check_int32_offsets(
        "merge_dictionaries(values)", interner.total_bytes(), merged_size
    )

    var out = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=codes^,
        offsets=_merged_dict_offsets(interner, numeric),
        validity=_concat_validities(cols, total_rows),
        length=total_rows,
        null_count=total_nulls,
        offset=0,
    )
    out._set_dict_data_from_oab(_merged_dict_data(interner))
    out._dict_size = merged_size
    out._dict_index_byte_width = w
    out._dict_value_dtype = first._dict_value_dtype
    return out^


def _concat_validities(
    cols: Slab[Column[HeapRegion]], total_rows: Int
) -> Optional[Bitmap[HeapRegion]]:
    """One `total_rows` bitmap: output row `row_ci + i` is NULL iff row `i` of
    input `ci` is (`_row_is_null`, which reads bit `_offset + i`). None when
    no input carries a bitmap or a null — callers treat None as all-valid."""
    var any_nulls = False
    for ci in range(len(cols)):
        if cols[ci]._null_count > 0 or cols[ci]._validity:
            any_nulls = True
            break
    if not any_nulls:
        return None

    var bm = Bitmap.create_all_valid(total_rows)
    var row = 0
    for ci in range(len(cols)):
        ref c = cols[ci]
        if c._validity or c._null_count > 0:
            for i in range(c._length):
                if _row_is_null(c, i):
                    bm.clear(row + i)
        row += c._length
    return bm^
