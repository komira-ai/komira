# =============================================================================
# Tests for the STRING / BINARY sort kernel
# =============================================================================
#
# Covers:
#   - Single-key STRING sort: ascending / descending / stability / unicode bytes
#   - Multi-key STRING sort via sort_batch_by_keys (lexicographic over 2 keys)
#   - Empty / single-row edge cases
#   - NULL handling: Arrow convention (NULLS FIRST asc, NULLS LAST desc)
#   - Sliced batch (verify _offset propagation)
#   - BINARY parity with STRING
#   - An unsupported key type raises with a descriptive error
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_arrow.binary_array import BinaryArray
from komira_op_sort.sort_string import sort_indices_string
from komira_op_sort.sort_topn_sink import _execute_sort_sink
from komira_op_sort.sort_multi import sort_batch_by_keys
from komira_physical_plan.physical_plan import SortSinkData
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Builders
# =============================================================================


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _str_col_nullable(
    values: List[String], valid_flags: List[Bool],
) raises -> Column[HeapRegion]:
    """Build a STRING column with an explicit validity bitmap.

    `values[i]` is a placeholder for null rows (length-zero strings); the
    bitmap drives null-detection. Mirrors how the parquet decoder produces
    nullable STRING columns post-late-mat.

    Manually constructs offsets+data buffers to avoid partial-moving fields
    out of a StringArray (RFC v4.2 banned pattern).
    """
    var n = len(values)
    var int32_size = 4

    # Pre-compute total data bytes.
    var total_bytes = 0
    for i in range(n):
        total_bytes += values[i].byte_length()

    # Allocate offsets buffer (n+1 entries of Int32).
    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    var off_ptr = offsets_buf.view_typed_mut[DType.int32]()
    (off_ptr + 0).init_pointee_copy(Int32(0))

    # Allocate data buffer.
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var data_ptr = data_buf.view_typed_mut[DType.uint8]()

    var offset = 0
    for i in range(n):
        var s = values[i]
        var s_len = s.byte_length()
        if s_len > 0:
            var s_ptr = s.unsafe_ptr().bitcast[UInt8]()
            for k in range(s_len):
                (data_ptr + offset + k).init_pointee_copy((s_ptr + k)[])
        offset += s_len
        (off_ptr + i + 1).init_pointee_copy(Int32(offset))
    offsets_buf.set_length(Int64((n + 1) * int32_size))

    data_buf.set_length(Int64(total_bytes))


    # Build validity bitmap from valid_flags (1 = valid, 0 = null).
    var bm = Bitmap.create(n)
    var null_count = 0
    for i in range(n):
        if valid_flags[i]:
            bm.set(i)
        else:
            null_count += 1

    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=bm^,
        length=n,
        null_count=null_count,
        offset=0,
    )


def _i64_col(values: List[Int64]) -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return Column.from_primitive[DType.int64](arr^)


def _str_at(col: Column[HeapRegion], row: Int) raises -> String:
    var sa = col.as_string()
    return sa.get(row)


def _i64_at(col: Column[HeapRegion], row: Int) raises -> Int64:
    var arr = col.as_primitive[DType.int64]()
    return arr.get(row)


# =============================================================================
# Test 1 — single-key STRING sort, ascending
# =============================================================================


def test_sort_string_ascending() raises:
    """Lex-ascending sort over plain ASCII strings."""
    var values: List[String] = ["banana", "apple", "cherry"]
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 3)

    # Expected order: apple, banana, cherry -> indices [1, 0, 2]
    assert_equal(Int(indices.get(0)), 1)
    assert_equal(Int(indices.get(1)), 0)
    assert_equal(Int(indices.get(2)), 2)


# =============================================================================
# Test 2 — single-key STRING sort, descending
# =============================================================================


def test_sort_string_descending() raises:
    """Lex-descending sort over plain ASCII strings."""
    var values: List[String] = ["banana", "apple", "cherry"]
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=True)
    assert_equal(indices.length, 3)

    # Expected order: cherry, banana, apple -> indices [2, 0, 1]
    assert_equal(Int(indices.get(0)), 2)
    assert_equal(Int(indices.get(1)), 0)
    assert_equal(Int(indices.get(2)), 1)


# =============================================================================
# Test 3 — empty input
# =============================================================================


def test_sort_string_empty() raises:
    """Empty STRING column produces empty index array."""
    var values = List[String]()
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 0)


# =============================================================================
# Test 4 — single row
# =============================================================================


def test_sort_string_single_row() raises:
    """Single-row STRING column produces [0]."""
    var values: List[String] = ["solo"]
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 1)
    assert_equal(Int(indices.get(0)), 0)


