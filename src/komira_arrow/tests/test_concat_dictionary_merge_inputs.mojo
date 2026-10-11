# =============================================================================
# concat of DICTIONARY columns whose dictionaries differ (the remap path)
# =============================================================================
#
# Kept apart from `test_concat_dictionary_inputs.mojo` because, before the
# fix, every case here ABORTED or read out of bounds instead of returning a
# wrong value, and an abort would hide the other file's results:
#   * numeric dictionaries with different values: the merge unwrapped the
#     string-dictionary `_offsets`, which a numeric dictionary does not have;
#   * a NULL row whose code is out of range: Arrow leaves the code under a null
#     slot undefined, and the remap looked it up anyway;
#   * a dictionary that claims entries but carries no data buffer: the merge
#     unwrapped the absent buffer. It must be refused with an error.
#   * a non-null code past the end of its dictionary: refused, not looked up.
#     Both boundaries are pinned (code == dict_size, code == -1) at both code
#     widths, with and without nulls in the input (the remap has one loop per
#     case);
#   * a dictionary whose buffers are present but too short or inconsistent
#     (short values buffer, short offsets buffer, last offset past the values,
#     decreasing offsets, including at the last entry, negative first
#     offset): refused before any entry is read. Each refusal is asserted by
#     error name and reason. Valid layouts those checks must keep accepting
#     are pinned too: offsets that start above 0, and an all-empty string
#     dictionary whose values buffer is omitted.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.concat import _concat_columns, concat_record_batches_nway_ref
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, Field
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab


def _no_nulls(n: Int) -> List[Bool]:
    var m = List[Bool](capacity=n)
    for _ in range(n):
        m.append(False)
    return m^


def _nulls_in(nulls: List[Bool]) -> Int:
    var c = 0
    for i in range(len(nulls)):
        if nulls[i]:
            c += 1
    return c


def _validity(nulls: List[Bool]) -> Optional[Bitmap[HeapRegion]]:
    if _nulls_in(nulls) == 0:
        return None
    var bm = Bitmap.create_all_valid(len(nulls))
    for i in range(len(nulls)):
        if nulls[i]:
            bm.clear(i)
    return bm^


def _str_dict_col(
    codes: List[Int],
    dict_data: String,
    dict_offs: List[Int],
    nulls: List[Bool],
    width: Int = 4,
) raises -> Column[HeapRegion]:
    var n = len(codes)
    var buf = OwnedAlignedBuffer(max(n * width, 1))
    buf.set_length(Int64(n * width))
    for i in range(n):
        if width == 8:
            buf.set_typed[Int64](i, Int64(codes[i]))
        else:
            buf.set_typed[Int32](i, Int32(codes[i]))
    var obuf = OwnedAlignedBuffer(len(dict_offs) * 4)
    obuf.set_length(Int64(len(dict_offs) * 4))
    for i in range(len(dict_offs)):
        obuf.set_typed[Int32](i, Int32(dict_offs[i]))
    var bytes = dict_data.as_bytes()
    var dbuf = OwnedAlignedBuffer(max(len(bytes), 1))
    dbuf.set_length(Int64(len(bytes)))
    for i in range(len(bytes)):
        dbuf.write_u8_at(i, bytes[i])
    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=buf^,
        offsets=Optional(obuf^),
        validity=_validity(nulls),
        length=n,
        null_count=_nulls_in(nulls),
        offset=0,
    )
    col._set_dict_data_from_oab(dbuf^)
    col._dict_size = len(dict_offs) - 1
    col._dict_index_byte_width = width
    return col^


def _code_at(col: Column[HeapRegion], r: Int) -> Int:
    var e = col._offset + r
    if col._dict_index_byte_width == 8:
        return Int(col._data.get_typed[Int64](e))
    return Int(col._data.get_typed[Int32](e))


def _is_null(col: Column[HeapRegion], r: Int) -> Bool:
    if not col._validity:
        return False
    return not col._validity.value().test(col._offset + r)


def _dict_str_at(col: Column[HeapRegion], r: Int) -> String:
    var code = _code_at(col, r)
    var s = Int(col._offsets.value().get_typed[Int32](code))
    var e = Int(col._offsets.value().get_typed[Int32](code + 1))
    var out = String()
    for i in range(s, e):
        out += chr(Int(col._dict_data.value().read_u8_at(i)))
    return out^


