# =============================================================================
# merge_dict_columns: slices, code width, dictionary identity, numeric values
# =============================================================================
#
# `dictionary_merge.merge_dict_columns` is the N-way union of DICTIONARY
# columns. Row `i` of an input is code element `_offset + i` (at
# `_dict_index_byte_width` bytes) and validity bit `_offset + i`; every test
# asserts the Arrow answer computed from the fixture's own lists, decoded
# through the output's dictionary.
#
# What each test is built to catch:
#   * sliced inputs, remap path and identical-dictionary path: codes and
#     validity read from element 0 instead of `_offset` return the rows
#     before the window.
#   * Int64 codes: read at 4 bytes they come back as [low half, high half];
#     the output must stay 8 bytes wide. The single-input arm must keep the
#     width too.
#   * ["a","b"] and ["ab",""] have the same bytes and different offsets: a
#     fast path that compares only the bytes decodes the second input's codes
#     through the first dictionary.
#   * numeric dictionaries (no `_offsets`) merge, keeping the value dtype.
#   * the code under a NULL slot is undefined in Arrow and must never be
#     looked up; a non-null code outside the dictionary is refused by name.
#   * code widths that disagree between inputs are refused by name.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.dictionary_merge import merge_dict_columns
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab


def _no_nulls(n: Int) -> List[Bool]:
    var m = List[Bool](capacity=n)
    for _ in range(n):
        m.append(False)
    return m^


def _nulls_in(nulls: List[Bool], off: Int, n: Int) -> Int:
    var c = 0
    for i in range(off, off + n):
        if nulls[i]:
            c += 1
    return c


def _validity(nulls: List[Bool]) -> Optional[Bitmap[HeapRegion]]:
    if _nulls_in(nulls, 0, len(nulls)) == 0:
        return None
    var bm = Bitmap.create_all_valid(len(nulls))
    for i in range(len(nulls)):
        if nulls[i]:
            bm.clear(i)
    return bm^


def _str_dict_col(
    codes: List[Int],
    width: Int,
    dict_data: String,
    dict_offs: List[Int],
    nulls: List[Bool],
    off: Int,
    n: Int,
) raises -> Column[HeapRegion]:
    """A string DICTIONARY column, codes `width` bytes each (little endian),
    viewing rows [off, off + n) of `codes` / `nulls`."""
    var total = len(codes)
    var buf = OwnedAlignedBuffer(max(total * width, 1))
    buf.set_length(Int64(total * width))
    for i in range(total):
        var v = codes[i]
        for k in range(width):
            buf.write_u8_at(i * width + k, UInt8((v >> (8 * k)) & 0xFF))
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
        null_count=_nulls_in(nulls, off, n),
        offset=off,
    )
    col._set_dict_data_from_oab(dbuf^)
    col._dict_size = len(dict_offs) - 1
    col._dict_index_byte_width = width
    return col^


def _xyz_offs() -> List[Int]:
    return [0, 1, 2, 3]


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


def _check_str_dict(
    col: Column[HeapRegion],
    want: List[String],
    want_null: List[Bool],
    width: Int,
    label: String,
) raises:
    assert_equal(col.arrow_type, ArrowType.DICTIONARY, label + ": type")
    assert_equal(col._dict_index_byte_width, width, label + ": code width")
    assert_equal(col._length, len(want), label + ": length")
    assert_equal(
        col._null_count,
        _nulls_in(want_null, 0, len(want_null)),
        label + ": null_count",
    )
    for r in range(len(want)):
        assert_equal(
            _is_null(col, r), want_null[r], label + ": null at " + String(r)
        )
        if not want_null[r]:
            assert_equal(
                _dict_str_at(col, r), want[r], label + ": value at " + String(r)
            )


def _merge_error(var a: Column[HeapRegion], var b: Column[HeapRegion]) -> String:
    """The error `merge_dict_columns([a, b])` raises, or "" if it returns."""
    var cols = Slab[Column[HeapRegion]]()
    cols.append(a^)
    cols.append(b^)
    try:
        _ = merge_dict_columns(cols)
    except e:
        return String(e)
    return String()


