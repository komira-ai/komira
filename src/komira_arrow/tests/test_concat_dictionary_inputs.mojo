# =============================================================================
# concat of DICTIONARY columns: nulls, index width, slices, dictionary identity
# =============================================================================
#
# A dictionary column is codes (`_data`, `_dict_index_byte_width` bytes each,
# addressed from element `_offset`) plus a dictionary: for a string dictionary
# Int32 `_offsets` over `_dict_data` bytes, for a numeric one a flat value
# buffer tagged by `_dict_value_dtype`. Every test asserts the Arrow-spec
# answer computed from the fixture's own lists.
#
# What each test is built to catch:
#   * identical-dictionary fast path with nulls: the output must keep the
#     validity bitmap, not only the null count.
#   * Int64 codes: read at 8 bytes and emitted at 8 bytes; read at 4 they come
#     back as [low half, high half, ...].
#   * sliced codes: the codes and validity of a sliced input start at `_offset`.
#   * two dictionaries with the same bytes but different offsets are different
#     dictionaries (["a","b"] vs ["ab",""]); a fast path that compares only the
#     bytes reuses the wrong one.
#   * code widths that disagree between inputs, or that are not 4 or 8 (the
#     only widths a Column carries), are refused instead of read at the wrong
#     stride; so are dictionaries of different kinds (numeric value dtypes
#     that differ, string vs numeric). Each refusal is asserted by its error
#     name, so a different failure on the way does not pass for it.
#   * a numeric dictionary stays numeric: `_dict_value_dtype` is carried.
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
    """A string DICTIONARY column in the `from_dictionary` /
    `from_int64_dict_indices` layout, codes `width` bytes each (little
    endian), viewing rows [off, off + n)."""
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
    label: String,
) raises:
    assert_equal(col.arrow_type, ArrowType.DICTIONARY, label + ": type")
    assert_equal(col._length, len(want), label + ": length")
    assert_equal(
        col._null_count, _nulls_in(want_null, 0, len(want_null)), label + ": null_count"
    )
    for r in range(len(want)):
        assert_equal(_is_null(col, r), want_null[r], label + ": null at " + String(r))
        if not want_null[r]:
            assert_equal(_dict_str_at(col, r), want[r], label + ": value at " + String(r))


def _batch(var col: Column[HeapRegion]) raises -> RecordBatch:
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(col^)
    return b.build(Schema.from_fields_1(Field("c", ArrowType.DICTIONARY, True)))


# -----------------------------------------------------------------------------
# Identical-dictionary fast path keeps nulls
# -----------------------------------------------------------------------------


def test_pairwise_identical_dict_keeps_nulls() raises:
    """Issue item 3: the fast path set `validity=None` and kept the count."""
    var a = _str_dict_col([0, 1, 0], 4, "xyz", _xyz_offs(), [False, True, False], 0, 3)
    var b = _str_dict_col([1, 2], 4, "xyz", _xyz_offs(), [True, False], 0, 2)
    var out = _concat_columns(a, b)
    _check_str_dict(
        out,
        [String("x"), String(""), String("x"), String(""), String("z")],
        [False, True, False, True, False],
        "pair identical dict nulls",
    )


def test_nway_identical_dict_sliced_with_nulls() raises:
    # Rows x y z x y z x y z x; nulls at 1, 3, 9. Window [3, 9): 6 rows,
    # starting on a null.
    var codes: List[Int] = [0, 1, 2, 0, 1, 2, 0, 1, 2, 0]
    var nulls: List[Bool] = [False, True, False, True, False, False, False, False, False, True]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 3, 6)))
    batches.append(_batch(_str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 0, 2)))
    batches.append(_batch(_str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 9, 1)))
    var out = concat_record_batches_nway_ref(batches)
    _check_str_dict(
        out.column_at(0),
        [String(""), String("y"), String("z"), String("x"), String("y"), String("z"), String("x"), String(""), String("")],
        [True, False, False, False, False, False, False, True, True],
        "nway identical dict sliced",
    )


def test_pairwise_identical_dict_sliced() raises:
    var codes: List[Int] = [2, 2, 1, 0, 1, 2, 0]
    var nulls: List[Bool] = [False, False, False, True, False, False, False]
    var a = _str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 3, 3)
    var b = _str_dict_col(codes, 4, "xyz", _xyz_offs(), nulls, 5, 2)
    var out = _concat_columns(a, b)
    _check_str_dict(
        out,
        [String(""), String("y"), String("z"), String("z"), String("x")],
        [True, False, False, False, False],
        "pair identical dict sliced",
    )


