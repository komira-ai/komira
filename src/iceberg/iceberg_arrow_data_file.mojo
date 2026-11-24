# =============================================================================
# iceberg_arrow_data_file.mojo — an Arrow RecordBatch as one Iceberg data file.
# =============================================================================
#
# `encode_iceberg_data_file` turns one Arrow batch into the bytes of a Parquet
# data file and the `DataFileInfo` the manifest records for it:
#
#   * the Parquet schema carries the table's field ids (Parquet field 9), so a
#     reader binds each column to the table schema by id and not by name;
#   * a column the table says is `required` is written REQUIRED and any other
#     OPTIONAL, whatever the batch's own nullable flags say;
#   * the `DataFileInfo` holds the file URI as given, the byte size, the row
#     count and one `ColumnBound` per column: the single-value-serialized
#     lower and upper bound, null count and value count for boolean, int,
#     long, float, double and date columns, the counts alone for strings.
#
# `iceberg_type_of_arrow` and `iceberg_type_of_column` name the Iceberg type of
# a column (the subset above, with string and date), and refuse any other
# Arrow type with ICEBERG_TYPE_UNSUPPORTED.
#
# The module opens no file and reads no catalog: bytes in, bytes out. Errors
# start with their token, then `: ` and the message.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.record_batch import RecordBatch
from arrow.schema import SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from containers.slab import Slab
from parquet_api.types import CompressionCodec
from parquet_writer import write_record_batch_to_parquet_bytes

from .iceberg_bounds import (
    bound_int32,
    bound_int64,
    bound_float32,
    bound_float64,
    bound_boolean,
)
from .iceberg_types import ColumnBound, DataFileInfo

comptime ICEBERG_TYPE_UNSUPPORTED: String = "ICEBERG_TYPE_UNSUPPORTED"
comptime ICEBERG_NULL_IN_REQUIRED_COLUMN: String = (
    "ICEBERG_NULL_IN_REQUIRED_COLUMN"
)


# =============================================================================
# Arrow type -> Iceberg type name.
# =============================================================================


def _write_iceberg_type_of_arrow[
    W: Writer
](mut writer: W, arrow_type: ArrowType, string_dictionary: Bool) -> Bool:
    """WRITE the Iceberg type name of `arrow_type`; True when it has one.
    ⚠ THIS WRITES; IT DOES NOT RETURN THE NAME.

    The arms live here so no string constant is ever SELECTED and returned:
    see `_write_iceberg_type_name` in iceberg_types.mojo."""
    if arrow_type == ArrowType.BOOL:
        writer.write(String("boolean"))
        return True
    elif arrow_type == ArrowType.INT32:
        writer.write(String("int"))
        return True
    elif arrow_type == ArrowType.INT64:
        writer.write(String("long"))
        return True
    elif arrow_type == ArrowType.FLOAT32:
        writer.write(String("float"))
        return True
    elif arrow_type == ArrowType.FLOAT64:
        writer.write(String("double"))
        return True
    elif arrow_type == ArrowType.DATE32:
        writer.write(String("date"))
        return True
    elif (
        arrow_type == ArrowType.STRING
        or arrow_type == ArrowType.LARGE_STRING
        or (arrow_type == ArrowType.DICTIONARY and string_dictionary)
    ):
        writer.write(String("string"))
        return True
    return False


def iceberg_type_of_arrow(
    column_name: String, arrow_type: ArrowType, string_dictionary: Bool = False
) raises -> String:
    """The Iceberg type name a column of `arrow_type` is written as: bool
    `boolean`, int32 `int`, int64 `long`, float32 `float`, float64 `double`,
    date32 `date`, utf8, large_utf8 and (when `string_dictionary`) a
    dictionary of utf8 `string`.

    Raises:
        Error: any other Arrow type, as
            `ICEBERG_TYPE_UNSUPPORTED: column <name> has Arrow type <type>,
            which the Iceberg writer does not write yet`.
    """
    var out = String()
    if _write_iceberg_type_of_arrow(out, arrow_type, string_dictionary):
        return out^
    raise Error(
        String(ICEBERG_TYPE_UNSUPPORTED)
        + ": column "
        + column_name
        + " has Arrow type "
        + String(arrow_type)
        + ", which the Iceberg writer does not write yet"
    )


def iceberg_type_of_column(batch: RecordBatch, index: Int) raises -> String:
    """`iceberg_type_of_arrow` for column `index` of `batch`, which knows
    whether a dictionary column holds strings.

    Raises:
        Error: the column's type has no Iceberg type (ICEBERG_TYPE_UNSUPPORTED).
    """
    return iceberg_type_of_arrow(
        batch.schema.field_name(index),
        batch.schema.field_arrow_type(index),
        batch.column_at(index).is_string_dict(),
    )


