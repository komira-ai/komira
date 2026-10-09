# =============================================================================
# DICTIONARY concat — the pair-wise kernel and the helpers the N-way arm shares
# =============================================================================
#
# A DICTIONARY Column is one tag over two layouts (see `Column.is_numeric_dict`):
#   * string dictionary: `_offsets` (Int32, `_dict_size + 1` entries) over the
#     packed bytes in `_dict_data`; `_dict_value_dtype == DTYPE_NONE`.
#   * numeric dictionary: no `_offsets`; `_dict_data` is a flat buffer of
#     `_dict_size` values of `_dict_value_dtype`.
# In both, the per-row codes live in `_data`, `_dict_index_byte_width` (4 or 8)
# bytes each, and row `i` of the column is code element `_offset + i` and
# validity bit `_offset + i`.
#
# Every kernel here reads the codes of an input from element `_offset`, at the
# input's own code width, and emits the codes at that width. Inputs whose code
# width or dictionary layout disagree are refused (the same rule
# `_refuse_concat_layout_disagreement` applies to offset widths): reading one
# input's codes at another's width is a wrong answer under a correct row count.
# =============================================================================

from std.sys import size_of

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.dict_interner import DictInterner, dict_merge_probe_add
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_arrow.offset_overflow import check_int32_offsets
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer


def _dict_code_width(
    site: StaticString, which: Int, col: Column[HeapRegion]
) raises -> Int:
    """The code width of DICTIONARY input `which`, refusing any width a Column
    does not carry. 1- and 2-byte codes are not a Column layout (the IPC
    encoder and the selection-column builder accept 4 and 8 only); read at 4
    bytes they would be a silent wrong answer."""
    var w = col._dict_index_byte_width
    if w != 4 and w != 8:
        raise Error(
            String("ArrowConcatDictCodeWidth: ")
            + String(site)
            + ": input "
            + String(which)
            + " carries "
            + String(w)
            + "-byte dictionary codes; a Column's codes are 4 (Int32) or 8"
            " (Int64) bytes wide"
        )
    return w


def _refuse_dict_layout_disagreement(
    site: StaticString,
    which: Int,
    first: Column[HeapRegion],
    other: Column[HeapRegion],
) raises:
    """Raise unless DICTIONARY inputs `0` and `which` share one layout: the same
    code width, and the same dictionary kind (string vs numeric, and for a
    numeric dictionary the same value dtype)."""
    var wf = _dict_code_width(site, 0, first)
    var wo = _dict_code_width(site, which, other)
    if wf != wo:
        raise Error(
            String("ArrowConcatLayoutDisagreement: ")
            + String(site)
            + ": input 0 carries "
            + String(wf)
            + "-byte dictionary codes but input "
            + String(which)
            + " carries "
            + String(wo)
            + "-byte codes. Index width is a schema property"
            " (Field.dictionary's index type); bring the inputs to one"
            " type before concatenating them"
        )
    if first._dict_value_dtype != other._dict_value_dtype:
        raise Error(
            String("ArrowConcatLayoutDisagreement: ")
            + String(site)
            + ": input 0's dictionary values are "
            + String(first._dict_value_dtype)
            + " but input "
            + String(which)
            + "'s are "
            + String(other._dict_value_dtype)
            + " (a string dictionary reports "
            + String(DTYPE_NONE)
            + ")"
        )


def _dict_data_len(col: Column[HeapRegion]) -> Int:
    """Bytes in `col`'s dictionary values buffer; an absent buffer is 0 (Arrow
    lets a zero-length buffer be omitted)."""
    if col._dict_data:
        return col._dict_data.value().len()
    return 0


