# Dictionary encoding of string columns (`dict_encoder`) and of numeric
# columns (`dict_encoder_numeric`), on small inputs below every sampling gate.
#
# What each test proves, and the defect it catches:
#   * duplicates / unique values / single / all-unique / empty: indices are
#     first-seen order and the dictionary holds each distinct string once
#     (a table that hashed prefixes, or compared lengths only, merges
#     "ab"/"ba" or "a"/"aa" and fails test_distinct_strings_never_merge).
#   * large_string: the Int64-offset twin gives the same answer.
#   * the pre-estimate does not fire under DICT_PREESTIMATE_MIN_ROWS: a
#     4,095-row all-unique column is still dictionary-encoded in full.
#   * numeric: -0.0 and +0.0 are two entries and each row reads back its
#     own sign bit (a canonicalising key writes the first-seen zero for
#     both); NaN payloads survive; null rows get index 0 and add nothing.
#   * numeric cardinality cap: NUMERIC_DICT_MAX_CARDINALITY + 1 distinct
#     values abandon (success False), exactly the cap is kept.
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_parquet_writer.dict_encoder import (
    DICT_PREESTIMATE_MIN_ROWS,
    encode_dict_column,
    encode_dict_column_large,
)
from komira_parquet_writer.dict_encoder_numeric import (
    NUMERIC_DICT_MAX_CARDINALITY,
    encode_numeric_dict_column,
)


def _indices(result_indices: PrimitiveArray[DType.int32]) raises -> List[Int]:
    var out = List[Int]()
    for i in range(result_indices.length):
        out.append(Int(result_indices.get(i)))
    return out^


def _assert_ints(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": [" + String(i) + "]")


def test_duplicates_first_seen_order() raises:
    var strs: List[String] = ["apple", "banana", "apple", "cherry", "banana"]
    var result = encode_dict_column(StringArray.from_strings(strs))
    assert_true(result.success)
    _assert_ints(_indices(result.indices), [0, 1, 0, 2, 1], "indices")
    assert_equal(result.dictionary.length, 3)
    assert_equal(result.dictionary.get(0), "apple")
    assert_equal(result.dictionary.get(1), "banana")
    assert_equal(result.dictionary.get(2), "cherry")


def test_single_and_all_unique() raises:
    var same: List[String] = ["hello", "hello", "hello"]
    var r1 = encode_dict_column(StringArray.from_strings(same))
    assert_equal(r1.dictionary.length, 1)
    _assert_ints(_indices(r1.indices), [0, 0, 0], "single")
    var uniq: List[String] = ["a", "b", "c", "d"]
    var r2 = encode_dict_column(StringArray.from_strings(uniq))
    assert_equal(r2.dictionary.length, 4)
    _assert_ints(_indices(r2.indices), [0, 1, 2, 3], "all unique")


def test_distinct_strings_never_merge() raises:
    # Same length / same bytes in another order / a prefix / the empty string.
    var strs: List[String] = ["ab", "ba", "a", "aa", "", "ab", ""]
    var result = encode_dict_column(StringArray.from_strings(strs))
    _assert_ints(_indices(result.indices), [0, 1, 2, 3, 4, 0, 4], "indices")
    assert_equal(result.dictionary.length, 5)
    assert_equal(result.dictionary.get(3), "aa")
    assert_equal(result.dictionary.get(4), "")


def test_empty_input() raises:
    var strs: List[String] = []
    var result = encode_dict_column(StringArray.from_strings(strs))
    assert_true(result.success)
    assert_equal(result.indices.length, 0)
    assert_equal(result.dictionary.length, 0)


def test_large_string_twin_matches() raises:
    var strs: List[String] = ["x", "yy", "x", "zzz", "yy"]
    var narrow = encode_dict_column(StringArray.from_strings(strs))
    var wide = encode_dict_column_large(LargeStringArray.from_strings(strs))
    assert_true(wide.success)
    _assert_ints(_indices(wide.indices), _indices(narrow.indices), "indices")
    assert_equal(wide.dictionary.length, narrow.dictionary.length)
    for i in range(wide.dictionary.length):
        assert_equal(wide.dictionary.get(i), narrow.dictionary.get(i))


