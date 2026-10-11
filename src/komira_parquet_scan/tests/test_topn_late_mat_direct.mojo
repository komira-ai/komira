# The scan side of the two-phase top-N:
#   - the stamp operator appends the flat row group a morsel came from, for
#     a whole row group's partition id and a split one's, on an empty batch
#     too;
#   - the winners' row groups come back distinct and ascending; an empty
#     answer needs none; a non-empty answer without the stamp column, or
#     with a negative stamp, is refused;
#   - the route counters add up and reset.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_morsel.morsel import Morsel
from komira_parquet_scan.parquet_source_options import rg_partition_id
from komira_parquet_scan.topn_late_mat import (
    TOPN_LATE_MAT_RG_COLUMN,
    TopNRowGroupStampOp,
    reset_topn_late_mat_counters,
    topn_late_mat_phase2_units,
    topn_late_mat_record,
    topn_late_mat_runs,
    topn_late_mat_winner_row_groups,
)


def _batch(name: String, values: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(values)))
    return rbb.build(sb.build())


def test_the_stamp_is_the_row_group_of_the_partition_id() raises:
    var op = TopNRowGroupStampOp()
    for which in range(3):
        var rg = 7 if which < 2 else 0
        var pid = rg_partition_id(rg) + (5 if which == 1 else 0)
        var keys: List[Int64] = [Int64(30), Int64(10), Int64(20)]
        var m = Morsel(_batch("key", keys^), 0, pid)
        var res = op.execute(m)
        assert_true(res.is_need_more_input())
        assert_equal(m.batch.num_columns(), 2)
        var f = m.batch.schema.field_at(1)
        assert_equal(f.name, String(TOPN_LATE_MAT_RG_COLUMN))
        assert_true(f.arrow_type == ArrowType.INT64)
        var col = m.batch.column_as_primitive[DType.int64](1)
        for i in range(3):
            assert_equal(Int(col.get(i)), rg)
    var empty = Morsel(_batch("key", List[Int64]()), 0, rg_partition_id(2))
    _ = op.execute(empty)
    assert_equal(empty.batch.num_rows(), 0)
    assert_equal(empty.batch.num_columns(), 2)


def test_winner_row_groups_and_refusals() raises:
    var stamps: List[Int64] = [Int64(9), Int64(2), Int64(9), Int64(0), Int64(2)]
    assert_equal(topn_late_mat_winner_row_groups(_batch(String(TOPN_LATE_MAT_RG_COLUMN), stamps^)), [0, 2, 9])
    assert_equal(len(topn_late_mat_winner_row_groups(_batch("key", List[Int64]()))), 0)
    with assert_raises(contains="no __komira_topn_late_mat_rg column"):
        var keys: List[Int64] = [Int64(1)]
        _ = topn_late_mat_winner_row_groups(_batch("key", keys^))
    with assert_raises(contains="negative row-group stamp"):
        var bad: List[Int64] = [Int64(1), Int64(-1)]
        _ = topn_late_mat_winner_row_groups(_batch(String(TOPN_LATE_MAT_RG_COLUMN), bad^))


def test_the_route_counters() raises:
    reset_topn_late_mat_counters()
    topn_late_mat_record(3)
    topn_late_mat_record(4)
    assert_equal(topn_late_mat_runs(), 2)
    assert_equal(topn_late_mat_phase2_units(), 7)
    reset_topn_late_mat_counters()
    assert_equal(topn_late_mat_runs(), 0)
    assert_equal(topn_late_mat_phase2_units(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