def _batch(var col: Column[HeapRegion]) raises -> RecordBatch:
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(col^)
    return b.build(Schema.from_fields_1(Field("c", ArrowType.DICTIONARY, True)))


def _codes(vals: List[Int]) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, Int32(vals[i]))
    return arr^


def _check_numeric(col: Column[HeapRegion], want: List[Int], label: String) raises:
    assert_true(col.is_numeric_dict(), label + ": still a numeric dictionary")
    assert_true(col.dict_value_dtype() == DType.int64, label + ": value dtype")
    assert_equal(col._length, len(want), label + ": length")
    for r in range(len(want)):
        var code = col.dict_code_at(r)
        assert_true(code >= 0 and code < col._dict_size, label + ": code in range")
        assert_equal(
            Int(col.dict_value_i64(code)), want[r], label + ": value at " + String(r)
        )


def test_pairwise_numeric_dicts_with_different_values_merge() raises:
    var a = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes([0, 1]), [Int64(100), Int64(200)]
    )
    var b = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes([1, 0, 1]), [Int64(200), Int64(300)]
    )
    var out = _concat_columns(a, b)
    _check_numeric(out, [100, 200, 300, 200, 300], "pair numeric merge")
    assert_equal(out._dict_size, 3, "merged numeric dictionary is distinct")


def test_nway_numeric_dicts_with_different_values_merge() raises:
    var batches = Slab[RecordBatch]()
    batches.append(
        _batch(
            Column.from_numeric_dict[DType.int32, DType.int64](
                _codes([0, 1, 1]), [Int64(100), Int64(200)]
            ).slice(1, 2)
        )
    )
    batches.append(
        _batch(
            Column.from_numeric_dict[DType.int32, DType.int64](
                _codes([1]), [Int64(7), Int64(100)]
            )
        )
    )
    var out = concat_record_batches_nway_ref(batches)
    _check_numeric(out.column_at(0), [200, 200, 100], "nway numeric merge")


def test_remap_does_not_look_up_codes_under_null_slots() raises:
    var a = _str_dict_col([0], "xyz", [0, 1, 2, 3], _no_nulls(1))
    # b's dictionary is ["z", "w"]; row 1 is NULL with an out-of-range code.
    var b = _str_dict_col([0, 1000000000, 1], "zw", [0, 1, 2], [False, True, False])
    var out = _concat_columns(a, b)
    assert_equal(out._length, 4, "length")
    assert_equal(out._null_count, 1, "null_count")
    for r in range(4):
        var code = _code_at(out, r)
        assert_true(
            code >= 0 and code < out._dict_size,
            "every output code indexes the dictionary (row " + String(r) + ")",
        )
    assert_equal(_dict_str_at(out, 0), "x", "row 0")
    assert_equal(_dict_str_at(out, 1), "z", "row 1")
    assert_true(_is_null(out, 2), "row 2 null")
    assert_equal(_code_at(out, 2), 0, "the code under the NULL slot is 0")
    assert_equal(_dict_str_at(out, 3), "w", "row 3")


def _pair_error(a: Column[HeapRegion], b: Column[HeapRegion]) -> String:
    """The error `a ++ b` raises, or "" if it returns."""
    try:
        _ = _concat_columns(a, b)
    except e:
        return String(e)
    return String()


def _assert_refused(msg: String, name: String, reason: String, label: String) raises:
    assert_true(
        msg.startswith(name + ": ") and msg.find(reason) >= 0,
        label + ": want " + name + " (" + reason + "), got '" + msg + "'",
    )