def test_small_all_unique_column_is_never_abandoned() raises:
    # Below DICT_PREESTIMATE_MIN_ROWS the HLL gate is not consulted, so a
    # column that would look near-unique is still encoded in full.
    var strs = List[String]()
    for i in range(DICT_PREESTIMATE_MIN_ROWS - 1):
        strs.append(String("v") + String(i))
    var result = encode_dict_column(StringArray.from_strings(strs))
    assert_true(result.success)
    assert_equal(result.dictionary.length, DICT_PREESTIMATE_MIN_ROWS - 1)


def test_large_all_unique_column_is_abandoned_up_front() raises:
    # Above the gate a near-unique column is refused before the build.
    var strs = List[String]()
    for i in range(DICT_PREESTIMATE_MIN_ROWS * 2):
        strs.append(String("row-") + String(i * 7919))
    var result = encode_dict_column(StringArray.from_strings(strs))
    assert_false(result.success)
    assert_equal(result.indices.length, 0)


# --- numeric ----------------------------------------------------------------


def test_numeric_signed_zero_is_lossless() raises:
    var neg_zero = bitcast[DType.float64, 1](UInt64(1) << 63)
    var arr = PrimitiveArray[DType.float64].allocate(5)
    arr.set(0, neg_zero)
    arr.set(1, 1.5)
    arr.set(2, -2.5)
    arr.set(3, Float64(0))
    arr.set(4, neg_zero)
    var result = encode_numeric_dict_column[DType.float64](arr)
    assert_true(result.success)
    assert_equal(len(result.dict_values), 4, "-0.0 and +0.0 are two entries")
    _assert_ints(_indices(result.indices), [0, 1, 2, 3, 0], "indices")
    for i in range(5):
        var code = Int(result.indices.get(i))
        assert_equal(
            UInt64(result.dict_values[code].to_bits()),
            UInt64(arr.get(i).to_bits()),
            "row " + String(i) + " reads back its own bits",
        )


def test_numeric_nan_payloads_survive() raises:
    var a = bitcast[DType.float32, 1](UInt32(0x7FC00001))
    var b = bitcast[DType.float32, 1](UInt32(0xFFC00002))
    var arr = PrimitiveArray[DType.float32].allocate(3)
    arr.set(0, a)
    arr.set(1, b)
    arr.set(2, a)
    var result = encode_numeric_dict_column[DType.float32](arr)
    assert_equal(len(result.dict_values), 2)
    assert_equal(Int(result.dict_values[0].to_bits()), 0x7FC00001)
    assert_equal(Int(result.dict_values[1].to_bits()), 0xFFC00002)


def test_numeric_nulls_get_index_zero() raises:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(4)
    arr.set(0, 7)
    arr.set(1, 99)
    arr.set(2, 8)
    arr.set(3, 7)
    arr._set_null(1)
    var result = encode_numeric_dict_column[DType.int32](arr)
    assert_equal(len(result.dict_values), 2, "the null row's 99 is not a value")
    _assert_ints(_indices(result.indices), [0, 0, 1, 0], "indices")


def test_numeric_cardinality_cap() raises:
    var at_cap = PrimitiveArray[DType.int64].allocate(NUMERIC_DICT_MAX_CARDINALITY)
    for i in range(NUMERIC_DICT_MAX_CARDINALITY):
        at_cap.set(i, Int64(i))
    var kept = encode_numeric_dict_column[DType.int64](at_cap)
    assert_true(kept.success, "exactly the cap is kept")
    assert_equal(len(kept.dict_values), NUMERIC_DICT_MAX_CARDINALITY)
    var over = PrimitiveArray[DType.int64].allocate(NUMERIC_DICT_MAX_CARDINALITY + 1)
    for i in range(NUMERIC_DICT_MAX_CARDINALITY + 1):
        over.set(i, Int64(i))
    var dropped = encode_numeric_dict_column[DType.int64](over)
    assert_false(dropped.success, "one past the cap is abandoned")
    assert_equal(len(dropped.dict_values), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