def _require_dict_payload(
    site: StaticString, which: Int, col: Column[HeapRegion]
) raises:
    """Refuse a dictionary that claims entries it does not carry.

    A string dictionary whose entries are all empty (its offsets span zero
    bytes) may omit its values buffer: that is a zero-length buffer, legal
    in Arrow, and reads as empty strings."""
    if col._dict_size <= 0:
        return
    var missing = String()
    if col.is_numeric_dict():
        if not col._dict_data:
            missing = "values buffer"
    elif not col._offsets:
        missing = "offsets buffer"
    elif not col._dict_data:
        ref offs = col._offsets.value()
        var span = Int(offs.get_typed[Int32](col._dict_size)) - Int(
            offs.get_typed[Int32](0)
        )
        if span != 0:
            missing = "values buffer"
    if missing.byte_length() > 0:
        raise Error(
            String("ArrowConcatDictMissingPayload: ")
            + String(site)
            + ": input "
            + String(which)
            + " claims "
            + String(col._dict_size)
            + " dictionary entries but carries no dictionary "
            + missing
        )


def _buffers_equal(
    x: SharedAlignedBuffer[HeapRegion],
    y: SharedAlignedBuffer[HeapRegion],
    nbytes: Int,
) -> Bool:
    """True iff the first `nbytes` bytes of `x` and `y` agree (both must hold
    at least that many)."""
    if x.len() < nbytes or y.len() < nbytes:
        return False
    for i in range(nbytes):
        if x.read_u8_at(i) != y.read_u8_at(i):
            return False
    return True


def _dicts_identical(a: Column[HeapRegion], b: Column[HeapRegion]) -> Bool:
    """True iff `a` and `b` carry the same dictionary, so `b`'s codes mean in
    `a`'s dictionary exactly what they mean in their own.

    ⚠ THE OFFSETS ARE PART OF A STRING DICTIONARY. ["a", "b"] and ["ab", ""]
    have the same size and the same bytes ("ab") and are different
    dictionaries; comparing only the bytes would decode `b`'s codes through
    `a`'s entries. A false "different" only costs the remap path; a false
    "identical" is a wrong answer, so every doubt answers False."""
    if a._dict_size != b._dict_size:
        return False
    if a._dict_value_dtype != b._dict_value_dtype:
        return False
    # An absent values buffer is a zero-length one: [""] with its empty
    # buffer omitted is the same dictionary as [""] with it, and NOT the same
    # as ["x"].
    var dlen = _dict_data_len(a)
    if dlen != _dict_data_len(b):
        return False
    if dlen > 0 and not _buffers_equal(
        a._dict_data.value(), b._dict_data.value(), dlen
    ):
        return False
    if Bool(a._offsets) != Bool(b._offsets):
        return False
    if a._offsets:
        var obytes = (a._dict_size + 1) * size_of[Int32]()
        if not _buffers_equal(a._offsets.value(), b._offsets.value(), obytes):
            return False
    return True


@always_inline
def _row_is_null(col: Column[HeapRegion], i: Int) -> Bool:
    """Row `i` of `col` (relative to its `_offset`) is NULL. A bitmap-less
    column with a positive null count is the degenerate "leading rows" shape
    `_merge_validity` also honours."""
    if col._validity:
        return not col._validity.value().test(col._offset + i)
    return i < col._null_count


def _copy_dict_codes(
    mut dst: OwnedAlignedBuffer, dst_row: Int, col: Column[HeapRegion], w: Int
):
    """Copy `col`'s codes for its rows [0, _length) — code elements
    [_offset, _offset + _length) — into `dst` at row `dst_row`, width `w`."""
    var nb = col._length * w
    if nb > 0:
        dst.view_range_mut(dst_row * w, nb).copy_from_view_at(
            0, col._data.view_range_ro(col._offset * w, nb)
        )


def _copy_dict_offsets(src: Column[HeapRegion]) -> Optional[OwnedAlignedBuffer]:
    """A copy of `src`'s string-dictionary offsets, or None (numeric dict)."""
    if not src._offsets:
        return None
    var off_len = src._offsets.value().len()
    var off_buf = OwnedAlignedBuffer(max(off_len, 1))
    if off_len > 0:
        off_buf.copy_from_view(src._offsets.value().view_range_ro(0, off_len))
    off_buf.set_length(Int64(off_len))
    return off_buf^