def test_remap_refuses_a_non_null_code_past_the_dictionary() raises:
    """b's dictionary ["z", "w"] has 2 entries: codes 2 and -1 are out of
    range and 1 is in. Each at code widths 4 and 8, in an input without
    nulls and in one with a NULL row ahead of the bad code."""
    var a_offs: List[Int] = [0, 1, 2, 3]
    var b_offs: List[Int] = [0, 1, 2]
    var bad: List[Int] = [2, -1]
    for wi in range(2):
        var w = 4 if wi == 0 else 8
        for with_null in range(2):
            var label = (
                "width " + String(w) + (", nulls" if with_null == 1 else ", no nulls")
            )
            var a = _str_dict_col([0], "xyz", a_offs.copy(), _no_nulls(1), w)
            for k in range(len(bad)):
                var codes: List[Int] = [1, bad[k]]
                var nulls: List[Bool] = [False, False]
                if with_null == 1:
                    codes = [7, 1, bad[k]]
                    nulls = [True, False, False]
                var b = _str_dict_col(codes, "zw", b_offs.copy(), nulls, w)
                _assert_refused(
                    _pair_error(a, b),
                    "ArrowConcatDictCodeOutOfRange",
                    "carries code " + String(bad[k]) + " ",
                    label + ", code " + String(bad[k]),
                )
            # The last in-range code is accepted and decoded.
            var ok_codes: List[Int] = [1, 1]
            var ok_nulls: List[Bool] = [False, False]
            if with_null == 1:
                ok_codes = [7, 1]
                ok_nulls = [True, False]
            var out = _concat_columns(
                a, _str_dict_col(ok_codes, "zw", b_offs.copy(), ok_nulls, w)
            )
            assert_equal(_dict_str_at(out, 2), "w", label + ": code 1 decodes")


def test_dictionary_without_data_buffer_is_refused() raises:
    var a = _str_dict_col([0, 1], "xy", [0, 1, 2], _no_nulls(2))
    a._dict_data = None
    var b = _str_dict_col([0], "zwv", [0, 1, 2, 3], _no_nulls(1))
    _assert_refused(
        _pair_error(a, b),
        "ArrowConcatDictMissingPayload",
        "no dictionary values buffer",
        "a dictionary claiming 2 entries with no data",
    )


def _zw() raises -> Column[HeapRegion]:
    return _str_dict_col([0, 1], "zw", [0, 1, 2], _no_nulls(2))


def test_short_numeric_values_buffer_is_refused() raises:
    """3 int64 entries claimed over a 16-byte values buffer: entry 2 would be
    read past the buffer."""
    var a = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes([0, 1]), [Int64(100), Int64(200)]
    )
    a._dict_size = 3
    var b = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes([0]), [Int64(300)]
    )
    _assert_refused(
        _pair_error(a, b), "ArrowConcatDictMalformed", "values buffer holds 16 bytes", "short numeric values"
    )


def test_short_offsets_buffer_is_refused() raises:
    """3 string entries claimed over 3 Int32 offsets (4 are needed)."""
    var b = _str_dict_col([0, 1], "zw", [0, 1, 2], _no_nulls(2))
    b._dict_size = 3
    _assert_refused(
        _pair_error(_str_dict_col([0], "x", [0, 1], _no_nulls(1)), b),
        "ArrowConcatDictMalformed",
        "offsets buffer holds 12 bytes",
        "short offsets",
    )


def test_last_offset_past_values_buffer_is_refused() raises:
    """Offsets [0, 1, 5] over the 2 bytes "zw": entry 1 would read 4 bytes
    from a 2-byte buffer. Pair-wise and N-way."""
    var a = _str_dict_col([0, 1], "zw", [0, 1, 5], _no_nulls(2))
    _assert_refused(
        _pair_error(a, _zw()), "ArrowConcatDictMalformed", "last offset 5 runs past", "pair last offset"
    )
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_str_dict_col([0, 1], "zw", [0, 1, 5], _no_nulls(2))))
    batches.append(_batch(_str_dict_col([0], "q", [0, 1], _no_nulls(1))))
    var msg = String()
    try:
        _ = concat_record_batches_nway_ref(batches)
    except e:
        msg = String(e)
    _assert_refused(msg, "ArrowConcatDictMalformed", "last offset 5 runs past", "nway last offset")


def test_decreasing_offsets_are_refused() raises:
    """Offsets [0, 2, 1, 3]: entry 1 would be a negative-length read."""
    var b = _str_dict_col([0, 2], "xyz", [0, 2, 1, 3], _no_nulls(2))
    _assert_refused(
        _pair_error(_zw(), b), "ArrowConcatDictMalformed", "offsets decrease at entry 2", "decreasing offsets"
    )