# =============================================================================
# Test 5 — stability (equal keys preserve original order)
# =============================================================================


def test_sort_string_stability() raises:
    """Equal STRING keys retain original (lower-index-first) order."""
    # Three groups (A, B, C); within each group the original-row order
    # must be preserved post-sort.
    var values: List[String] = ["B", "A", "B", "A", "C", "B"]
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 6)

    # Expected: A_at_1, A_at_3, B_at_0, B_at_2, B_at_5, C_at_4
    assert_equal(Int(indices.get(0)), 1)
    assert_equal(Int(indices.get(1)), 3)
    assert_equal(Int(indices.get(2)), 0)
    assert_equal(Int(indices.get(3)), 2)
    assert_equal(Int(indices.get(4)), 5)
    assert_equal(Int(indices.get(5)), 4)


# =============================================================================
# Test 6 — Q4 5-priority shape
# =============================================================================


def test_sort_string_q4_priorities() raises:
    """Sorts the actual TPC-H Q4 priority strings."""
    var values: List[String] = [
        "3-MEDIUM",
        "1-URGENT",
        "5-LOW",
        "2-HIGH",
        "4-NOT SPECIFIED",
    ]
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=False)

    # Expected order: 1-URGENT, 2-HIGH, 3-MEDIUM, 4-NOT SPECIFIED, 5-LOW
    assert_equal(Int(indices.get(0)), 1)
    assert_equal(Int(indices.get(1)), 3)
    assert_equal(Int(indices.get(2)), 0)
    assert_equal(Int(indices.get(3)), 4)
    assert_equal(Int(indices.get(4)), 2)


# =============================================================================
# Test 7 — length-tiebreak (prefix sorts before longer)
# =============================================================================


def test_sort_string_length_tiebreak() raises:
    """When one string is a prefix of another, shorter sorts first."""
    var values: List[String] = ["app", "apple", "ap"]
    var col = _str_col(values)
    var indices = sort_indices_string(col, descending=False)

    # Expected: ap (idx 2), app (idx 0), apple (idx 1)
    assert_equal(Int(indices.get(0)), 2)
    assert_equal(Int(indices.get(1)), 0)
    assert_equal(Int(indices.get(2)), 1)


# =============================================================================
# Test 8 — null handling: NULLS FIRST ascending
# =============================================================================


def test_sort_string_nulls_ascending() raises:
    """Arrow convention: NULLS FIRST when ascending."""
    # Rows 1 and 3 are null.
    var values: List[String] = ["banana", "", "apple", "", "cherry"]
    var valid: List[Bool] = [True, False, True, False, True]
    var col = _str_col_nullable(values, valid)
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 5)

    # First two outputs must be the null rows (in some stable order).
    var first = Int(indices.get(0))
    var second = Int(indices.get(1))
    assert_true(first == 1 or first == 3)
    assert_true(second == 1 or second == 3)
    assert_true(first != second)
    # Null rows stable: 1 before 3.
    assert_equal(first, 1)
    assert_equal(second, 3)
    # Then valid rows in lex order: apple (2), banana (0), cherry (4).
    assert_equal(Int(indices.get(2)), 2)
    assert_equal(Int(indices.get(3)), 0)
    assert_equal(Int(indices.get(4)), 4)


# =============================================================================
# Test 9 — null handling: NULLS LAST descending
# =============================================================================


def test_sort_string_nulls_descending() raises:
    """Arrow convention: NULLS LAST when descending."""
    var values: List[String] = ["banana", "", "apple", "", "cherry"]
    var valid: List[Bool] = [True, False, True, False, True]
    var col = _str_col_nullable(values, valid)
    var indices = sort_indices_string(col, descending=True)
    assert_equal(indices.length, 5)

    # First three outputs must be valid rows in reverse lex order:
    # cherry (4), banana (0), apple (2).
    assert_equal(Int(indices.get(0)), 4)
    assert_equal(Int(indices.get(1)), 0)
    assert_equal(Int(indices.get(2)), 2)
    # Then nulls (stable: 1, 3).
    assert_equal(Int(indices.get(3)), 1)
    assert_equal(Int(indices.get(4)), 3)


# =============================================================================
# Test 9b — explicit NULLS placement override
# =============================================================================