# -----------------------------------------------------------------------------
# Int64 codes
# -----------------------------------------------------------------------------


def _ab() -> List[String]:
    return [String("a"), String("b")]


def test_pairwise_int64_indices_factory() raises:
    """Issue item 4: codes [0,1] ++ [1] came back as 0,0,1 at width 4."""
    var a = Column.from_int64_dict_indices([Int64(0), Int64(1)], _ab())
    var b = Column.from_int64_dict_indices([Int64(1)], _ab())
    var out = _concat_columns(a, b)
    assert_equal(out._dict_index_byte_width, 8, "int64 codes stay 8 bytes wide")
    _check_str_dict(out, [String("a"), String("b"), String("b")], _no_nulls(3), "pair int64")


def test_nway_int64_indices_sliced_with_nulls() raises:
    var codes: List[Int] = [0, 1, 2, 1, 0, 2]
    var nulls: List[Bool] = [False, False, True, False, False, False]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_str_dict_col(codes, 8, "xyz", _xyz_offs(), nulls, 1, 3)))
    batches.append(_batch(_str_dict_col(codes, 8, "xyz", _xyz_offs(), nulls, 4, 2)))
    var out = concat_record_batches_nway_ref(batches)
    assert_equal(out.column_at(0)._dict_index_byte_width, 8, "nway int64 width")
    _check_str_dict(
        out.column_at(0),
        [String("y"), String(""), String("y"), String("x"), String("z")],
        [False, True, False, False, False],
        "nway int64 sliced",
    )


def test_pairwise_int64_indices_remap_sliced() raises:
    """Different dictionaries (remap path) at width 8, both sliced."""
    var a = _str_dict_col([2, 0, 1, 2], 8, "xyz", _xyz_offs(), [False, False, True, False], 1, 3)
    # b's dictionary is ["z", "w"].
    var b = _str_dict_col([0, 1, 1, 0], 8, "zw", [0, 1, 2], _no_nulls(4), 2, 2)
    var out = _concat_columns(a, b)
    assert_equal(out._dict_index_byte_width, 8, "remap int64 width")
    _check_str_dict(
        out,
        [String("x"), String(""), String("z"), String("w"), String("z")],
        [False, True, False, False, False],
        "pair int64 remap sliced",
    )


def test_pairwise_remap_int32_sliced_with_nulls() raises:
    var a = _str_dict_col([1, 1, 0, 2], 4, "xyz", _xyz_offs(), [False, True, False, False], 1, 3)
    var b = _str_dict_col([1, 0, 1], 4, "wz", [0, 1, 2], [False, True, False], 1, 2)
    var out = _concat_columns(a, b)
    _check_str_dict(
        out,
        [String(""), String("x"), String("z"), String(""), String("z")],
        [True, False, False, True, False],
        "pair int32 remap sliced",
    )


# -----------------------------------------------------------------------------
# Dictionary identity is bytes AND offsets
# -----------------------------------------------------------------------------


def test_pairwise_same_bytes_different_offsets_is_not_identical() raises:
    var a = _str_dict_col([0, 1], 4, "ab", [0, 1, 2], _no_nulls(2), 0, 2)
    var b = _str_dict_col([0, 1], 4, "ab", [0, 2, 2], _no_nulls(2), 0, 2)
    var out = _concat_columns(a, b)
    _check_str_dict(
        out, [String("a"), String("b"), String("ab"), String("")], _no_nulls(4), "pair same bytes"
    )


def test_nway_same_bytes_different_offsets_is_not_identical() raises:
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_str_dict_col([0, 1], 4, "ab", [0, 1, 2], _no_nulls(2), 0, 2)))
    batches.append(_batch(_str_dict_col([1, 0], 4, "ab", [0, 2, 2], _no_nulls(2), 0, 2)))
    var out = concat_record_batches_nway_ref(batches)
    _check_str_dict(
        out.column_at(0),
        [String("a"), String("b"), String(""), String("ab")],
        _no_nulls(4),
        "nway same bytes",
    )


