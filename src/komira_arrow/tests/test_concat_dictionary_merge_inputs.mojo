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
    codes: List[Int], dict_data: String, dict_offs: List[Int], nulls: List[Bool]
) raises -> Column[HeapRegion]:
    var n = len(codes)
    var buf = OwnedAlignedBuffer(max(n * 4, 1))
    buf.set_length(Int64(n * 4))
    for i in range(n):
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
    assert_equal(_dict_str_at(out, 3), "w", "row 3")


def test_remap_refuses_a_non_null_code_past_the_dictionary() raises:
    var a = _str_dict_col([0], "xyz", [0, 1, 2, 3], _no_nulls(1))
    var b = _str_dict_col([0, 5], "zw", [0, 1, 2], _no_nulls(2))
    var raised = False
    try:
        _ = _concat_columns(a, b)
    except:
        raised = True
    assert_true(raised, "a non-null code past the dictionary must raise")


def test_dictionary_without_data_buffer_is_refused() raises:
    var a = _str_dict_col([0, 1], "xy", [0, 1, 2], _no_nulls(2))
    a._dict_data = None
    var b = _str_dict_col([0], "zwv", [0, 1, 2, 3], _no_nulls(1))
    var raised = False
    try:
        _ = _concat_columns(a, b)
    except:
        raised = True
    assert_true(raised, "a dictionary claiming 2 entries with no data must raise")


def main() raises:
    var t = TestSuite()
    t.test[test_pairwise_numeric_dicts_with_different_values_merge]()
    t.test[test_nway_numeric_dicts_with_different_values_merge]()
    t.test[test_remap_does_not_look_up_codes_under_null_slots]()
    t.test[test_remap_refuses_a_non_null_code_past_the_dictionary]()
    t.test[test_dictionary_without_data_buffer_is_refused]()
    t^.run()