# =============================================================================
# One batch -> one data file.
# =============================================================================


struct EncodedDataFile(Movable):
    """A Parquet data file in memory and what the manifest records for it.

    Fields:
      var bytes: List[UInt8]   — the Parquet file.
      var info: DataFileInfo   — `file_path` is the URI the caller gave,
                                 `file_size_in_bytes` is `len(bytes)`.
    """

    var bytes: List[UInt8]
    var info: DataFileInfo

    def __init__(out self, var bytes: List[UInt8], var info: DataFileInfo):
        self.bytes = bytes^
        self.info = info^


def _null_count(batch: RecordBatch, index: Int) -> Int:
    var n = 0
    ref col = batch.column_at(index)
    for row in range(col.length()):
        if col.is_null_at(row):
            n += 1
    return n


def _column_bound(
    batch: RecordBatch, index: Int, field_id: Int
) raises -> ColumnBound:
    """The bound of column `index`: min, max and counts for a fixed-width
    column, the counts alone for a string."""
    var at = batch.schema.field_arrow_type(index)
    if at == ArrowType.BOOL:
        return bound_boolean(field_id, batch.column_as_boolean(index))
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        return bound_int32(
            field_id, batch.column_as_primitive[DType.int32](index)
        )
    elif at == ArrowType.INT64:
        return bound_int64(
            field_id, batch.column_as_primitive[DType.int64](index)
        )
    elif at == ArrowType.FLOAT32:
        return bound_float32(
            field_id, batch.column_as_primitive[DType.float32](index)
        )
    elif at == ArrowType.FLOAT64:
        return bound_float64(
            field_id, batch.column_as_primitive[DType.float64](index)
        )
    return ColumnBound(
        field_id, None, None, _null_count(batch, index), batch.num_rows()
    )


def _with_nullability(
    batch: RecordBatch, required: List[Bool]
) raises -> RecordBatch:
    """`batch` with column `i` declared NOT NULL when `required[i]` and
    nullable otherwise; the columns are shared, not copied."""
    var n = batch.num_columns()
    var sb = SchemaBuilder()
    var columns = Slab[Column[HeapRegion]].create(n)
    for i in range(n):
        var field = batch.schema.field_at(i)
        field.nullable = not required[i]
        sb.add_field(field)
        columns.append(batch.column_at(i).share())
    return RecordBatch.from_typed_columns_slab(sb.build(), columns^)


def encode_iceberg_data_file(
    batch: RecordBatch,
    field_ids: List[Int],
    required: List[Bool],
    var file_uri: String,
    codec: CompressionCodec,
) raises -> EncodedDataFile:
    """`batch` as a Parquet data file with field id `field_ids[i]` on column
    `i`, REQUIRED where `required[i]`, and the `DataFileInfo` for it.

    Nothing is written when an error is raised.

    Raises:
        Error: the batch has no columns, or `field_ids` or `required` does not
            have one entry per column; a column's type has no Iceberg type
            (ICEBERG_TYPE_UNSUPPORTED); or a required column holds a null, as
            `ICEBERG_NULL_IN_REQUIRED_COLUMN: column <name> is required and the
            rows hold <n> null(s)`.
    """
    var n = batch.num_columns()
    if n == 0:
        raise Error("encode_iceberg_data_file: batch has no columns")
    if len(field_ids) != n or len(required) != n:
        raise Error(
            "encode_iceberg_data_file: "
            + String(len(field_ids))
            + " field id(s) and "
            + String(len(required))
            + " required flag(s) for "
            + String(n)
            + " column(s)"
        )
    for i in range(n):
        _ = iceberg_type_of_column(batch, i)
    for i in range(n):
        if not required[i]:
            continue
        var nulls = _null_count(batch, i)
        if nulls > 0:
            raise Error(
                String(ICEBERG_NULL_IN_REQUIRED_COLUMN)
                + ": column "
                + batch.schema.field_name(i)
                + " is required and the rows hold "
                + String(nulls)
                + " null(s)"
            )

    var bounds = List[ColumnBound]()
    for i in range(n):
        bounds.append(_column_bound(batch, i, field_ids[i]))
    var bytes = write_record_batch_to_parquet_bytes(
        _with_nullability(batch, required), codec, field_ids=field_ids
    )
    var size = len(bytes)
    return EncodedDataFile(
        bytes^, DataFileInfo(file_uri^, size, batch.num_rows(), bounds^)
    )