def _without_data(var col: Column[HeapRegion]) -> Column[HeapRegion]:
    """Drop the values buffer (legal when it would be zero-length)."""
    col._dict_data = None
    return col^


def test_pairwise_empty_entry_dictionary_without_buffer_is_not_x() raises:
    """["x"] (buffer present) vs [""] (zero-length buffer omitted): same
    size, so a check that compares bytes only when BOTH sides have a buffer
    calls them identical and decodes b's row as "x". Both orders."""
    var out = _concat_columns(
        _str_dict_col([0], 4, "x", [0, 1], _no_nulls(1), 0, 1),
        _without_data(_str_dict_col([0], 4, "", [0, 0], _no_nulls(1), 0, 1)),
    )
    _check_str_dict(out, [String("x"), String("")], _no_nulls(2), "pair x then empty")
    var out2 = _concat_columns(
        _without_data(_str_dict_col([0], 4, "", [0, 0], _no_nulls(1), 0, 1)),
        _str_dict_col([0], 4, "x", [0, 1], _no_nulls(1), 0, 1),
    )
    _check_str_dict(out2, [String(""), String("x")], _no_nulls(2), "pair empty then x")


def test_nway_empty_entry_dictionary_without_buffer_is_not_x() raises:
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_str_dict_col([0], 4, "x", [0, 1], _no_nulls(1), 0, 1)))
    batches.append(
        _batch(_without_data(_str_dict_col([0, 0], 4, "", [0, 0], _no_nulls(2), 0, 2)))
    )
    var out = concat_record_batches_nway_ref(batches)
    _check_str_dict(
        out.column_at(0), [String("x"), String(""), String("")], _no_nulls(3), "nway x then empty"
    )
    var batches2 = Slab[RecordBatch]()
    batches2.append(
        _batch(_without_data(_str_dict_col([0], 4, "", [0, 0], _no_nulls(1), 0, 1)))
    )
    batches2.append(_batch(_str_dict_col([0], 4, "x", [0, 1], _no_nulls(1), 0, 1)))
    var out2 = concat_record_batches_nway_ref(batches2)
    _check_str_dict(
        out2.column_at(0), [String(""), String("x")], _no_nulls(2), "nway empty then x"
    )


def test_pairwise_identical_dict_null_slot_issue_repro() raises:
    """Issue item 3 as reported: [1, null] ++ [2] over one dictionary."""
    var a = _str_dict_col([1, 0], 4, "xyz", _xyz_offs(), [False, True], 0, 2)
    var b = _str_dict_col([2], 4, "xyz", _xyz_offs(), _no_nulls(1), 0, 1)
    var out = _concat_columns(a, b)
    _check_str_dict(
        out, [String("y"), String(""), String("z")], [False, True, False], "pair [1,null]++[2]"
    )


# -----------------------------------------------------------------------------
# Code widths: disagreeing or unsupported widths are refused
# -----------------------------------------------------------------------------


def _pair_error(var a: Column[HeapRegion], var b: Column[HeapRegion]) -> String:
    """The error `a ++ b` raises, or "" if it returns."""
    try:
        _ = _concat_columns(a, b)
    except e:
        return String(e)
    return String()


def _nway_error(var a: Column[HeapRegion], var b: Column[HeapRegion]) raises -> String:
    var batches = Slab[RecordBatch]()
    batches.append(_batch(a^))
    batches.append(_batch(b^))
    try:
        _ = concat_record_batches_nway_ref(batches)
    except e:
        return String(e)
    return String()


def _assert_refused(msg: String, name: String, label: String) raises:
    assert_true(
        msg.startswith(name + ": "),
        label + ": want a " + name + " error, got '" + msg + "'",
    )


def test_mixed_code_widths_are_refused() raises:
    for identical in range(2):
        var b_data = String("zw")
        var b_offs: List[Int] = [0, 1, 2]
        if identical == 1:
            b_data = String("xyz")
            b_offs = _xyz_offs()
        _assert_refused(
            _pair_error(
                _str_dict_col([0, 1], 4, "xyz", _xyz_offs(), _no_nulls(2), 0, 2),
                _str_dict_col([1, 0], 8, b_data, b_offs.copy(), _no_nulls(2), 0, 2),
            ),
            "ArrowConcatLayoutDisagreement",
            "pair: 4-byte ++ 8-byte codes (identical=" + String(identical) + ")",
        )
        _assert_refused(
            _nway_error(
                _str_dict_col([0, 1], 4, "xyz", _xyz_offs(), _no_nulls(2), 0, 2),
                _str_dict_col([1, 0], 8, b_data, b_offs.copy(), _no_nulls(2), 0, 2),
            ),
            "ArrowConcatLayoutDisagreement",
            "nway: 4-byte ++ 8-byte codes (identical=" + String(identical) + ")",
        )


