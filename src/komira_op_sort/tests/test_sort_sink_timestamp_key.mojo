# =============================================================================
# The sort sink orders a TIMESTAMP key as the signed integer it is stored as
# =============================================================================
#
# Every TIMESTAMP unit (and the unit-less TIMESTAMP) is stored as a signed
# int64 tick count, and one column has one unit, so tick order is instant
# order. A tick count below zero (before the epoch) sorts before zero, in
# ascending and in descending order.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_physical_plan.physical_plan import SortSinkData
from komira_op_sort.sort_topn_sink import _execute_sort_sink


def _batch(unit: ArrowType) raises -> RecordBatch:
    """`[t <unit>, id INT64]` with ticks 5, -3, 0, -100, 7 in that order."""
    var ticks: List[Int64] = [5, -3, 0, -100, 7]
    var t = PrimitiveArray[DType.int64].allocate(len(ticks))
    var ids = PrimitiveArray[DType.int64].allocate(len(ticks))
    for i in range(len(ticks)):
        t.set_typed[Scalar[DType.int64]](i, ticks[i])
        ids.set_typed[Scalar[DType.int64]](i, Int64(i))
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](t, unit))
    builder.add_column(Column.from_primitive[DType.int64](ids^))
    var sb = SchemaBuilder()
    sb.add_field(Field("t", unit, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    return builder.build(sb.build())


def _sorted_ids(unit: ArrowType, descending: Bool) raises -> List[Int]:
    var keys = List[String]()
    keys.append(String("t"))
    var desc = List[Bool]()
    desc.append(descending)
    var rb = _execute_sort_sink(_batch(unit), SortSinkData(keys^, desc^))
    var out = List[Int]()
    for r in range(rb.num_rows()):
        out.append(
            Int(rb.column_as_primitive_int64(1).get_typed[Scalar[DType.int64]](r))
        )
    return out^


def _units() -> List[ArrowType]:
    var u = List[ArrowType]()
    u.append(ArrowType.TIMESTAMP)
    u.append(ArrowType.TIMESTAMP_S)
    u.append(ArrowType.TIMESTAMP_MS)
    u.append(ArrowType.TIMESTAMP_US)
    u.append(ArrowType.TIMESTAMP_NS)
    return u^


def test_timestamp_units_sort_ascending_with_negative_ticks_first() raises:
    # ticks by id: 0:5 1:-3 2:0 3:-100 4:7  ->  -100(3) -3(1) 0(2) 5(0) 7(4)
    var units = _units()
    for u in range(len(units)):
        var ids = _sorted_ids(units[u], False)
        var want: List[Int] = [3, 1, 2, 0, 4]
        for i in range(5):
            assert_equal(ids[i], want[i], "unit " + String(u) + " row " + String(i))


def test_timestamp_units_sort_descending() raises:
    var units = _units()
    for u in range(len(units)):
        var ids = _sorted_ids(units[u], True)
        var want: List[Int] = [4, 0, 2, 1, 3]
        for i in range(5):
            assert_equal(ids[i], want[i], "unit " + String(u) + " row " + String(i))


def main() raises:
    var suite = TestSuite()
    suite.test[test_timestamp_units_sort_ascending_with_negative_ticks_first]()
    suite.test[test_timestamp_units_sort_descending]()
    suite^.run()