def test_sort_string_nulls_placement_override() raises:
    """An explicit `nulls_first` overrides the direction-derived NULL
    placement: `ASC NULLS LAST` and `DESC NULLS FIRST` are both reachable."""
    var values: List[String] = ["banana", "", "apple", "", "cherry"]
    var valid: List[Bool] = [True, False, True, False, True]

    # ASC with explicit NULLS LAST override: valids lex-ascending first
    # (apple=2, banana=0, cherry=4), then stable nulls (1, 3) at the end.
    var col_a = _str_col_nullable(values, valid)
    var asc_nulls_last = sort_indices_string(
        col_a, descending=False, nulls_first=Optional(False)
    )
    assert_equal(asc_nulls_last.length, 5)
    assert_equal(Int(asc_nulls_last.get(0)), 2)
    assert_equal(Int(asc_nulls_last.get(1)), 0)
    assert_equal(Int(asc_nulls_last.get(2)), 4)
    assert_equal(Int(asc_nulls_last.get(3)), 1)
    assert_equal(Int(asc_nulls_last.get(4)), 3)

    # DESC with explicit NULLS FIRST override: stable nulls (1, 3) first,
    # then valids reverse-lex (cherry=4, banana=0, apple=2).
    var col_d = _str_col_nullable(values, valid)
    var desc_nulls_first = sort_indices_string(
        col_d, descending=True, nulls_first=Optional(True)
    )
    assert_equal(desc_nulls_first.length, 5)
    assert_equal(Int(desc_nulls_first.get(0)), 1)
    assert_equal(Int(desc_nulls_first.get(1)), 3)
    assert_equal(Int(desc_nulls_first.get(2)), 4)
    assert_equal(Int(desc_nulls_first.get(3)), 0)
    assert_equal(Int(desc_nulls_first.get(4)), 2)


def test_sort_string_nulls_default_unchanged() raises:
    """With no `nulls_first` argument, ASC puts NULLs first and DESC puts
    them last."""
    var values: List[String] = ["banana", "", "apple", "", "cherry"]
    var valid: List[Bool] = [True, False, True, False, True]
    var col = _str_col_nullable(values, valid)
    # Default (no nulls_first arg) == ASC NULLS FIRST, same as Test 8.
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 5)
    assert_equal(Int(indices.get(0)), 1)
    assert_equal(Int(indices.get(1)), 3)
    assert_equal(Int(indices.get(2)), 2)
    assert_equal(Int(indices.get(3)), 0)
    assert_equal(Int(indices.get(4)), 4)


# =============================================================================
# Test 10 — sliced batch: _offset propagation
# =============================================================================


def test_sort_string_slice_offset() raises:
    """Verifies the kernel honors Column._offset for sliced batches.

    Builds a 6-element STRING column representing rows from a parent
    batch of 6 rows where the logical view starts at row 2 (offset=2,
    length=4). The kernel must skip the first 2 rows when reading
    offsets[].
    """
    # Underlying buffer has 6 rows, but the logical column is rows 2..6.
    var all_values: List[String] = ["zz_skip0", "zz_skip1", "delta", "alpha", "charlie", "bravo"]
    var n_total = len(all_values)
    var int32_size = 4

    # Build offsets+data buffers manually (avoids StringArray partial-move).
    var total_bytes = 0
    for i in range(n_total):
        total_bytes += all_values[i].byte_length()
    var offsets_buf = OwnedAlignedBuffer((n_total + 1) * int32_size)
    var off_ptr = offsets_buf.view_typed_mut[DType.int32]()
    (off_ptr + 0).init_pointee_copy(Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var data_ptr = data_buf.view_typed_mut[DType.uint8]()
    var offset = 0
    for i in range(n_total):
        var s = all_values[i]
        var s_len = s.byte_length()
        if s_len > 0:
            var s_ptr = s.unsafe_ptr().bitcast[UInt8]()
            for k in range(s_len):
                (data_ptr + offset + k).init_pointee_copy((s_ptr + k)[])
        offset += s_len
        (off_ptr + i + 1).init_pointee_copy(Int32(offset))
    offsets_buf.set_length(Int64((n_total + 1) * int32_size))

    data_buf.set_length(Int64(total_bytes))


    # Sliced Column: offset=2, length=4 -> logical view [delta, alpha, charlie, bravo].
    var sliced_col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=Optional[Bitmap[HeapRegion]](None),
        length=4,
        null_count=0,
        offset=2,
    )

    var indices = sort_indices_string(sliced_col, descending=False)
    assert_equal(indices.length, 4)
    # Expected lex order (within the 4 logical rows starting at offset 2):
    #   alpha (logical row 1), bravo (logical row 3), charlie (logical row 2),
    #   delta (logical row 0)
    assert_equal(Int(indices.get(0)), 1)
    assert_equal(Int(indices.get(1)), 3)
    assert_equal(Int(indices.get(2)), 2)
    assert_equal(Int(indices.get(3)), 0)


# =============================================================================
# Test 11 — BINARY parity with STRING
# =============================================================================