def test_int8_int16_code_widths_are_refused() raises:
    """1- and 2-byte codes are not a Column layout (the IPC encoder and the
    selection-column builder accept 4 and 8 only). Reading them at 4 bytes is
    a silent wrong answer, so concat must refuse them."""
    for w in range(1, 3):
        _assert_refused(
            _pair_error(
                _str_dict_col([0, 1], w, "xyz", _xyz_offs(), _no_nulls(2), 0, 2),
                _str_dict_col([2], w, "xyz", _xyz_offs(), _no_nulls(1), 0, 1),
            ),
            "ArrowConcatDictCodeWidth",
            "pair: width " + String(w),
        )
        _assert_refused(
            _nway_error(
                _str_dict_col([0, 1], w, "xyz", _xyz_offs(), _no_nulls(2), 0, 2),
                _str_dict_col([2], w, "xyz", _xyz_offs(), _no_nulls(1), 0, 1),
            ),
            "ArrowConcatDictCodeWidth",
            "nway: width " + String(w),
        )


# -----------------------------------------------------------------------------
# Numeric dictionaries keep their value dtype
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


def _vals() -> List[Int64]:
    return [Int64(100), Int64(200), Int64(300)]


def _check_numeric(
    col: Column[HeapRegion], want: List[Int], want_null: List[Bool], label: String
) raises:
    assert_true(col.is_numeric_dict(), label + ": still a numeric dictionary")
    assert_true(col.dict_value_dtype() == DType.int64, label + ": value dtype")
    assert_equal(col._length, len(want), label + ": length")
    assert_equal(
        col._null_count, _nulls_in(want_null, 0, len(want_null)), label + ": null_count"
    )
    for r in range(len(want)):
        assert_equal(_is_null(col, r), want_null[r], label + ": null at " + String(r))
        if not want_null[r]:
            assert_equal(
                Int(col.dict_value_i64(col.dict_code_at(r))),
                want[r],
                label + ": value at " + String(r),
            )


def test_pairwise_numeric_dict_keeps_value_dtype() raises:
    var nulls: List[Bool] = [False, True, False, False]
    var a = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes([2, 0, 1, 0], nulls), _vals()
    ).slice(1, 3)
    var b = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes([1, 2], _no_nulls(2)), _vals()
    )
    var out = _concat_columns(a, b)
    _check_numeric(out, [0, 200, 100, 200, 300], [True, False, False, False, False], "pair numeric")


def test_nway_numeric_dict_keeps_value_dtype() raises:
    var nulls: List[Bool] = [False, True, False, False]
    var batches = Slab[RecordBatch]()
    batches.append(
        _batch(
            Column.from_numeric_dict[DType.int32, DType.int64](
                _codes([2, 0, 1, 0], nulls), _vals()
            ).slice(1, 3)
        )
    )
    batches.append(
        _batch(
            Column.from_numeric_dict[DType.int32, DType.int64](
                _codes([1, 2], _no_nulls(2)), _vals()
            )
        )
    )
    var out = concat_record_batches_nway_ref(batches)
    _check_numeric(
        out.column_at(0), [0, 200, 100, 200, 300], [True, False, False, False, False], "nway numeric"
    )


def _num_dict[val_dt: DType]() raises -> Column[HeapRegion]:
    """Codes [0, 1] over the values [1, 2] stored as `val_dt`."""
    return Column.from_numeric_dict[DType.int32, val_dt](
        _codes([0, 1], _no_nulls(2)), [Int64(1), Int64(2)]
    )


def _xyz_dict() raises -> Column[HeapRegion]:
    return _str_dict_col([0, 1], 4, "xyz", _xyz_offs(), _no_nulls(2), 0, 2)


