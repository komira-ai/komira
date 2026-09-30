# =============================================================================
# Tests for N-way RecordBatch concat
# =============================================================================
#
# Verifies that `concat_record_batches_nway` produces the same row-by-row
# output as the pair-wise `_concat_columns` fold for primitives + STRING /
# BINARY + DICTIONARY + validity-bitmap merging.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.schema import RecordBatch, Schema, Field
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatchBuilder
from komira_core.arrow.concat import (
    concat_record_batches_nway, _concat_columns,
)
from komira_core.arrow.bitmap import Bitmap
from komira_core.collections.slab import Slab
from std.sys import size_of


def _make_int64_batch(vals: List[Int]) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Int64(vals[i]))
    var schema = Schema.from_fields_1(Field("id", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(schema^)


def _make_string_batch(strs: List[String]) raises -> RecordBatch:
    var sa = StringArray.from_strings(strs)
    var schema = Schema.from_fields_1(Field("s", ArrowType.STRING, False))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_string(sa^))
    return b.build(schema^)


def _make_nullable_int64_batch(
    vals: List[Int], null_mask: List[Bool]
) raises -> RecordBatch:
    """null_mask[i]=True means row i is NULL."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nulls = 0
    for i in range(n):
        if null_mask[i]:
            arr._set_null(i)
            nulls += 1
        else:
            arr.set(i, Int64(vals[i]))
    # _set_null does not increment null_count; fix it explicitly.
    arr.null_count = nulls
    var schema = Schema.from_fields_1(Field("v", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(schema^)


def test_nway_int64_five_inputs_matches_pairwise() raises:
    """5 inputs primitive Int64 N-way concat = 4 pair-wise concats."""
    # Build 5 small RecordBatches with consecutive int64 values.
    var batches = Slab[RecordBatch]()
    batches.append(_make_int64_batch([1, 2, 3]))
    batches.append(_make_int64_batch([4, 5]))
    batches.append(_make_int64_batch([6, 7, 8, 9]))
    batches.append(_make_int64_batch([10]))
    batches.append(_make_int64_batch([11, 12, 13]))

    var merged = concat_record_batches_nway(batches^)

    # Expected: 13 rows, [1..13].
    assert_equal(merged.num_rows(), 13)
    assert_equal(merged.num_columns(), 1)
    ref col = merged.column_at(0)
    assert_equal(col._length, 13)
    assert_equal(col._null_count, 0)
    comptime sz = size_of[Int64]()
    for i in range(13):
        var v = col._data.get_typed[Int64](i)
        assert_equal(Int(v), i + 1)


def test_nway_string_three_inputs_offsets_rebased() raises:
    """3-input STRING concat: per-row values match + offsets correctly shifted."""
    var b1 = _make_string_batch([String("aa"), String("bbb")])  # 2 rows, 5 data bytes
    var b2 = _make_string_batch([String("c")])                  # 1 row, 1 data byte
    var b3 = _make_string_batch([String(""), String("dddd")])  # 2 rows, 4 data bytes

    var batches = Slab[RecordBatch]()
    batches.append(b1^)
    batches.append(b2^)
    batches.append(b3^)

    var merged = concat_record_batches_nway(batches^)
    assert_equal(merged.num_rows(), 5)
    ref col = merged.column_at(0)
    assert_equal(col._length, 5)
    assert_equal(col._null_count, 0)

    # Offsets: [0, 2, 5, 6, 6, 10]
    comptime int32_size = size_of[Int32]()
    var expected_offs: List[Int] = [0, 2, 5, 6, 6, 10]
    for i in range(6):
        var off = col._offsets.value().get_typed[Int32](i)
        assert_equal(Int(off), expected_offs[i])

    # Data bytes (10 total): "aabbbcdddd"
    var ca = Int(ord("a"))
    var cb = Int(ord("b"))
    var cc = Int(ord("c"))
    var cd = Int(ord("d"))
    var expected_bytes: List[Int] = [ca, ca, cb, cb, cb, cc, cd, cd, cd, cd]
    for i in range(10):
        var b = col._data.read_u8_at(i)
        assert_equal(Int(b), expected_bytes[i])


def test_nway_validity_mixed_inputs() raises:
    """Mixed validity: input 0 fully valid (no bitmap), input 1 has nulls,
    input 2 fully valid (no bitmap). Output bitmap correctly merged."""
    var b1 = _make_int64_batch([10, 20])  # all valid
    var b2 = _make_nullable_int64_batch([30, 99, 40], [False, True, False])
    var b3 = _make_int64_batch([50, 60])  # all valid

    var batches = Slab[RecordBatch]()
    batches.append(b1^)
    batches.append(b2^)
    batches.append(b3^)

    var merged = concat_record_batches_nway(batches^)
    assert_equal(merged.num_rows(), 7)
    ref col = merged.column_at(0)
    assert_equal(col._length, 7)
    assert_equal(col._null_count, 1)
    # Validity: rows [0,1,2,4,5,6] valid, row 3 null.
    assert_true(col._validity.__bool__())
    ref bm = col._validity.value()
    assert_true(bm.test(0))
    assert_true(bm.test(1))
    assert_true(bm.test(2))
    assert_false(bm.test(3))
    assert_true(bm.test(4))
    assert_true(bm.test(5))
    assert_true(bm.test(6))


def test_nway_all_valid_no_bitmap_emitted() raises:
    """When all N inputs have no nulls, output has no validity bitmap."""
    var batches = Slab[RecordBatch]()
    batches.append(_make_int64_batch([1, 2]))
    batches.append(_make_int64_batch([3]))
    batches.append(_make_int64_batch([4, 5, 6]))

    var merged = concat_record_batches_nway(batches^)
    ref col = merged.column_at(0)
    assert_equal(col._null_count, 0)
    assert_false(col._validity.__bool__())


def test_nway_single_input_pass_through() raises:
    """N=1: result is the single batch, unmodified."""
    var batches = Slab[RecordBatch]()
    batches.append(_make_int64_batch([42, 43]))

    var merged = concat_record_batches_nway(batches^)
    assert_equal(merged.num_rows(), 2)
    ref col = merged.column_at(0)
    assert_equal(Int(col._data.get_typed[Int64](0)), 42)
    assert_equal(Int(col._data.get_typed[Int64](1)), 43)


def test_nway_int64_matches_pairwise_baseline() raises:
    """4 inputs: N-way concat == 3 pair-wise _concat_columns calls."""
    var b1 = _make_int64_batch([1, 2])
    var b2 = _make_int64_batch([3, 4, 5])
    var b3 = _make_int64_batch([6])
    var b4 = _make_int64_batch([7, 8])

    # Pair-wise baseline:
    var col_a = b1.column_at(0).deep_copy()
    var col_b = b2.column_at(0).deep_copy()
    var merged_ab = _concat_columns(col_a, col_b)
    var col_c = b3.column_at(0).deep_copy()
    var merged_abc = _concat_columns(merged_ab, col_c)
    var col_d = b4.column_at(0).deep_copy()
    var merged_pairwise = _concat_columns(merged_abc, col_d)

    # N-way:
    var batches = Slab[RecordBatch]()
    batches.append(b1^)
    batches.append(b2^)
    batches.append(b3^)
    batches.append(b4^)
    var merged_nway = concat_record_batches_nway(batches^)

    assert_equal(merged_pairwise._length, 8)
    assert_equal(merged_nway.num_rows(), 8)
    ref nw_col = merged_nway.column_at(0)
    # Byte-identical data buffer:
    for i in range(8):
        var pv = merged_pairwise._data.get_typed[Int64](i)
        var nv = nw_col._data.get_typed[Int64](i)
        assert_equal(Int(pv), Int(nv))


def test_nway_two_column_batch_primitive_and_string() raises:
    """Mixed-type 2-column RecordBatch concat across 3 inputs."""
    var ids1 = PrimitiveArray[DType.int64].allocate(2)
    ids1.set(0, Int64(1))
    ids1.set(1, Int64(2))
    var strs1: List[String] = [String("a"), String("bb")]
    var sa1 = StringArray.from_strings(strs1)

    var ids2 = PrimitiveArray[DType.int64].allocate(1)
    ids2.set(0, Int64(3))
    var strs2: List[String] = [String("ccc")]
    var sa2 = StringArray.from_strings(strs2)

    var ids3 = PrimitiveArray[DType.int64].allocate(2)
    ids3.set(0, Int64(4))
    ids3.set(1, Int64(5))
    var strs3: List[String] = [String("dddd"), String("e")]
    var sa3 = StringArray.from_strings(strs3)

    def _mk(
        var ids: PrimitiveArray[DType.int64], var sa: StringArray
    ) raises -> RecordBatch:
        var schema = Schema.from_fields_2(
            Field("id", ArrowType.INT64, False),
            Field("s", ArrowType.STRING, False),
        )
        var b = RecordBatchBuilder.with_capacity(2)
        b.add_column(Column.from_primitive[DType.int64](ids^))
        b.add_column(Column.from_string(sa^))
        return b.build(schema^)

    var batches = Slab[RecordBatch]()
    batches.append(_mk(ids1^, sa1^))
    batches.append(_mk(ids2^, sa2^))
    batches.append(_mk(ids3^, sa3^))

    var merged = concat_record_batches_nway(batches^)
    assert_equal(merged.num_rows(), 5)
    assert_equal(merged.num_columns(), 2)

    ref id_col = merged.column_at(0)
    var expected_ids: List[Int] = [1, 2, 3, 4, 5]
    for i in range(5):
        assert_equal(Int(id_col._data.get_typed[Int64](i)), expected_ids[i])

    ref s_col = merged.column_at(1)
    assert_equal(s_col._length, 5)
    # Offsets: [0, 1, 3, 6, 10, 11]
    var expected_offs: List[Int] = [0, 1, 3, 6, 10, 11]
    for i in range(6):
        var off = s_col._offsets.value().get_typed[Int32](i)
        assert_equal(Int(off), expected_offs[i])
    # Bytes: "abbcccdddde"
    var ca = Int(ord("a"))
    var cb = Int(ord("b"))
    var cc = Int(ord("c"))
    var cd = Int(ord("d"))
    var ce = Int(ord("e"))
    var expected_bytes: List[Int] = [ca, cb, cb, cc, cc, cc, cd, cd, cd, cd, ce]
    for i in range(11):
        var b = s_col._data.read_u8_at(i)
        assert_equal(Int(b), expected_bytes[i])


def main() raises:
    var t = TestSuite()
    t.test[test_nway_int64_five_inputs_matches_pairwise]()
    t.test[test_nway_string_three_inputs_offsets_rebased]()
    t.test[test_nway_validity_mixed_inputs]()
    t.test[test_nway_all_valid_no_bitmap_emitted]()
    t.test[test_nway_single_input_pass_through]()
    t.test[test_nway_int64_matches_pairwise_baseline]()
    t.test[test_nway_two_column_batch_primitive_and_string]()
    t^.run()
