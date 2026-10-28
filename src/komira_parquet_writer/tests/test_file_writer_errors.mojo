# ParquetFileWriter refuses what would make a file that does not match its
# schema. No reader is needed: each test is an Error and its message.
#
#   * test_closed_writer_refuses_everything: close_to_bytes ends the writer;
#     a second close and a later write both raise (a double close that
#     returned a second file would hide a caller's lost-bytes bug).
#   * test_column_index_out_of_range: index -1 and index == leaf count.
#   * test_a_column_cannot_be_written_twice: two chunks for one leaf would
#     leave a footer whose columns do not line up with the schema.
#   * test_row_counts_must_agree: the second column's length differs.
#   * test_every_leaf_must_be_written: a file with fewer chunks than leaves
#     is refused at close (readers index chunks by leaf).
#   * test_required_column_refuses_a_null: nullability is the schema's, so a
#     REQUIRED column holding a null raises instead of dropping the null.
#   * test_no_column_written_is_a_footer_only_file: zero chunks closes, with
#     no row group.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import ParquetType
from komira_parquet_writer import (
    ParquetFileWriter,
    make_schema_elements_nullable,
)


def _schema(nullable_second: Bool = False) raises -> List[SchemaElement]:
    var names: List[String] = ["a", "b"]
    var types: List[ParquetType] = [ParquetType.INT32, ParquetType.INT32]
    var nullable: List[Bool] = [False, nullable_second]
    return make_schema_elements_nullable(names^, types^, nullable^)


def _col(n: Int) raises -> PrimitiveArray[DType.int32]:
    var a = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        a.set(i, Int32(i))
    return a^


def test_closed_writer_refuses_everything() raises:
    var w = ParquetFileWriter.create(_schema())
    w.write_batch[DType.int32](0, _col(3))
    w.write_batch[DType.int32](1, _col(3))
    var file = w.close_to_bytes()
    assert_true(len(file) > 12)
    with assert_raises(contains="already closed"):
        _ = w.close_to_bytes()
    with assert_raises(contains="already closed"):
        w.write_batch[DType.int32](0, _col(3))


def test_column_index_out_of_range() raises:
    var w = ParquetFileWriter.create(_schema())
    with assert_raises(contains="column_index -1 out of range"):
        w.write_batch[DType.int32](-1, _col(3))
    with assert_raises(contains="column_index 2 out of range"):
        w.write_batch[DType.int32](2, _col(3))


def test_a_column_cannot_be_written_twice() raises:
    var w = ParquetFileWriter.create(_schema())
    w.write_batch[DType.int32](0, _col(3))
    with assert_raises(contains="column 0 was already written"):
        w.write_batch[DType.int32](0, _col(3))


def test_row_counts_must_agree() raises:
    var w = ParquetFileWriter.create(_schema())
    w.write_batch[DType.int32](0, _col(3))
    with assert_raises(contains="column 1 has 4 rows, expected 3"):
        w.write_batch[DType.int32](1, _col(4))


def test_every_leaf_must_be_written() raises:
    var w = ParquetFileWriter.create(_schema())
    w.write_batch[DType.int32](1, _col(3))
    with assert_raises(contains="1 of 2 columns were written"):
        _ = w.close_to_bytes()


def test_required_column_refuses_a_null() raises:
    var w = ParquetFileWriter.create(_schema())
    var a = PrimitiveArray[DType.int32].allocate_nullable(3)
    a._set_null(1)
    with assert_raises(contains="is REQUIRED but holds"):
        w.write_batch[DType.int32](0, a)
    # The same array is fine for an OPTIONAL column.
    var w2 = ParquetFileWriter.create(_schema(nullable_second=True))
    w2.write_batch[DType.int32](0, _col(3))
    w2.write_nullable_batch[DType.int32](1, a)
    assert_true(len(w2.close_to_bytes()) > 12)


def test_no_column_written_is_a_footer_only_file() raises:
    var w = ParquetFileWriter.create(_schema())
    var file = w.close_to_bytes()
    assert_equal(Int(file[0]), 0x50)
    assert_equal(Int(file[len(file) - 1]), 0x31)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
