# =============================================================================
# Regression test: scalar-String lifetime in eval_string_* and dict_filter_*
# =============================================================================
#
# Guards against the Q3 nondeterminism bug:
#
# An earlier revision of eval/string_comparison.mojo and eval/dict_filter.mojo
# extracted a raw pointer into a stack-local `String` via
# `unsafe_from_address=Int(val.as_c_string_slice().unsafe_ptr())`. Laundering
# the pointer through `unsafe_from_address=Int(...)` detaches it from the
# compiler's lifetime tracking, so the String could be destroyed before the
# per-row comparison loop dereferenced the pointer. Small strings live in
# stack SSO slots that are immediately reused, so reads through the dangling
# pointer returned whatever bytes happened to be there — leading to different
# filter counts on repeated calls against identical data. Observed as
# TPC-H Q3's top-row revenue flipping between runs on the same file.
#
# This test calls the filter APIs many times in a row with scalar string
# values that sit on the stack and that would have been vulnerable to the
# old pattern. We interleave additional stack-local String constructions
# between calls to maximise stack churn. Every call must return the
# byte-identical result.
#
# If the lifetime bug regresses, we expect counts / bool-mask bit patterns
# to drift between iterations.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from std.sys import size_of
from std.memory import unsafe_memcpy

from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_column_kernels.string_comparison import (
    eval_string_eq, eval_string_ne, eval_string_gt, eval_string_lt,
    eval_string_ge, eval_string_le,
)
from komira_column_kernels.dict_filter import (
    DictFilterOp, dict_filter_eval, dict_filter_eval_bool_mask,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _count_true(mask: BooleanArray) raises -> Int:
    """Count the number of True bits in a BooleanArray."""
    var count = 0
    for i in range(mask.length):
        if mask.get(i):
            count += 1
    return count


def _churn_the_stack() raises -> Int:
    """Do work that creates and destroys several stack-local Strings.

    This is intentionally noisy — the point is to reuse the stack slots that
    `eval_string_*` used during the previous call. If the scalar bytes were
    not properly copied to a heap buffer, a later filter call reading
    through the dangling pointer would see these strings instead of the
    one the caller actually passed.
    """
    var garbage0 = String("XXXX" * 8)
    var garbage1 = String("YYYY" * 8)
    var garbage2 = String("ZZZZ" * 8)
    var garbage3 = String("0000" * 8)
    return garbage0.byte_length() + garbage1.byte_length() + garbage2.byte_length() + garbage3.byte_length()


# -----------------------------------------------------------------------------
# Test: StringArray equality stays stable across many calls
# -----------------------------------------------------------------------------


def test_eval_string_eq_stable_across_calls() raises:
    """Calling eval_string_eq with the same scalar must return identical
    bitmasks across many iterations, even with stack churn between calls.

    Uses "BUILDING" to match the exact TPC-H Q3 repro scenario.
    """
    # Build a StringArray of 1000 rows, roughly 1/5 "BUILDING" like
    # TPC-H customer.c_mktsegment. We interleave the segment values
    # deterministically so the expected count is exact.
    var segments: List[String] = [
        "BUILDING", "FURNITURE", "AUTOMOBILE", "HOUSEHOLD", "MACHINERY",
    ]
    var expected_building = 0
    var values = List[String]()
    for i in range(1000):
        var seg = segments[i % 5]
        values.append(seg)
        if seg == "BUILDING":
            expected_building += 1
    var col = StringArray.from_strings(values)

    # Warm up, then run a large number of calls with stack churn between
    # each. The result must be byte-identical every time.
    var first_count = -1
    for _ in range(64):
        _ = _churn_the_stack()
        var result = eval_string_eq(col, String("BUILDING"))
        var count = _count_true(result)
        if first_count < 0:
            first_count = count
            assert_equal(count, expected_building,
                         "first iteration count mismatch")
        else:
            assert_equal(count, first_count,
                         "eval_string_eq drifted across iterations")


def test_eval_string_ne_stable_across_calls() raises:
    """Same lifetime check for eval_string_ne."""
    var values: List[String] = [
        "apple", "banana", "cherry", "date", "apple", "banana", "cherry",
    ]
    var col = StringArray.from_strings(values)
    var first_count = -1
    for _ in range(32):
        _ = _churn_the_stack()
        var result = eval_string_ne(col, String("apple"))
        var count = _count_true(result)
        if first_count < 0:
            first_count = count
        else:
            assert_equal(count, first_count,
                         "eval_string_ne drifted across iterations")


def test_eval_string_lt_stable_across_calls() raises:
    """Same lifetime check for eval_string_lt (lexicographic)."""
    var values: List[String] = ["aa", "ab", "ba", "bb", "ca", "cb", "da"]
    var col = StringArray.from_strings(values)
    var first_count = -1
    for _ in range(32):
        _ = _churn_the_stack()
        var result = eval_string_lt(col, String("bb"))
        var count = _count_true(result)
        if first_count < 0:
            first_count = count
        else:
            assert_equal(count, first_count,
                         "eval_string_lt drifted across iterations")


# -----------------------------------------------------------------------------
# Test: StringDictionaryArray filter stays stable across many calls
# -----------------------------------------------------------------------------


def _build_mktsegment_dict_array() raises -> StringDictionaryArray:
    """Build a StringDictionaryArray mirroring TPC-H customer.c_mktsegment.

    Dictionary: ["BUILDING", "FURNITURE", "AUTOMOBILE", "HOUSEHOLD", "MACHINERY"]
    Indices:    deterministic cycle of length 1000 -> 200 of each segment.
    """
    var strings: List[String] = [
        "BUILDING", "FURNITURE", "AUTOMOBILE", "HOUSEHOLD", "MACHINERY",
    ]
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
        var s_copy = strings[i]
        var s_len = s_copy.byte_length()
        if s_len > 0:
            var s_ptr = s_copy.as_c_string_slice().unsafe_ptr().bitcast[UInt8]()
            unsafe_memcpy(
                dest=dict_data.view_typed_mut[DType.uint8]() + write_pos,
                src=s_ptr,
                count=s_len,
            )
        write_pos += s_len
        (off_ptr + i + 1)[] = Int32(write_pos)
    dict_offsets.set_length(Int64(dict_off_bytes))

    dict_data.set_length(Int64(total_data_bytes))


    var dictionary = StringArray(dict_offsets^, dict_data^, None, len(strings), total_data_bytes, 0)

    var nrows = 1000
    var indices = PrimitiveArray[DType.int32].allocate(nrows)
    var idx_ptr = indices._typed_ptr_mut()
    for i in range(nrows):
        (idx_ptr + i)[] = Scalar[DType.int32](Int32(i % 5))

    return StringDictionaryArray.from_parts(indices^, dictionary^)


def test_dict_filter_eval_bool_mask_stable() raises:
    """dict_filter_eval_bool_mask must return the same bitmask across
    many calls when the inputs are unchanged.

    This is the exact code path TPC-H Q3 hits via
    `filter(col("c_mktsegment") == "BUILDING")` on a Parquet dictionary
    column. Before the fix, the scalar "BUILDING" and the internal
    dict_match list were both held through laundered raw pointers, and
    the compiler destroyed them before the per-row scan ran.
    """
    var arr = _build_mktsegment_dict_array()
    var expected = 200  # 1000 rows / 5 segments

    var first_count = -1
    for _ in range(64):
        _ = _churn_the_stack()
        var result = dict_filter_eval_bool_mask(
            arr, DictFilterOp.EQ, String("BUILDING")
        )
        var count = _count_true(result)
        if first_count < 0:
            first_count = count
            assert_equal(count, expected,
                         "first iteration count mismatch")
        else:
            assert_equal(count, first_count,
                         "dict_filter_eval_bool_mask drifted across iterations")


def test_dict_filter_eval_selection_vector_stable() raises:
    """dict_filter_eval (SelectionVector variant) must also be stable."""
    var arr = _build_mktsegment_dict_array()
    var expected = 200

    var first_len = -1
    for _ in range(64):
        _ = _churn_the_stack()
        var sv = dict_filter_eval(arr, DictFilterOp.EQ, String("FURNITURE"))
        var got_len = sv.indices.length
        if first_len < 0:
            first_len = got_len
            assert_equal(got_len, expected,
                         "first iteration SV length mismatch")
        else:
            assert_equal(got_len, first_len,
                         "dict_filter_eval drifted across iterations")


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