def test_offsets_decreasing_at_the_last_entry_are_refused() raises:
    """Offsets [0, 1, 3, 2] over "abc": the decrease is at the final offset,
    the one the loop reads last; the last offset (2) is inside the buffer,
    so only the decrease check refuses it."""
    var b = _str_dict_col([0, 2], "abc", [0, 1, 3, 2], _no_nulls(2))
    _assert_refused(
        _pair_error(_zw(), b),
        "ArrowConcatDictMalformed",
        "offsets decrease at entry 3",
        "decrease at the last entry",
    )


def _check_strs(
    col: Column[HeapRegion], want: List[String], label: String
) raises:
    assert_equal(col._length, len(want), label + ": length")
    for r in range(len(want)):
        assert_equal(_dict_str_at(col, r), want[r], label + ": row " + String(r))


def test_string_dictionary_offsets_starting_above_zero_are_accepted() raises:
    """Offsets [2, 3, 4] over "qqzw" is the dictionary ["z", "w"] (valid
    Arrow: the first offset need not be 0). Accepted as either input, and
    decoded through its own offsets."""
    var offs: List[Int] = [2, 3, 4]
    var other_offs: List[Int] = [0, 1, 2]
    var d = _str_dict_col([1, 0], "qqzw", offs.copy(), _no_nulls(2))
    var other = _str_dict_col([0, 1], "xw", other_offs.copy(), _no_nulls(2))
    _check_strs(_concat_columns(d, other), ["w", "z", "x", "w"], "based first")
    var d2 = _str_dict_col([1, 0], "qqzw", offs.copy(), _no_nulls(2))
    var other2 = _str_dict_col([0, 1], "xw", other_offs.copy(), _no_nulls(2))
    _check_strs(_concat_columns(other2, d2), ["x", "w", "w", "z"], "based second")


def test_all_empty_string_dictionary_without_values_buffer_is_accepted() raises:
    """Two empty entries, offsets [3, 3, 3], values buffer omitted: the
    offsets span zero bytes, so the omitted buffer is a legal zero-length
    one. Accepted as either input; its rows decode as ""."""
    var offs: List[Int] = [3, 3, 3]
    var other_offs: List[Int] = [0, 1, 2]
    var d = _str_dict_col([1, 0], "", offs.copy(), _no_nulls(2))
    d._dict_data = None
    var other = _str_dict_col([0, 1], "xy", other_offs.copy(), _no_nulls(2))
    _check_strs(_concat_columns(d, other), ["", "", "x", "y"], "empty first")
    var d2 = _str_dict_col([1, 0], "", offs.copy(), _no_nulls(2))
    d2._dict_data = None
    var other2 = _str_dict_col([0, 1], "xy", other_offs.copy(), _no_nulls(2))
    _check_strs(_concat_columns(other2, d2), ["x", "y", "", ""], "empty second")


def test_negative_first_offset_is_refused() raises:
    """Offsets [-1, 1, 2]: entry 0 would read the byte before the buffer."""
    var a = _str_dict_col([0, 1], "zw", [-1, 1, 2], _no_nulls(2))
    _assert_refused(
        _pair_error(a, _str_dict_col([0], "q", [0, 1], _no_nulls(1))),
        "ArrowConcatDictMalformed",
        "first offset is negative",
        "negative first offset",
    )


def main() raises:
    var t = TestSuite()
    t.test[test_pairwise_numeric_dicts_with_different_values_merge]()
    t.test[test_nway_numeric_dicts_with_different_values_merge]()
    t.test[test_remap_does_not_look_up_codes_under_null_slots]()
    t.test[test_remap_refuses_a_non_null_code_past_the_dictionary]()
    t.test[test_dictionary_without_data_buffer_is_refused]()
    t.test[test_short_numeric_values_buffer_is_refused]()
    t.test[test_short_offsets_buffer_is_refused]()
    t.test[test_last_offset_past_values_buffer_is_refused]()
    t.test[test_decreasing_offsets_are_refused]()
    t.test[test_negative_first_offset_is_refused]()
    t.test[test_offsets_decreasing_at_the_last_entry_are_refused]()
    t.test[test_string_dictionary_offsets_starting_above_zero_are_accepted]()
    t.test[test_all_empty_string_dictionary_without_values_buffer_is_accepted]()
    t^.run()