def _carry_dict_payload(
    mut out: Column[HeapRegion], src: Column[HeapRegion], w: Int
):
    """Give `out` a copy of `src`'s dictionary values, its size and value
    dtype, and code width `w`. The offsets go through the Column constructor
    (`_copy_dict_offsets`)."""
    if src._dict_data:
        var dlen = src._dict_data.value().len()
        var dbuf = OwnedAlignedBuffer(max(dlen, 1))
        if dlen > 0:
            dbuf.copy_from_view(src._dict_data.value().view_range_ro(0, dlen))
        dbuf.set_length(Int64(dlen))
        out._set_dict_data_from_oab(dbuf^)
    out._dict_size = src._dict_size
    out._dict_value_dtype = src._dict_value_dtype
    out._dict_index_byte_width = w


def _numeric_dict_value_width(col: Column[HeapRegion]) raises -> Int:
    var vdt = col._dict_value_dtype
    if vdt == DType.int32 or vdt == DType.float32:
        return 4
    if vdt == DType.int64 or vdt == DType.float64:
        return 8
    raise Error(
        "concat(dictionary): numeric dictionary value dtype "
        + String(vdt)
        + " has no merge arm (int32/int64/float32/float64 only)"
    )


def _concat_dict_columns[
    o_a: Origin[mut=False], o_b: Origin[mut=False]
](
    ref [o_a] a: Column[HeapRegion],
    ref [o_b] b: Column[HeapRegion],
    var validity: Optional[Bitmap[HeapRegion]],
) raises -> Column[HeapRegion]:
    """Pair-wise DICTIONARY concat `a ++ b`. `validity` is the caller's merged
    bitmap for the `a._length + b._length` output rows.

    Fast path: the dictionaries are identical (`_dicts_identical`), so the
    codes are copied through and `a`'s dictionary is kept. Otherwise `b`'s
    dictionary is merged into `a`'s and `b`'s codes are remapped.
    """
    comptime site = "_concat_columns(pair-wise, dictionary)"
    _refuse_dict_layout_disagreement(site, 1, a, b)
    var w = a._dict_index_byte_width
    var len_a = a._length
    var len_b = b._length
    var total = len_a + len_b
    var null_count = a._null_count + b._null_count

    var new_data = OwnedAlignedBuffer(max(total * w, 1))
    new_data.set_length(Int64(total * w))

    if _dicts_identical(a, b):
        # Fast path: identical dictionaries. Just concat the code windows.
        _copy_dict_codes(new_data, 0, a, w)
        _copy_dict_codes(new_data, len_a, b, w)
        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=new_data^,
            offsets=_copy_dict_offsets(a),
            validity=validity^,
            length=total,
            null_count=null_count,
            offset=0,
        )
        _carry_dict_payload(col, a, w)
        return col^

    # Slow path: different dictionaries. Build remap table b_code -> merged.
    # Start with a's dictionary as the canonical one; each of b's entries is
    # found in it or appended.
    #
    # ⛔ NOT A LINEAR SCAN OVER A `List[String]`, and NOT a rare case:
    # common writers emit a dictionary PER ROW GROUP, so such a parquet
    # file lands here on column 0. A free-text column can intern millions
    # of distinct values over dozens of row groups, and a linear scan makes
    # the fold Σ k·d² comparisons — a merge that never finishes.
    #
    # `DictInterner` is an append-only bytes arena + Int32 offsets + an
    # open-addressing index, so a merge is O(Σ dict_size) probes and ZERO
    # per-entry `String` allocations. It preserves FIRST-SEEN insertion
    # order, which this repo's byte-equivalence oracles depend on, and
    # `seed_append` preserves DUPLICATES in a's dictionary — a's code window
    # is copied through unchanged below, so entry i must stay at ordinal i
    # even when a's dictionary is not distinct.
    #
    # A NUMERIC dictionary interns each value's `vw` bytes as its key, so the
    # merged arena is again a flat value buffer (every entry is `vw` bytes).
    _require_dict_payload(site, 0, a)
    _require_dict_payload(site, 1, b)
    var numeric = a.is_numeric_dict()
    var vw = _numeric_dict_value_width(a) if numeric else 0
    var dict_size_a = a._dict_size
    var dict_size_b = b._dict_size
    var interner = DictInterner(expected_entries=dict_size_a + dict_size_b)
    # The key of every entry of a string dictionary that omits its (then
    # zero-length) values buffer: `_require_dict_payload` proved them empty.
    var no_bytes = OwnedAlignedBuffer(1)
    no_bytes.set_length(0)
    for i in range(dict_size_a):
        if numeric:
            _ = interner.seed_append(
                a._dict_data.value().view_ro().sub(i * vw, vw)
            )
        elif not a._dict_data:
            _ = interner.seed_append(no_bytes.view_range_ro(0, 0))
        else:
            var s = Int(a._offsets.value().get_typed[Int32](i))
            var e = Int(a._offsets.value().get_typed[Int32](i + 1))
            _ = interner.seed_append(
                a._dict_data.value().view_ro().sub(s, e - s)
            )

    var remap = List[Int32](capacity=max(dict_size_b, 1))
    for i in range(dict_size_b):
        if numeric:
            remap.append(
                interner.find_or_insert(
                    b._dict_data.value().view_ro().sub(i * vw, vw)
                )
            )
        elif not b._dict_data:
            remap.append(interner.find_or_insert(no_bytes.view_range_ro(0, 0)))
        else:
            var bs = Int(b._offsets.value().get_typed[Int32](i))
            var be = Int(b._offsets.value().get_typed[Int32](i + 1))
            remap.append(
                interner.find_or_insert(
                    b._dict_data.value().view_ro().sub(bs, be - bs)
                )
            )

    dict_merge_probe_add(interner.probes())

    var merged_size = interner.size()
    var total_data_len = interner.total_bytes()
    # Int32-offset ceiling on the MERGED dictionary values buffer (the
    # interner's own offsets are Int32, numeric or not).
    check_int32_offsets("concat(dictionary values)", total_data_len, merged_size)

    # a's codes pass through unchanged (seed_append kept a's ordinals).
    _copy_dict_codes(new_data, 0, a, w)
    # b's codes are remapped. The code under a NULL slot is undefined in Arrow
    # and is never looked up: the output carries 0 there. A non-null code
    # outside b's dictionary is refused rather than read past the table.
    for i in range(len_b):
        var out_code = 0
        if not _row_is_null(b, i):
            var code: Int
            if w == 8:
                code = Int(b._data.get_typed[Int64](b._offset + i))
            else:
                code = Int(b._data.get_typed[Int32](b._offset + i))
            if code < 0 or code >= dict_size_b:
                raise Error(
                    String("ArrowConcatDictCodeOutOfRange: ")
                    + String(site)
                    + ": input 1 row "
                    + String(i)
                    + " carries code "
                    + String(code)
                    + " but its dictionary has "
                    + String(dict_size_b)
                    + " entries"
                )
            out_code = Int(remap[code])
        if w == 8:
            new_data.set_typed[Int64](len_a + i, Int64(out_code))
        else:
            new_data.set_typed[Int32](len_a + i, Int32(out_code))

    var merged_offsets = Optional[OwnedAlignedBuffer](None)
    if not numeric:
        comptime int32_size = size_of[Int32]()
        var merged_offs_bytes = (merged_size + 1) * int32_size
        var merged_offs_buf = OwnedAlignedBuffer(merged_offs_bytes)
        merged_offs_buf.copy_from_int32_list(interner.offsets())
        merged_offs_buf.set_length(Int64(merged_offs_bytes))
        merged_offsets = merged_offs_buf^

    var merged_data_buf = OwnedAlignedBuffer(max(total_data_len, 1))
    merged_data_buf.copy_from_bytes_list(interner.bytes())
    merged_data_buf.set_length(Int64(total_data_len))

    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=new_data^,
        offsets=merged_offsets^,
        validity=validity^,
        length=total,
        null_count=null_count,
        offset=0,
    )
    col._set_dict_data_from_oab(merged_data_buf^)
    col._dict_size = merged_size
    col._dict_index_byte_width = w
    col._dict_value_dtype = a._dict_value_dtype
    return col^