def test_sort_binary_ascending() raises:
    """BINARY column sorts byte-wise via the same kernel."""
    var values: List[List[UInt8]] = [
        [UInt8(2), UInt8(1)],
        [UInt8(1), UInt8(0)],
        [UInt8(2), UInt8(0)],
    ]
    var ba = BinaryArray.from_bytes_list(values)
    var col = Column.from_binary(ba^)
    var indices = sort_indices_string(col, descending=False)
    assert_equal(indices.length, 3)
    # Lex byte order: [1,0], [2,0], [2,1] -> indices [1, 2, 0].
    assert_equal(Int(indices.get(0)), 1)
    assert_equal(Int(indices.get(1)), 2)
    assert_equal(Int(indices.get(2)), 0)


# =============================================================================
# Test 12 — full _execute_sort_sink path (single-key STRING)
# =============================================================================


def test_sort_sink_single_key_string() raises:
    """Drives the SortSink dispatch for a single STRING key.

    Mirrors how the morsel executor invokes _sort_batch_single_key.
    """
    var values: List[String] = [
        "3-MEDIUM",
        "1-URGENT",
        "5-LOW",
        "2-HIGH",
        "4-NOT SPECIFIED",
    ]
    var col = _str_col(values)

    var sb = SchemaBuilder()
    sb.add_field(Field("p", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(col^)
    var batch = rb.build(sb.build())

    var keys = List[String]()
    keys.append("p")
    var desc = List[Bool]()
    desc.append(False)
    var sink_data = SortSinkData(keys^, desc^, 0)

    var sorted = _execute_sort_sink(batch^, sink_data)
    assert_equal(sorted.num_rows(), 5)

    assert_equal(_str_at(sorted.column_at(0), 0), String("1-URGENT"))
    assert_equal(_str_at(sorted.column_at(0), 1), String("2-HIGH"))
    assert_equal(_str_at(sorted.column_at(0), 2), String("3-MEDIUM"))
    assert_equal(_str_at(sorted.column_at(0), 3), String("4-NOT SPECIFIED"))
    assert_equal(_str_at(sorted.column_at(0), 4), String("5-LOW"))


# =============================================================================
# Test 13 — multi-key sort: STRING primary + INT64 secondary
# =============================================================================


def test_sort_multi_key_string_then_int64() raises:
    """sort_batch_by_keys with a STRING primary and INT64 secondary key."""
    var prio: List[String] = ["B", "A", "B", "A", "B"]
    var num: List[Int64] = [Int64(20), Int64(30), Int64(10), Int64(10), Int64(20)]

    var sb = SchemaBuilder()
    sb.add_field(Field("p", ArrowType.STRING, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_str_col(prio))
    rb.add_column(_i64_col(num))
    var batch = rb.build(sb.build())

    var keys = List[String]()
    keys.append("p")
    keys.append("n")
    var desc = List[Bool]()
    desc.append(False)
    desc.append(False)

    var sorted = sort_batch_by_keys(batch^, keys, desc)
    assert_equal(sorted.num_rows(), 5)
    # Expected:
    #   (A, 10) at original row 3
    #   (A, 30) at original row 1
    #   (B, 10) at original row 2
    #   (B, 20) at original row 0  (stable tie on key 'n' with row 4)
    #   (B, 20) at original row 4
    assert_equal(_str_at(sorted.column_at(0), 0), String("A"))
    assert_equal(Int(_i64_at(sorted.column_at(1), 0)), 10)
    assert_equal(_str_at(sorted.column_at(0), 1), String("A"))
    assert_equal(Int(_i64_at(sorted.column_at(1), 1)), 30)
    assert_equal(_str_at(sorted.column_at(0), 2), String("B"))
    assert_equal(Int(_i64_at(sorted.column_at(1), 2)), 10)
    assert_equal(_str_at(sorted.column_at(0), 3), String("B"))
    assert_equal(Int(_i64_at(sorted.column_at(1), 3)), 20)
    assert_equal(_str_at(sorted.column_at(0), 4), String("B"))
    assert_equal(Int(_i64_at(sorted.column_at(1), 4)), 20)


# =============================================================================
# Test 14 — fail-loud for the SDK->engine NULL pseudo-type
# =============================================================================


def test_sort_string_dispatch_fail_loud_unknown_type() raises:
    """An unsupported key type raises with a descriptive error: feeding a
    non-STRING/BINARY column to the string kernel names the type."""
    var col = _i64_col([Int64(1), Int64(2)])  # INT64 is fine for the kernel
    # But sort_indices_string itself rejects INT64.
    var raised = False
    try:
        var _idx = sort_indices_string(col, descending=False)
    except err:
        raised = True
        var msg = String(err)
        assert_true("unsupported arrow_type" in msg)
    assert_true(raised)


# =============================================================================
# Suite registration
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