def _assert_refused(msg: String, name: String, label: String) raises:
    assert_true(
        msg.startswith(name + ": "),
        label + ": want a " + name + " error, got '" + msg + "'",
    )


# -----------------------------------------------------------------------------
# Sliced inputs
# -----------------------------------------------------------------------------


def test_merge_remap_sliced_inputs_with_nulls() raises:
    # a: rows z x y(null) z over ["x","y","z"]; window [1, 4) = x, null, z.
    var a = _str_dict_col(
        [2, 0, 1, 2], 4, "xyz", _xyz_offs(), [False, False, True, False], 1, 3
    )
    # b: rows z w w z over ["z","w"] (null at 0); window [2, 4) = w, z.
    var b = _str_dict_col(
        [0, 1, 1, 0], 4, "zw", [0, 1, 2], [True, False, False, False], 2, 2
    )
    var cols = Slab[Column[HeapRegion]]()
    cols.append(a^)
    cols.append(b^)
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out,
        [String("x"), String(""), String("z"), String("w"), String("z")],
        [False, True, False, False, False],
        4,
        "remap sliced",
    )


def test_merge_identical_dicts_sliced_inputs_with_nulls() raises:
    # Rows x y z x y z; nulls at 1, 3. Windows [3, 6) and [0, 2).
    var codes: List[Int] = [0, 1, 2, 0, 1, 2]
    var nulls: List[Bool] = [False, True, False, True, False, False]
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 3, 3))
    cols.append(_str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 0, 2))
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out,
        [String(""), String("y"), String("z"), String("x"), String("")],
        [True, False, False, False, True],
        4,
        "identical sliced",
    )


# -----------------------------------------------------------------------------
# Int64 codes
# -----------------------------------------------------------------------------


def test_merge_int64_codes_remap_sliced() raises:
    var a = _str_dict_col(
        [2, 0, 1, 2], 8, "xyz", _xyz_offs(), [False, False, True, False], 1, 3
    )
    var b = _str_dict_col([0, 1, 1, 0], 8, "zw", [0, 1, 2], _no_nulls(4), 2, 2)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(a^)
    cols.append(b^)
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out,
        [String("x"), String(""), String("z"), String("w"), String("z")],
        [False, True, False, False, False],
        8,
        "int64 remap sliced",
    )


def test_merge_int64_codes_identical_dicts() raises:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_str_dict_col([2, 1], 8, "xyz", _xyz_offs(), _no_nulls(2), 0, 2))
    cols.append(_str_dict_col([0], 8, "xyz", _xyz_offs(), _no_nulls(1), 0, 1))
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out,
        [String("z"), String("y"), String("x")],
        _no_nulls(3),
        8,
        "int64 identical",
    )


def test_merge_single_input_keeps_int64_codes_and_slice() raises:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(
        _str_dict_col(
            [0, 2, 1, 0], 8, "xyz", _xyz_offs(), [False, False, True, False], 1, 3
        )
    )
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out,
        [String("z"), String(""), String("x")],
        [False, True, False],
        8,
        "single int64 sliced",
    )


# -----------------------------------------------------------------------------
# Dictionary identity includes the offsets
# -----------------------------------------------------------------------------


def test_merge_same_bytes_different_offsets_is_not_identical() raises:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_str_dict_col([0, 1], 4, "ab", [0, 1, 2], _no_nulls(2), 0, 2))
    cols.append(_str_dict_col([1, 0], 4, "ab", [0, 2, 2], _no_nulls(2), 0, 2))
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out,
        [String("a"), String("b"), String(""), String("ab")],
        _no_nulls(4),
        4,
        "same bytes",
    )


# -----------------------------------------------------------------------------
# Numeric dictionaries
# -----------------------------------------------------------------------------


def _codes(vals: List[Int], nulls: List[Bool]) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(vals))
    var p = arr._typed_ptr_mut()
    for i in range(len(vals)):
        p.store[width=1](i, Int32(vals[i]))
        if nulls[i]:
            arr._set_null(i)
    arr.null_count = _nulls_in(nulls, 0, len(nulls))
    return arr^


