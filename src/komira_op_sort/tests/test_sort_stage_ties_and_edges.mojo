# =============================================================================
# Stage_Sort: ties keep input order, both directions, across batches; empty
# input and a single row
# =============================================================================
#
# The INT64 payload `v` is the input row id, so the order of rows that tie on
# every key is visible. The sorted payloads are compared with the stable sort
# of the same rows: a one-key ASC and DESC sort with ties, a two-key sort with
# ties on both keys, ties that span two batches (the second batch continues the
# row ids), a stage that never saw a row, and a one-row input.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder

from komira_op_sort.sort_stage import Stage_Sort
from komira_op_sort.sort_stage_buffer import SortBuffer, SortKeyBlock
from komira_op_sort.sort_stage_columns import (
    SORT_DIR_ASC_U8,
    SORT_DIR_DESC_U8,
    SortKeyColumn_Typed,
)
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed

comptime _K0 = SortKeyColumn_Typed[DType.int64, 0]
comptime _K1 = SortKeyColumn_Typed[DType.int64, 1]
comptime _KB1 = SortKeyBlock[_K0]
comptime _KB2 = SortKeyBlock[_K0, _K1]
comptime _V1 = PayloadCol_Typed[DType.int64, 1]
comptime _V2 = PayloadCol_Typed[DType.int64, 2]


def _col(var v: List[Int64]) -> Column[]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(v^)
    )


def _ids(start: Int, n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(Int64(start + i))
    return out^


def _batch1(var k: List[Int64], start: Int) raises -> RecordBatch:
    var n = len(k)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    return RecordBatch.from_typed_columns_2(
        sb.build(), _col(k^), _col(_ids(start, n))
    )


def _out_schema1() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    return sb.build()


def _stage1(dir: UInt8) raises -> Stage_Sort[_KB1, _V1]:
    var buf = SortBuffer[_KB1, _V1](_KB1((_K0.new(16),)), (_V1.new(16),), 16)
    buf.set_direction(0, dir)
    return Stage_Sort[_KB1, _V1](buf^, _out_schema1())


def _payloads(b: RecordBatch, col: Int) raises -> List[Int64]:
    var c = b.column_as_primitive_int64(col)
    var got = List[Int64]()
    for i in range(b.num_rows()):
        got.append(c.load[1](i)[0])
    return got^


def _expect(got: List[Int64], want: List[Int64]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def test_ties_keep_input_order_ascending() raises:
    var stage = _stage1(SORT_DIR_ASC_U8)
    var b = _batch1([2, 1, 2, 1, 3, 2, 1], 0)
    var bv = batch_view_over(b)
    _ = stage.process_batch(bv)
    var fin = stage^.finalize()
    var out = fin.take()
    _expect(_payloads(out, 0), [1, 1, 1, 2, 2, 2, 3])
    _expect(_payloads(out, 1), [1, 3, 6, 0, 2, 5, 4])


def test_ties_keep_input_order_descending() raises:
    var stage = _stage1(SORT_DIR_DESC_U8)
    var b = _batch1([2, 1, 2, 1, 3, 2, 1], 0)
    var bv = batch_view_over(b)
    _ = stage.process_batch(bv)
    var fin = stage^.finalize()
    var out = fin.take()
    _expect(_payloads(out, 0), [3, 2, 2, 2, 1, 1, 1])
    _expect(_payloads(out, 1), [4, 0, 2, 5, 1, 3, 6])


def test_ties_across_batches_keep_input_order() raises:
    var stage = _stage1(SORT_DIR_ASC_U8)
    var b0 = _batch1([5, 5, 1], 0)
    var b1 = _batch1([1, 5, 1], 3)
    var v0 = batch_view_over(b0)
    var v1 = batch_view_over(b1)
    _ = stage.process_batch(v0)
    _ = stage.process_batch(v1)
    var fin = stage^.finalize()
    var out = fin.take()
    _expect(_payloads(out, 1), [2, 3, 5, 0, 1, 4])


def test_two_keys_with_ties_on_both() raises:
    var k0: List[Int64] = [1, 2, 1, 2, 1, 1]
    var k1: List[Int64] = [9, 9, 3, 9, 9, 3]
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var batch = RecordBatch.from_typed_columns_3(
        sb.build(), _col(k0^), _col(k1^), _col(_ids(0, 6))
    )
    for desc in range(2):
        var buf = SortBuffer[_KB2, _V2](
            _KB2((_K0.new(16), _K1.new(16))), (_V2.new(16),), 16
        )
        var d = SORT_DIR_DESC_U8 if desc == 1 else SORT_DIR_ASC_U8
        buf.set_direction(0, d)
        buf.set_direction(1, d)
        var osb = SchemaBuilder()
        osb.add_field(Field("k0", ArrowType.INT64, True))
        osb.add_field(Field("k1", ArrowType.INT64, True))
        osb.add_field(Field("v", ArrowType.INT64, True))
        var stage = Stage_Sort[_KB2, _V2](buf^, osb.build())
        var bv = batch_view_over(batch)
        _ = stage.process_batch(bv)
        var fin = stage^.finalize()
        var out = fin.take()
        if desc == 0:
            _expect(_payloads(out, 2), [2, 5, 0, 4, 1, 3])
        else:
            _expect(_payloads(out, 2), [1, 3, 0, 4, 2, 5])


def test_empty_input_drains_no_rows() raises:
    var stage = _stage1(SORT_DIR_ASC_U8)
    var fin = stage^.finalize()
    if fin:
        assert_equal(fin.take().num_rows(), 0)


def test_single_row() raises:
    var stage = _stage1(SORT_DIR_DESC_U8)
    var b = _batch1([42], 7)
    var bv = batch_view_over(b)
    _ = stage.process_batch(bv)
    var fin = stage^.finalize()
    var out = fin.take()
    assert_equal(out.num_rows(), 1)
    _expect(_payloads(out, 0), [42])
    _expect(_payloads(out, 1), [7])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
