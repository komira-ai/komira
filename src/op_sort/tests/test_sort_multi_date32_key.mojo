# =============================================================================
# sort_batch_by_keys orders a DATE32 key as the signed day number it is
# =============================================================================
#
# A DATE32 is stored as a signed int32 count of days since 1970-01-01, so day
# order is date order and a day before the epoch is below zero. What these
# tests prove:
#
#   * one DATE32 key sorts ascending and descending, days before the epoch
#     first ascending, two rows of one day kept in input order;
#   * a DATE32 key ahead of an INT64 key (the per-key passes, not the one-pass
#     lexicographic sort) orders by the day and breaks a tie by the second key,
#     and an INT64 key ahead of a DATE32 key breaks its own ties by the day;
#   * the sorted batch's day column is still DATE32, in the schema and in the
#     column, and holds the day of the row it sits beside.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from op_sort.sort_multi import sort_batch_by_keys


def _days() -> List[Int]:
    """Days by id: 19725 is 2024-01-03, -1 1969-12-31, -400 a day of 1968."""
    return [19725, 19726, -1, 19727, 0, -400, 19725]


def _groups() -> List[Int]:
    return [1, 0, 1, 0, 1, 0, 1]


def _batch() raises -> RecordBatch:
    """`[day DATE32, id INT64, g INT64]`, seven rows of `_days` and `_groups`."""
    var days = _days()
    var groups = _groups()
    var n = len(days)
    var d = PrimitiveArray[DType.int32].allocate(n)
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var g = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        d.set(i, Int32(days[i]))
        ids.set(i, Int64(i))
        g.set(i, Int64(groups[i]))
    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](d, ArrowType.DATE32)
    )
    builder.add_column(Column.from_primitive[DType.int64](ids^))
    builder.add_column(Column.from_primitive[DType.int64](g^))
    var sb = SchemaBuilder()
    sb.add_field(Field("day", ArrowType.DATE32, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("g", ArrowType.INT64, False))
    return builder.build(sb.build())


def _sorted_ids(keys: List[String], desc: List[Bool]) raises -> List[Int]:
    var rb = sort_batch_by_keys(_batch(), keys, desc)
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.DATE32)
    assert_true(rb.column_at(0).arrow_type == ArrowType.DATE32)
    var days = _days()
    var day_col = rb.column_at(0).as_primitive[DType.int32]()
    var out = List[Int]()
    for r in range(rb.num_rows()):
        var id = Int(rb.column_as_primitive_int64(1).get(r))
        assert_equal(Int(day_col.get(r)), days[id], "day at row " + String(r))
        out.append(id)
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "position " + String(i))


def test_one_date32_key_sorts_ascending_days_before_the_epoch_first() raises:
    _expect(_sorted_ids(["day"], [False]), [5, 2, 4, 0, 6, 1, 3])


def test_one_date32_key_sorts_descending() raises:
    _expect(_sorted_ids(["day"], [True]), [3, 1, 0, 6, 4, 2, 5])


def test_a_date32_key_ahead_of_an_int64_key() raises:
    # The two rows of 19725 (ids 0 and 6) in descending id order.
    _expect(_sorted_ids(["day", "id"], [False, True]), [5, 2, 4, 6, 0, 1, 3])


def test_an_int64_key_ahead_of_a_date32_key() raises:
    # g 0: ids 1, 3, 5 (19726, 19727, -400); g 1: ids 0, 2, 4, 6.
    _expect(_sorted_ids(["g", "day"], [False, True]), [3, 1, 5, 0, 6, 4, 2])


def main() raises:
    var suite = TestSuite()
    suite.test[test_one_date32_key_sorts_ascending_days_before_the_epoch_first]()
    suite.test[test_one_date32_key_sorts_descending]()
    suite.test[test_a_date32_key_ahead_of_an_int64_key]()
    suite.test[test_an_int64_key_ahead_of_a_date32_key]()
    suite^.run()