def test_merge_numeric_dicts_sliced() raises:
    # a: values [100, 200, 300], codes 2 0(null) 1 0, sliced to [1, 4).
    # b: values [300, 400], codes 1 0.
    var nulls: List[Bool] = [False, True, False, False]
    var cols = Slab[Column[HeapRegion]]()
    cols.append(
        Column.from_numeric_dict[DType.int32, DType.int64](
            _codes([2, 0, 1, 0], nulls),
            [Int64(100), Int64(200), Int64(300)],
        ).slice(1, 3)
    )
    cols.append(
        Column.from_numeric_dict[DType.int32, DType.int64](
            _codes([1, 0], _no_nulls(2)), [Int64(300), Int64(400)]
        )
    )
    var out = merge_dict_columns(cols)
    var want: List[Int] = [0, 200, 100, 400, 300]
    var want_null: List[Bool] = [True, False, False, False, False]
    assert_true(out.is_numeric_dict(), "numeric: still a numeric dictionary")
    assert_true(out.dict_value_dtype() == DType.int64, "numeric: value dtype")
    assert_equal(out._length, 5, "numeric: length")
    assert_equal(out._null_count, 1, "numeric: null_count")
    for r in range(5):
        assert_equal(_is_null(out, r), want_null[r], "numeric: null at " + String(r))
        if not want_null[r]:
            assert_equal(
                Int(out.dict_value_i64(out.dict_code_at(r))),
                want[r],
                "numeric: value at " + String(r),
            )


# -----------------------------------------------------------------------------
# Codes under NULL slots, out-of-range codes, disagreeing widths
# -----------------------------------------------------------------------------


def test_merge_never_looks_up_the_code_under_a_null() raises:
    # b's row 0 is NULL and carries code 7; its dictionary has 2 entries.
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_str_dict_col([0], 4, "xyz", _xyz_offs(), _no_nulls(1), 0, 1))
    cols.append(_str_dict_col([7, 1], 4, "zw", [0, 1, 2], [True, False], 0, 2))
    var out = merge_dict_columns(cols)
    _check_str_dict(
        out, [String("x"), String(""), String("w")], [False, True, False], 4, "null slot"
    )


def test_merge_refuses_a_non_null_code_outside_the_dictionary() raises:
    _assert_refused(
        _merge_error(
            _str_dict_col([0], 4, "xyz", _xyz_offs(), _no_nulls(1), 0, 1),
            _str_dict_col([1, 2], 4, "zw", [0, 1, 2], _no_nulls(2), 0, 2),
        ),
        "ArrowConcatDictCodeOutOfRange",
        "code 2 in a 2-entry dictionary",
    )


def test_merge_refuses_mixed_code_widths() raises:
    _assert_refused(
        _merge_error(
            _str_dict_col([0, 1], 4, "xyz", _xyz_offs(), _no_nulls(2), 0, 2),
            _str_dict_col([1, 0], 8, "xyz", _xyz_offs(), _no_nulls(2), 0, 2),
        ),
        "ArrowConcatLayoutDisagreement",
        "4-byte then 8-byte codes",
    )


def main() raises:
    var t = TestSuite()
    t.test[test_merge_remap_sliced_inputs_with_nulls]()
    t.test[test_merge_identical_dicts_sliced_inputs_with_nulls]()
    t.test[test_merge_int64_codes_remap_sliced]()
    t.test[test_merge_int64_codes_identical_dicts]()
    t.test[test_merge_single_input_keeps_int64_codes_and_slice]()
    t.test[test_merge_same_bytes_different_offsets_is_not_identical]()
    t.test[test_merge_numeric_dicts_sliced]()
    t.test[test_merge_refuses_a_non_null_code_outside_the_dictionary]()
    t.test[test_merge_refuses_mixed_code_widths]()
    t.test[test_merge_never_looks_up_the_code_under_a_null]()
    t^.run()
