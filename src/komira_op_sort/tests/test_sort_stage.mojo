# =============================================================================
# Stage_Sort, and the stage sort buffer's float order
# =============================================================================
#
# Stage_Sort: one INT64 key ASC and DESC (the `make_sort_buffer_i64_1`
# factory), and two INT64 keys ASC/ASC and DESC/ASC; `process_batch` emits
# nothing and `finalize` emits the sorted frame.
#
# Float order (a behaviour change). The buffer's own comparisons ordered a
# FLOAT64 key with IEEE `<` / `>`, which tie a NaN with every value:
#   * `sorted_order` (the merge sort, also the comparator a spill merge or a
#     top-N heap uses) left NaN rows wherever the merge met them;
#   * `compare_batch_row_to_slot` (the top-N candidate test) never let a NaN
#     candidate beat a numeric row;
#   * `simd_reject_winner_mask` (the top-N SIMD reject) never marked a NaN
#     lane a winner DESC, so a DESC top-N skipped every NaN.
# They now order by `sort.sort_key_lt` (NaN above +inf, every NaN tied), as
# the drain (`sort_batch_by_keys`) already did. Planted mutants: the IEEE
# compare in `_key_cmp3` turns `test_sorted_order_f64_*`,
# `test_drain_and_sorted_order_agree_f64` and `test_candidate_compare_f64_nan`
# red; the mask without its NaN terms turns `test_simd_reject_mask_f64_nan_*`
# red. (The mask tests NaN with `isnan`: `SIMD.ne` is an ordered compare and
# does not flag a NaN.)
# =============================================================================

from std.math import inf, isnan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder

from komira_op_sort.sort_stage import Stage_Sort
from komira_op_sort.sort_stage_buffer import (
    Payload_I64,
    SortBuffer,
    SortKeyBlock,
    SortKeyBlock1_I64,
    make_sort_buffer_f64_1,
    make_sort_buffer_i64_1,
)
from komira_op_sort.sort_stage_columns import (
    SORT_DIR_ASC_U8,
    SORT_DIR_DESC_U8,
    SortKeyColumn_Typed,
)
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


# -----------------------------------------------------------------------------
# Stage_Sort
# -----------------------------------------------------------------------------


def _one_key_batch() raises -> RecordBatch:
    var k: List[Int64] = [3, 1, 4, 1, 5]
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    return RecordBatch.from_typed_columns_1(
        sb.build(),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k^)
        ),
    )


def _schema_k_p() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("p", ArrowType.INT64, True))
    return sb.build()


def _stage_sort_one_key(dir: UInt8) raises -> List[Int64]:
    var batch = _one_key_batch()
    var bv = batch_view_over(batch)
    var stage = Stage_Sort[SortKeyBlock1_I64, Payload_I64](
        buffer=make_sort_buffer_i64_1(16, dir), output_schema=_schema_k_p()
    )
    var r = stage.process_batch(bv)
    assert_false(r.batch.__bool__())
    var fin = stage^.finalize()
    assert_true(fin.__bool__())
    var out = fin.take()
    var c = out.column_as_primitive_int64(0)
    var got = List[Int64]()
    for i in range(out.num_rows()):
        got.append(c.load[1](i)[0])
    return got^


def test_stage_sort_one_key_asc() raises:
    var got = _stage_sort_one_key(SORT_DIR_ASC_U8)
    var want: List[Int64] = [1, 1, 3, 4, 5]
    assert_equal(len(got), 5)
    for i in range(5):
        assert_equal(got[i], want[i])


def test_stage_sort_one_key_desc() raises:
    var got = _stage_sort_one_key(SORT_DIR_DESC_U8)
    var want: List[Int64] = [5, 4, 3, 1, 1]
    for i in range(5):
        assert_equal(got[i], want[i])


comptime _K0 = SortKeyColumn_Typed[DType.int64, 0]
comptime _K1 = SortKeyColumn_Typed[DType.int64, 1]
comptime _KB2 = SortKeyBlock[_K0, _K1]
comptime _P0 = PayloadCol_Typed[DType.int64, 0]


