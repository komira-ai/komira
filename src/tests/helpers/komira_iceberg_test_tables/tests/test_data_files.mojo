# Rows as Arrow batches, Parquet files and Avro files.
#
#   * test_a_parquet_file_holds_every_type_and_null: rows of all six column
#     types, with nulls, are written as Parquet and read back by the Parquet
#     reader with the same values, nullability and Arrow types (INT32 for an
#     int, DATE32 for a date, FLOAT64 with a NaN), each column carrying its
#     Iceberg field id in the footer.
#   * test_a_required_column_is_not_nullable_in_the_batch: the field's
#     nullability is the column's `required` flag.
#   * test_an_avro_file_holds_the_rows: the same rows as an Avro object
#     container file (deflate) read back by the Avro reader.
#   * test_a_row_with_the_wrong_number_of_cells_is_refused and
#     test_an_unknown_column_type_is_refused: refusals by exact message.
#   * test_files_are_written_under_new_directories: write_file_bytes and
#     write_file_text create the directories of their path; dirname_of cuts at
#     the last `/` and is empty without one.

from std.math import nan
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.record_batch import RecordBatch
from avro.avro_ocf_reader import read_avro_bytes
from avro.ocf_header import decode_ocf_header
from byte_buffer.byte_view import ByteView
from parquet.bytes_decode import decode_row_group_from_bytes, row_group_byte_range
from parquet.metadata_parser import parse_full_metadata
from parquet.morsel_reader import ColumnProjection
from parquet_api.metadata import FileMetaData
from runtime_paths import test_tmpdir

from komira_iceberg_test_tables.data_files import (
    avro_file_bytes,
    dirname_of,
    parquet_file_bytes,
    rows_to_batch,
    write_file_bytes,
    write_file_text,
)
from komira_iceberg_test_tables.table_model import (
    TT_BOOLEAN,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    TableCell,
    TableColumn,
    TableRow,
    bool_cell,
    double_cell,
    int_cell,
    null_cell,
    string_cell,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _read_row_group(file: List[UInt8]) raises -> RecordBatch:
    var md = _footer(file)
    assert_equal(len(md.row_groups), 1)
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


def _columns() -> List[TableColumn]:
    var out = List[TableColumn]()
    out.append(TableColumn(1, "id", TT_LONG, True))
    out.append(TableColumn(2, "qty", TT_INT, False))
    out.append(TableColumn(3, "day", TT_DATE, False))
    out.append(TableColumn(4, "price", TT_DOUBLE, False))
    out.append(TableColumn(5, "name", TT_STRING, False))
    out.append(TableColumn(6, "flag", TT_BOOLEAN, False))
    return out^


def _rows() -> List[TableRow]:
    var out = List[TableRow]()
    var a = List[TableCell]()
    a.append(int_cell(10))
    a.append(int_cell(-3))
    a.append(int_cell(20819))
    a.append(double_cell(1.5))
    a.append(string_cell("alpha"))
    a.append(bool_cell(True))
    out.append(TableRow(a^))
    var b = List[TableCell]()
    b.append(int_cell(11))
    b.append(null_cell())
    b.append(null_cell())
    b.append(double_cell(nan[DType.float64]()))
    b.append(null_cell())
    b.append(null_cell())
    out.append(TableRow(b^))
    var c = List[TableCell]()
    c.append(int_cell(12))
    c.append(int_cell(7))
    c.append(int_cell(20900))
    c.append(null_cell())
    c.append(string_cell(""))
    c.append(bool_cell(False))
    out.append(TableRow(c^))
    return out^


def _check_rows(batch: RecordBatch) raises:
    assert_equal(batch.num_rows(), 3)
    assert_equal(batch.num_columns(), 6)
    assert_equal(batch.schema.field_name(4), "name")
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(batch.schema.field_arrow_type(1) == ArrowType.INT32)
    assert_true(batch.schema.field_arrow_type(2) == ArrowType.DATE32)
    assert_true(batch.schema.field_arrow_type(3) == ArrowType.FLOAT64)
    assert_true(batch.schema.field_arrow_type(4) == ArrowType.STRING)
    assert_true(batch.schema.field_arrow_type(5) == ArrowType.BOOL)
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(2)), 12)
    assert_true(batch.column_at(1).is_null_at(1))
    assert_equal(Int(batch.column_at(1).as_primitive[DType.int32]().get(0)), -3)
    assert_true(batch.column_at(2).is_null_at(1))
    assert_equal(Int(batch.column_at(2).as_primitive[DType.int32]().get(2)), 20900)
    var nan_value = batch.column_at(3).as_primitive[DType.float64]().get(1)
    assert_true(nan_value != nan_value)
    assert_equal(batch.column_at(3).as_primitive[DType.float64]().get(0), 1.5)
    assert_true(batch.column_at(3).is_null_at(2))
    assert_equal(batch.column_at(4).as_string().get(0), "alpha")
    assert_true(batch.column_at(4).is_null_at(1))
    assert_false(batch.column_at(4).is_null_at(2))
    assert_equal(batch.column_at(4).as_string().get(2), "")
    assert_true(batch.column_at(5).as_boolean().get(0))
    assert_false(batch.column_at(5).as_boolean().get(2))
    assert_true(batch.column_at(5).is_null_at(1))