def test_numeric_value_dtypes_that_differ_are_refused() raises:
    """int32 values ++ int64 values: same codes, same numbers, different
    value widths. Merged at one input's width, the other's entries are read
    at the wrong stride (int64 1 read as int32 entries 1 and 0)."""
    _assert_refused(
        _pair_error(_num_dict[DType.int32](), _num_dict[DType.int64]()),
        "ArrowConcatLayoutDisagreement",
        "pair: int32 ++ int64 values",
    )
    _assert_refused(
        _pair_error(_num_dict[DType.int64](), _num_dict[DType.int32]()),
        "ArrowConcatLayoutDisagreement",
        "pair: int64 ++ int32 values",
    )
    _assert_refused(
        _nway_error(_num_dict[DType.int32](), _num_dict[DType.int64]()),
        "ArrowConcatLayoutDisagreement",
        "nway: int32 ++ int64 values",
    )
    _assert_refused(
        _nway_error(_num_dict[DType.int64](), _num_dict[DType.int32]()),
        "ArrowConcatLayoutDisagreement",
        "nway: int64 ++ int32 values",
    )


def test_string_and_numeric_dictionaries_are_refused() raises:
    """A string dictionary (offsets + bytes) and a numeric one (flat values)
    are two layouts under one tag; merging one into the other reads a buffer
    the other does not have. Both orders, pair-wise and N-way."""
    _assert_refused(
        _pair_error(_xyz_dict(), _num_dict[DType.int64]()),
        "ArrowConcatLayoutDisagreement",
        "pair: string ++ numeric",
    )
    _assert_refused(
        _pair_error(_num_dict[DType.int64](), _xyz_dict()),
        "ArrowConcatLayoutDisagreement",
        "pair: numeric ++ string",
    )
    _assert_refused(
        _nway_error(_xyz_dict(), _num_dict[DType.int64]()),
        "ArrowConcatLayoutDisagreement",
        "nway: string ++ numeric",
    )
    _assert_refused(
        _nway_error(_num_dict[DType.int64](), _xyz_dict()),
        "ArrowConcatLayoutDisagreement",
        "nway: numeric ++ string",
    )


# -----------------------------------------------------------------------------
# Empty slices
# -----------------------------------------------------------------------------


def test_empty_dict_slices() raises:
    var codes: List[Int] = [0, 1, 2]
    var a = _str_dict_col(codes, 4, "xyz", _xyz_offs(), _no_nulls(3), 3, 0)
    var b = _str_dict_col(codes, 4, "xyz", _xyz_offs(), [False, True, False], 1, 2)
    var out = _concat_columns(a, b)
    _check_str_dict(out, [String(""), String("z")], [True, False], "pair empty dict a")
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_str_dict_col(codes, 8, "xyz", _xyz_offs(), _no_nulls(3), 2, 1)))
    batches.append(_batch(_str_dict_col(codes, 8, "xyz", _xyz_offs(), _no_nulls(3), 1, 0)))
    var out2 = concat_record_batches_nway_ref(batches)
    _check_str_dict(out2.column_at(0), [String("z")], _no_nulls(1), "nway empty dict b")


def main() raises:
    var t = TestSuite()
    t.test[test_pairwise_identical_dict_keeps_nulls]()
    t.test[test_nway_identical_dict_sliced_with_nulls]()
    t.test[test_pairwise_identical_dict_sliced]()
    t.test[test_pairwise_int64_indices_factory]()
    t.test[test_nway_int64_indices_sliced_with_nulls]()
    t.test[test_pairwise_int64_indices_remap_sliced]()
    t.test[test_pairwise_remap_int32_sliced_with_nulls]()
    t.test[test_pairwise_same_bytes_different_offsets_is_not_identical]()
    t.test[test_nway_same_bytes_different_offsets_is_not_identical]()
    t.test[test_pairwise_empty_entry_dictionary_without_buffer_is_not_x]()
    t.test[test_nway_empty_entry_dictionary_without_buffer_is_not_x]()
    t.test[test_pairwise_identical_dict_null_slot_issue_repro]()
    t.test[test_mixed_code_widths_are_refused]()
    t.test[test_int8_int16_code_widths_are_refused]()
    t.test[test_pairwise_numeric_dict_keeps_value_dtype]()
    t.test[test_nway_numeric_dict_keeps_value_dtype]()
    t.test[test_numeric_value_dtypes_that_differ_are_refused]()
    t.test[test_string_and_numeric_dictionaries_are_refused]()
    t.test[test_empty_dict_slices]()
    t^.run()