def _two_key(dir0: UInt8, e0: List[Int64], e1: List[Int64]) raises:
    var k0: List[Int64] = [1, 2, 1, 2, 1]
    var k1: List[Int64] = [20, 10, 10, 20, 30]
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, True))
    var batch = RecordBatch.from_typed_columns_2(
        sb.build(),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k0^)
        ),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k1^)
        ),
    )
    var buf = SortBuffer[_KB2, _P0](
        _KB2((_K0.new(16), _K1.new(16))), (_P0.new(16),), initial_capacity=16
    )
    buf.set_direction(0, dir0)
    buf.set_direction(1, SORT_DIR_ASC_U8)
    var osb = SchemaBuilder()
    osb.add_field(Field("k0", ArrowType.INT64, True))
    osb.add_field(Field("k1", ArrowType.INT64, True))
    osb.add_field(Field("payload", ArrowType.INT64, True))
    var stage = Stage_Sort[_KB2, _P0](buffer=buf^, output_schema=osb.build())
    var bv = batch_view_over(batch)
    _ = stage.process_batch(bv)
    var fin = stage^.finalize()
    var out = fin.take()
    assert_equal(out.num_rows(), 5)
    assert_equal(out.num_columns(), 3)
    var c0 = out.column_as_primitive_int64(0)
    var c1 = out.column_as_primitive_int64(1)
    for r in range(5):
        assert_equal(c0.load[1](r)[0], e0[r])
        assert_equal(c1.load[1](r)[0], e1[r])


def test_stage_sort_two_keys_asc_asc() raises:
    _two_key(SORT_DIR_ASC_U8, [1, 1, 1, 2, 2], [10, 20, 30, 10, 20])


def test_stage_sort_two_keys_desc_asc() raises:
    _two_key(SORT_DIR_DESC_U8, [2, 2, 1, 1, 1], [10, 20, 10, 20, 30])


# -----------------------------------------------------------------------------
# Float order
# -----------------------------------------------------------------------------


def _f64_keys() -> List[Float64]:
    """24 rows: NaN at rows 2, 9, 17; +inf at 5; -inf at 12; -0.0 at 20 and
    +0.0 at 21; other rows numbers."""
    var out = List[Float64]()
    for i in range(24):
        if i == 2 or i == 9 or i == 17:
            out.append(_nan())
        elif i == 5:
            out.append(inf[DType.float64]())
        elif i == 12:
            out.append(-inf[DType.float64]())
        elif i == 20:
            out.append(-0.0)
        elif i == 21:
            out.append(0.0)
        else:
            out.append(Float64((i * 7) % 11) - 5.0)
    return out^


def _f64_buffer(dir: UInt8) -> SortBuffer[
    SortKeyBlock[SortKeyColumn_Typed[DType.float64, 0]], Payload_I64
]:
    var buf = make_sort_buffer_f64_1(32, dir)
    var keys = _f64_keys()
    for i in range(len(keys)):
        buf.append_key[0, DType.float64](keys[i])
        buf.append_payload[0, DType.int64](Int64(i))
        buf.commit_row()
    return buf^


def test_sorted_order_f64_asc_nan_last() raises:
    var buf = _f64_buffer(SORT_DIR_ASC_U8)
    var order = buf.sorted_order()
    assert_equal(len(order), 24)
    # The three NaN rows last, in input order; everything before ascending.
    assert_equal(order[21], 2)
    assert_equal(order[22], 9)
    assert_equal(order[23], 17)
    assert_equal(order[0], 12)  # -inf first
    assert_equal(order[20], 5)  # +inf right before the NaNs
    for p in range(1, 21):
        var a = buf.key_at[0, DType.float64](order[p - 1])
        var b = buf.key_at[0, DType.float64](order[p])
        assert_true(a <= b)
    # -0.0 (row 20) and +0.0 (row 21) tie: input order.
    var pos20 = -1
    var pos21 = -1
    for p in range(24):
        if order[p] == 20:
            pos20 = p
        if order[p] == 21:
            pos21 = p
    assert_true(pos20 >= 0 and pos21 == pos20 + 1)