def test_a_parquet_file_holds_every_type_and_null() raises:
    var file = parquet_file_bytes(_columns(), _rows())
    assert_equal(Int(file[0]), 0x50)
    assert_equal(Int(file[len(file) - 1]), 0x31)
    _check_rows(_read_row_group(file))
    # Each column carries its Iceberg field id; the root carries none.
    var md = _footer(file)
    var columns = _columns()
    assert_false(Bool(md.schema[0].field_id))
    for i in range(len(columns)):
        assert_equal(md.schema[i + 1].field_id.value(), columns[i].id)


def test_a_required_column_is_not_nullable_in_the_batch() raises:
    var batch = rows_to_batch(_columns(), _rows())
    assert_false(batch.schema.field_nullable(0))
    assert_true(batch.schema.field_nullable(1))
    assert_true(batch.schema.field_nullable(5))


def test_an_avro_file_holds_the_rows() raises:
    var file = avro_file_bytes(_columns(), _rows())
    assert_equal(decode_ocf_header(Span(file)).codec_name(), "deflate")
    var batch = read_avro_bytes(Span(file))
    assert_equal(batch.num_rows(), 3)
    assert_equal(batch.schema.field_name(0), "id")
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(1)), 11)
    assert_equal(batch.column_at(4).as_string().get(0), "alpha")
    assert_true(batch.column_at(4).is_null_at(1))
    # The date is an int of days in Avro, as Iceberg stores one.
    assert_true(batch.schema.field_arrow_type(2) == ArrowType.INT32)
    assert_equal(Int(batch.column_at(2).as_primitive[DType.int32]().get(2)), 20900)
    assert_true(batch.column_at(2).is_null_at(1))


def test_a_row_with_the_wrong_number_of_cells_is_refused() raises:
    var rows = _rows()
    _ = rows[1].cells.pop()
    var message = String()
    try:
        _ = rows_to_batch(_columns(), rows)
    except e:
        message = String(e)
    assert_equal(
        message,
        "komira_iceberg_test_tables: row 1 has 5 cells for 6 columns",
    )


def test_an_unknown_column_type_is_refused() raises:
    var columns = List[TableColumn]()
    columns.append(TableColumn(1, "odd", 99, False))
    var rows = List[TableRow]()
    var cells = List[TableCell]()
    cells.append(int_cell(1))
    rows.append(TableRow(cells^))
    var message = String()
    try:
        _ = rows_to_batch(columns, rows)
    except e:
        message = String(e)
    assert_equal(
        message,
        "komira_iceberg_test_tables: column odd has an unknown type 99",
    )


def test_files_are_written_under_new_directories() raises:
    var dir = test_tmpdir() + "/data_files"
    var bytes = List[UInt8]()
    bytes.append(UInt8(0))
    bytes.append(UInt8(255))
    bytes.append(UInt8(7))
    write_file_bytes(dir + "/a/b/c.bin", bytes)
    var back = Path(dir + "/a/b/c.bin").read_bytes()
    assert_equal(len(back), 3)
    assert_equal(Int(back[1]), 255)
    write_file_text(dir + "/x/y.txt", "text\n")
    assert_equal(Path(dir + "/x/y.txt").read_text(), "text\n")
    assert_equal(dirname_of("a/b/c.txt"), "a/b")
    assert_equal(dirname_of("c.txt"), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
