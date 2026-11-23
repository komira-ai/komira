# =============================================================================
# data_files.mojo -- rows as the bytes of a Parquet or an Avro file, and the
# few file operations the builder needs.
# =============================================================================
#
# `rows_to_batch` turns rows into an Arrow batch: one field per column, named
# as the column, nullable unless the column is `required`. `parquet_file_bytes`
# writes it with the repository's Parquet writer, each column carrying its
# Iceberg field id as the Parquet field id (as Iceberg Java, Spark and pyiceberg
# write their files; a reader binds columns by id), `avro_file_bytes` as an
# Avro object container file, deflate-compressed.
# =============================================================================

from std.os import makedirs

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from avro.avro_ocf_writer import AvroWriterOptions, write_avro_bytes
from avro.ocf_header import AVRO_CODEC_DEFLATE
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes

from .table_model import (
    TT_BOOLEAN,
    TT_DATE,
    TT_DOUBLE,
    TT_INT,
    TT_LONG,
    TT_STRING,
    TableColumn,
    TableRow,
)


def rows_to_batch(
    columns: List[TableColumn], rows: List[TableRow], dates_as_int: Bool = False
) raises -> RecordBatch:
    """The Arrow batch of `rows` under `columns`. A date column is DATE32, or
    INT32 days with `dates_as_int` (the Avro form: Iceberg stores a date in
    Avro as an int). A row with fewer cells than there are columns is
    refused."""
    var n = len(rows)
    for r in range(n):
        if len(rows[r].cells) != len(columns):
            raise Error(
                "komira_iceberg_test_tables: row " + String(r) + " has "
                + String(len(rows[r].cells)) + " cells for " + String(len(columns))
                + " columns"
            )
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(len(columns)):
        ref col = columns[c]
        var nullable = not col.required
        if col.type_tag == TT_LONG:
            var a = PrimitiveArray[DType.int64].allocate_nullable(n)
            for r in range(n):
                ref cell = rows[r].cells[c]
                a.set(r, cell.i)
                if cell.is_null:
                    a._set_null(r)
            sb.add_field(Field(col.name.copy(), ArrowType.INT64, nullable))
            rb.add_column(Column.from_primitive[DType.int64](a^))
        elif col.type_tag == TT_INT or col.type_tag == TT_DATE:
            var a = PrimitiveArray[DType.int32].allocate_nullable(n)
            for r in range(n):
                ref cell = rows[r].cells[c]
                a.set(r, Int32(cell.i))
                if cell.is_null:
                    a._set_null(r)
            if col.type_tag == TT_INT or dates_as_int:
                sb.add_field(Field(col.name.copy(), ArrowType.INT32, nullable))
                rb.add_column(Column.from_primitive[DType.int32](a^))
            else:
                sb.add_field(Field(col.name.copy(), ArrowType.DATE32, nullable))
                rb.add_column(
                    Column.from_primitive_with_arrow_type[DType.int32](
                        a^, ArrowType.DATE32
                    )
                )
        elif col.type_tag == TT_DOUBLE:
            var a = PrimitiveArray[DType.float64].allocate_nullable(n)
            for r in range(n):
                ref cell = rows[r].cells[c]
                a.set(r, cell.f)
                if cell.is_null:
                    a._set_null(r)
            sb.add_field(Field(col.name.copy(), ArrowType.FLOAT64, nullable))
            rb.add_column(Column.from_primitive[DType.float64](a^))
        elif col.type_tag == TT_STRING:
            var strs = List[String]()
            var valid = List[Bool]()
            for r in range(n):
                ref cell = rows[r].cells[c]
                strs.append(cell.s.copy())
                valid.append(not cell.is_null)
            sb.add_field(Field(col.name.copy(), ArrowType.STRING, nullable))
            rb.add_column(
                Column.from_string(
                    StringArray.from_strings_with_validity(strs, valid)
                )
            )
        elif col.type_tag == TT_BOOLEAN:
            var a = BooleanArray.allocate_nullable(n)
            for r in range(n):
                ref cell = rows[r].cells[c]
                a.set(r, cell.i != 0)
                if cell.is_null:
                    a._set_null(r)
            sb.add_field(Field(col.name.copy(), ArrowType.BOOL, nullable))
            rb.add_column(Column.from_boolean(a^))
        else:
            raise Error(
                "komira_iceberg_test_tables: column " + col.name
                + " has an unknown type " + String(col.type_tag)
            )
    return rb.build(sb.build())


def parquet_file_bytes(columns: List[TableColumn], rows: List[TableRow]) raises -> List[UInt8]:
    """A Parquet file of `rows`, in one row group."""
    var ids = List[Int]()
    for i in range(len(columns)):
        ids.append(columns[i].id)
    return write_record_batch_to_parquet_bytes(
        rows_to_batch(columns, rows), field_ids=ids^
    )


def avro_file_bytes(columns: List[TableColumn], rows: List[TableRow]) raises -> List[UInt8]:
    """An Avro object container file of `rows` (deflate)."""
    return write_avro_bytes(
        rows_to_batch(columns, rows, dates_as_int=True),
        AvroWriterOptions(AVRO_CODEC_DEFLATE),
    )


def dirname_of(path: String) -> String:
    """`path` without its last `/` component (empty when it has no `/`)."""
    var at = path.rfind("/")
    if at < 0:
        return String("")
    return String(path[byte=0:at])


def write_file_bytes(path: String, bytes: List[UInt8]) raises:
    """Writes `bytes` to `path`, creating its directories."""
    makedirs(dirname_of(path), exist_ok=True)
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()


def write_file_text(path: String, text: String) raises:
    """Writes `text` to `path`, creating its directories."""
    makedirs(dirname_of(path), exist_ok=True)
    var fh = open(path, "w")
    fh.write(text)
    fh.close()
