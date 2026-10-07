# =============================================================================
# Tests for Dict-Aware Filter Evaluation
# =============================================================================
#
# Test strategy:
#   Build a StringDictionaryArray with known dictionary values and indices.
#   Run dict_filter_eval with each operator type and verify correctness
#   against the expected row selections.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_column_kernels.dict_filter import DictFilterOp, dict_filter_eval, dict_filter_eval_bool_mask
from std.sys import size_of
from std.memory import unsafe_memcpy


def _build_test_dict_array() raises -> StringDictionaryArray:
    """Build a test StringDictionaryArray.

    Dictionary: ["apple", "banana", "cherry", "date"]
    Indices:    [0, 1, 2, 3, 0, 1, 2, 3, 0, 1]

    So the logical values are:
      row 0: apple
      row 1: banana
      row 2: cherry
      row 3: date
      row 4: apple
      row 5: banana
      row 6: cherry
      row 7: date
      row 8: apple
      row 9: banana
    """
    # Build dictionary StringArray.
    var strings: List[String] = ["apple", "banana", "cherry", "date"]
    var total_data_bytes = 0
    for i in range(len(strings)):
        total_data_bytes += strings[i].byte_length()

    comptime int32_size = size_of[Int32]()
    var dict_off_bytes = (len(strings) + 1) * int32_size
    var dict_offsets = OwnedAlignedBuffer(dict_off_bytes)
    var dict_data = OwnedAlignedBuffer(total_data_bytes)
    var off_ptr = dict_offsets.view_typed_mut[DType.int32]()
    var write_pos = 0
    (off_ptr + 0)[] = Int32(0)
    for i in range(len(strings)):
        var s = strings[i]
        var s_len = s.byte_length()
        if s_len > 0:
            var s_ptr = s.as_c_string_slice().unsafe_ptr()
            unsafe_memcpy(
                dest=dict_data.view_typed_mut[DType.uint8]() + write_pos,
                src=UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(s_ptr)),
                count=s_len,
            )
        write_pos += s_len
        (off_ptr + i + 1)[] = Int32(write_pos)
    dict_offsets.set_length(Int64(dict_off_bytes))

    dict_data.set_length(Int64(total_data_bytes))


    var dict_arr = StringArray(dict_offsets^, dict_data^, None, len(strings), 0, 0)

    # Build indices: [0, 1, 2, 3, 0, 1, 2, 3, 0, 1]
    var num_rows = 10
    var indices = PrimitiveArray[DType.int32].allocate(num_rows)
    var idx_ptr = indices._typed_ptr_mut()
    for i in range(num_rows):
        (idx_ptr + i)[] = Scalar[DType.int32](i % 4)

    return StringDictionaryArray.from_parts(indices^, dict_arr^)


def test_dict_filter_eq() raises:
    """EQ: 'banana' matches rows 1, 5, 9."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.EQ, "banana")

    assert_equal(sel.length(), 3)
    var ptr = sel.indices._typed_ptr_mut()
    assert_equal(Int((ptr + 0)[]), 1)
    assert_equal(Int((ptr + 1)[]), 5)
    assert_equal(Int((ptr + 2)[]), 9)


def test_dict_filter_ne() raises:
    """NE: != 'apple' matches rows 1,2,3,5,6,7,9 (7 rows)."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.NE, "apple")

    assert_equal(sel.length(), 7)
    var ptr = sel.indices._typed_ptr_mut()
    # apple is at rows 0, 4, 8 -- so NE excludes them
    assert_equal(Int((ptr + 0)[]), 1)
    assert_equal(Int((ptr + 1)[]), 2)
    assert_equal(Int((ptr + 2)[]), 3)
    assert_equal(Int((ptr + 3)[]), 5)
    assert_equal(Int((ptr + 4)[]), 6)
    assert_equal(Int((ptr + 5)[]), 7)
    assert_equal(Int((ptr + 6)[]), 9)


def test_dict_filter_lt() raises:
    """LT: < 'cherry' matches 'apple' and 'banana' -> rows 0,1,4,5,8,9."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.LT, "cherry")

    assert_equal(sel.length(), 6)
    var ptr = sel.indices._typed_ptr_mut()
    assert_equal(Int((ptr + 0)[]), 0)  # apple
    assert_equal(Int((ptr + 1)[]), 1)  # banana
    assert_equal(Int((ptr + 2)[]), 4)  # apple
    assert_equal(Int((ptr + 3)[]), 5)  # banana
    assert_equal(Int((ptr + 4)[]), 8)  # apple
    assert_equal(Int((ptr + 5)[]), 9)  # banana


def test_dict_filter_ge() raises:
    """GE: >= 'cherry' matches 'cherry' and 'date' -> rows 2,3,6,7."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.GE, "cherry")

    assert_equal(sel.length(), 4)
    var ptr = sel.indices._typed_ptr_mut()
    assert_equal(Int((ptr + 0)[]), 2)
    assert_equal(Int((ptr + 1)[]), 3)
    assert_equal(Int((ptr + 2)[]), 6)
    assert_equal(Int((ptr + 3)[]), 7)


def test_dict_filter_no_match() raises:
    """EQ on a value not in the dictionary returns empty selection."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.EQ, "fig")

    assert_equal(sel.length(), 0)


def test_dict_filter_all_match() raises:
    """GE on a value smaller than all entries matches all rows."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.GE, "a")

    assert_equal(sel.length(), 10)


def test_dict_filter_bool_mask() raises:
    """Bool mask variant returns correct BooleanArray."""
    var arr = _build_test_dict_array()
    var mask = dict_filter_eval_bool_mask(arr, DictFilterOp.EQ, "apple")

    assert_equal(mask.length, 10)
    # apple is at rows 0, 4, 8
    assert_true(mask.get(0))
    assert_false(mask.get(1))
    assert_false(mask.get(2))
    assert_false(mask.get(3))
    assert_true(mask.get(4))
    assert_false(mask.get(5))
    assert_false(mask.get(6))
    assert_false(mask.get(7))
    assert_true(mask.get(8))
    assert_false(mask.get(9))


def test_dict_filter_gt() raises:
    """GT: > 'banana' matches 'cherry' and 'date' -> rows 2,3,6,7."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.GT, "banana")

    assert_equal(sel.length(), 4)
    var ptr = sel.indices._typed_ptr_mut()
    assert_equal(Int((ptr + 0)[]), 2)
    assert_equal(Int((ptr + 1)[]), 3)
    assert_equal(Int((ptr + 2)[]), 6)
    assert_equal(Int((ptr + 3)[]), 7)


def test_dict_filter_le() raises:
    """LE: <= 'banana' matches 'apple' and 'banana' -> 6 rows."""
    var arr = _build_test_dict_array()
    var sel = dict_filter_eval(arr, DictFilterOp.LE, "banana")

    assert_equal(sel.length(), 6)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