def test_sorted_order_f64_desc_nan_first() raises:
    var buf = _f64_buffer(SORT_DIR_DESC_U8)
    var order = buf.sorted_order()
    assert_equal(order[0], 2)
    assert_equal(order[1], 9)
    assert_equal(order[2], 17)
    assert_equal(order[3], 5)  # +inf after the NaNs
    assert_equal(order[23], 12)  # -inf last


def test_drain_and_sorted_order_agree_f64() raises:
    """The drain (sort_batch_by_keys) and the buffer's own merge sort give the
    same payload order, both directions."""
    for dir in [SORT_DIR_ASC_U8, SORT_DIR_DESC_U8]:
        var buf = _f64_buffer(dir)
        var order = buf.sorted_order()
        var drained = buf.drain_to_record_batch()
        var out = drained.take()
        var pay = out.column_as_primitive_int64(1)
        for p in range(24):
            assert_equal(Int(pay.load[1](p)[0]), order[p])


def _f64_batch(values: List[Float64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    return RecordBatch.from_typed_columns_1(
        sb.build(),
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(values)
        ),
    )


def test_candidate_compare_f64_nan() raises:
    """A NaN candidate sorts after a numeric slot; two NaNs tie."""
    var col = SortKeyColumn_Typed[DType.float64, 0].new(4)
    col.append_value(1.0)
    col.append_value(_nan())
    var batch = _f64_batch([_nan(), 2.0])
    var bv = batch_view_over(batch)
    assert_equal(col.compare_batch_row_to_slot(bv, 0, 0), 1)   # NaN vs 1.0
    assert_equal(col.compare_batch_row_to_slot(bv, 0, 1), 0)   # NaN vs NaN
    assert_equal(col.compare_batch_row_to_slot(bv, 1, 1), -1)  # 2.0 vs NaN
    assert_equal(col.compare_at(1, 0), 1)
    assert_equal(col.compare_at(0, 1), -1)


def test_simd_reject_mask_f64_nan_desc() raises:
    """DESC: a NaN candidate beats a numeric root; nothing beats a NaN root."""
    var col = SortKeyColumn_Typed[DType.float64, 0].new(1)
    var batch = _f64_batch([_nan(), 5.0, 1.0, inf[DType.float64]()])
    var bv = batch_view_over(batch)
    var m = col.simd_reject_winner_mask[4](bv, 0, 3.0, SORT_DIR_DESC_U8)
    assert_true(m[0])   # NaN > 3.0 under sort_key_lt
    assert_true(m[1])   # 5.0
    assert_false(m[2])  # 1.0
    assert_true(m[3])   # +inf
    var m2 = col.simd_reject_winner_mask[4](bv, 0, _nan(), SORT_DIR_DESC_U8)
    for i in range(4):
        assert_false(m2[i])


def test_simd_reject_mask_f64_nan_asc() raises:
    """ASC: a NaN candidate never wins; every number beats a NaN root."""
    var col = SortKeyColumn_Typed[DType.float64, 0].new(1)
    var batch = _f64_batch([_nan(), 5.0, 1.0, -inf[DType.float64]()])
    var bv = batch_view_over(batch)
    var m = col.simd_reject_winner_mask[4](bv, 0, 3.0, SORT_DIR_ASC_U8)
    assert_false(m[0])
    assert_false(m[1])
    assert_true(m[2])
    assert_true(m[3])
    var m2 = col.simd_reject_winner_mask[4](bv, 0, _nan(), SORT_DIR_ASC_U8)
    assert_false(m2[0])
    assert_true(m2[1])
    assert_true(m2[2])
    assert_true(m2[3])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
