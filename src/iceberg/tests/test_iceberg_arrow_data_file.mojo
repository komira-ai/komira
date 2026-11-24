# =============================================================================
# test_iceberg_arrow_data_file.mojo — an Arrow batch as an Iceberg data file.
# =============================================================================
#
# What each test proves:
#   1. The Arrow-to-Iceberg type mapping: each supported Arrow type gives its
#      Iceberg name, and any other type is refused with the exact message
#      naming the column and the type.
#   2. A dictionary column is `string` only when its values are strings, and a
#      large_string column is `string`.
#   3. `DataFileInfo` holds the URI as given, the byte size, the row count and
#      one bound per column: min, max, null count and value count for the
#      fixed-width columns and the counts alone for a string.
#   4. The Parquet bytes carry the table's field ids on the columns in order,
#      a required column REQUIRED and the others OPTIONAL (whatever the
#      batch's own nullable flags say), and decode to the values written.
#   5. An all-null column and a zero-row batch give bounds with no min or max
#      and the right counts, and a zero-row batch is still a Parquet file.
#   6. Float bounds skip NaN, and a zero bound covers both signed zeros.
#   7. A null in a required column is refused by name before any file is built,
#      a required column with a validity buffer and no null is accepted, and
#      an unsupported type is refused before the null check.
#   8. A batch with no columns, or a list of ids or flags of the wrong length,
#      is refused with the exact message.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.dictionary_array import StringDictionaryArray
from arrow.large_string_array import LargeStringArray
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.byte_view import ByteView
from parquet.file_decode import decode_parquet_file_from_bytes
from parquet.metadata_parser import parse_full_metadata
from parquet_api.metadata import FileMetaData
from parquet_api.types import CompressionCodec, FieldRepetitionType, ParquetType

from iceberg import (
    ICEBERG_TYPE_UNSUPPORTED,
    ICEBERG_NULL_IN_REQUIRED_COLUMN,
    EncodedDataFile,
    iceberg_type_of_arrow,
    iceberg_type_of_column,
    encode_iceberg_data_file,
    serialize_boolean,
    serialize_int32,
    serialize_int64,
    serialize_float32,
    serialize_float64,
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


def _message(err: Error) -> String:
    return String(err)


# Rows of the six-column batch (every Arrow field is declared nullable):
#   id      long    required   3, 1, 2, 5
#   name    string             "b", null, "a", "é"
#   amount  double             1.5, null, -2.0, 0.25
#   flag    boolean            true, false, null, true
#   day     date               19000, null, 18000, 19500
#   qty     int                7, 8, null, -1
def _six_column_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    sb.add_field(Field("amount", ArrowType.FLOAT64, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    sb.add_field(Field("day", ArrowType.DATE32, True))
    sb.add_field(Field("qty", ArrowType.INT32, True))

    var id = PrimitiveArray[DType.int64].allocate(4)
    id.set(0, Int64(3))
    id.set(1, Int64(1))
    id.set(2, Int64(2))
    id.set(3, Int64(5))

    var names = List[String]()
    names.append(String("b"))
    names.append(String(""))
    names.append(String("a"))
    names.append(String("é"))
    var name_valid = List[Bool]()
    name_valid.append(True)
    name_valid.append(False)
    name_valid.append(True)
    name_valid.append(True)

    var amount = PrimitiveArray[DType.float64].allocate_nullable(4)
    amount.set(0, Float64(1.5))
    amount._set_null(1)
    amount.set(2, Float64(-2.0))
    amount.set(3, Float64(0.25))

    var flag = BooleanArray.allocate_nullable(4)
    flag.set(0, True)
    flag.set(1, False)
    flag._set_null(2)
    flag.set(3, True)

    var day = PrimitiveArray[DType.int32].allocate_nullable(4)
    day.set(0, Int32(19000))
    day._set_null(1)
    day.set(2, Int32(18000))
    day.set(3, Int32(19500))

    var qty = PrimitiveArray[DType.int32].allocate_nullable(4)
    qty.set(0, Int32(7))
    qty.set(1, Int32(8))
    qty._set_null(2)
    qty.set(3, Int32(-1))

    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    rb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(names, name_valid)
        )
    )
    rb.add_column(Column.from_primitive[DType.float64](amount))
    rb.add_column(Column.from_boolean(flag))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            day, ArrowType.DATE32
        )
    )
    rb.add_column(Column.from_primitive[DType.int32](qty))
    return rb.build(sb.build())


def _ids(n: Int) -> List[Int]:
    """Field ids 10, 11, ... for `n` columns (not 1..n, so a positional bug and
    a mapping bug cannot cancel)."""
    var out = List[Int]()
    for i in range(n):
        out.append(10 + i)
    return out^


def _required(first: Bool, n: Int) -> List[Bool]:
    """`first` for column 0 and False for the others."""
    var out = List[Bool]()
    for i in range(n):
        out.append(first and i == 0)
    return out^


def _encode_six() raises -> EncodedDataFile:
    return encode_iceberg_data_file(
        _six_column_batch(),
        _ids(6),
        _required(True, 6),
        String("s3://warehouse/db/t/data/u-0.parquet"),
        CompressionCodec.SNAPPY,
    )


def _arrow_error(name: String, at: ArrowType) -> String:
    try:
        _ = iceberg_type_of_arrow(name, at)
    except e:
        return _message(e)
    return String("")


def test_arrow_types_map_to_their_iceberg_types() raises:
    assert_equal(iceberg_type_of_arrow("c", ArrowType.BOOL), "boolean")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.INT32), "int")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.INT64), "long")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.FLOAT32), "float")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.FLOAT64), "double")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.DATE32), "date")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.STRING), "string")
    assert_equal(iceberg_type_of_arrow("c", ArrowType.LARGE_STRING), "string")
    assert_equal(
        iceberg_type_of_arrow("c", ArrowType.DICTIONARY, True), "string"
    )
    assert_equal(ICEBERG_TYPE_UNSUPPORTED, "ICEBERG_TYPE_UNSUPPORTED")
    assert_equal(
        ICEBERG_NULL_IN_REQUIRED_COLUMN, "ICEBERG_NULL_IN_REQUIRED_COLUMN"
    )


def test_every_other_arrow_type_is_refused_by_name() raises:
    assert_equal(
        _arrow_error("small", ArrowType.INT8),
        "ICEBERG_TYPE_UNSUPPORTED: column small has Arrow type int8, which"
        " the Iceberg writer does not write yet",
    )
    assert_equal(
        _arrow_error("u", ArrowType.UINT64),
        "ICEBERG_TYPE_UNSUPPORTED: column u has Arrow type uint64, which the"
        " Iceberg writer does not write yet",
    )
    assert_equal(
        _arrow_error("ts", ArrowType.TIMESTAMP),
        "ICEBERG_TYPE_UNSUPPORTED: column ts has Arrow type timestamp[us],"
        " which the Iceberg writer does not write yet",
    )
    assert_equal(
        _arrow_error("b", ArrowType.BINARY),
        "ICEBERG_TYPE_UNSUPPORTED: column b has Arrow type binary, which the"
        " Iceberg writer does not write yet",
    )
    # A dictionary whose values are not strings has no Iceberg type.
    assert_equal(
        _arrow_error("d", ArrowType.DICTIONARY),
        "ICEBERG_TYPE_UNSUPPORTED: column d has Arrow type dictionary, which"
        " the Iceberg writer does not write yet",
    )


def _string_kinds_batch() raises -> RecordBatch:
    """A dictionary-of-strings column `d` and a large_string column `l`."""
    var codes = PrimitiveArray[DType.int32].allocate(3)
    codes.set(0, Int32(1))
    codes.set(1, Int32(0))
    codes.set(2, Int32(1))
    var dict_values = List[String]()
    dict_values.append(String("x"))
    dict_values.append(String("y"))
    var sda = StringDictionaryArray.from_parts(
        codes^, StringArray.from_strings(dict_values)
    )
    var large = List[String]()
    large.append(String("p"))
    large.append(String("q"))
    large.append(String("r"))
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DICTIONARY, False))
    sb.add_field(Field("l", ArrowType.LARGE_STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_dictionary(sda))
    rb.add_column(Column.from_large_string(LargeStringArray.from_strings(large)))
    return rb.build(sb.build())


def test_dictionary_of_strings_and_large_string_are_string_columns() raises:
    var batch = _string_kinds_batch()
    assert_equal(iceberg_type_of_column(batch, 0), "string")
    assert_equal(iceberg_type_of_column(batch, 1), "string")
    var file = encode_iceberg_data_file(
        batch,
        _ids(2),
        _required(False, 2),
        String("u.parquet"),
        CompressionCodec.UNCOMPRESSED,
    )
    assert_equal(file.info.record_count, 3)
    assert_equal(len(file.info.bounds), 2)
    for i in range(2):
        assert_equal(file.info.bounds[i].field_id, 10 + i)
        assert_false(Bool(file.info.bounds[i].lower))
        assert_false(Bool(file.info.bounds[i].upper))
        assert_equal(file.info.bounds[i].null_count, 0)
        assert_equal(file.info.bounds[i].value_count, 3)
    var md = _footer(file.bytes)
    assert_equal(
        Int(md.schema[1].type.value().value), Int(ParquetType.BYTE_ARRAY.value)
    )
    assert_equal(
        Int(md.schema[2].type.value().value), Int(ParquetType.BYTE_ARRAY.value)
    )


def test_data_file_info_records_the_uri_size_rows_and_bounds() raises:
    var file = _encode_six()
    var info = file.info.copy()
    assert_equal(info.file_path, "s3://warehouse/db/t/data/u-0.parquet")
    assert_equal(info.file_size_in_bytes, len(file.bytes))
    assert_equal(info.record_count, 4)
    assert_equal(info.content, 0)
    assert_equal(len(info.bounds), 6)
    for i in range(6):
        assert_equal(info.bounds[i].field_id, 10 + i)
        assert_equal(info.bounds[i].value_count, 4)

    # id: long, no nulls.
    assert_true(info.bounds[0].lower.value() == serialize_int64(Int64(1)))
    assert_true(info.bounds[0].upper.value() == serialize_int64(Int64(5)))
    assert_equal(info.bounds[0].null_count, 0)
    # name: a string has the counts only.
    assert_false(Bool(info.bounds[1].lower))
    assert_false(Bool(info.bounds[1].upper))
    assert_equal(info.bounds[1].null_count, 1)
    # amount: double with a null.
    assert_true(info.bounds[2].lower.value() == serialize_float64(Float64(-2.0)))
    assert_true(info.bounds[2].upper.value() == serialize_float64(Float64(1.5)))
    assert_equal(info.bounds[2].null_count, 1)
    # flag: boolean with a null.
    assert_true(info.bounds[3].lower.value() == serialize_boolean(False))
    assert_true(info.bounds[3].upper.value() == serialize_boolean(True))
    assert_equal(info.bounds[3].null_count, 1)
    # day: a date is its day count as an int.
    assert_true(info.bounds[4].lower.value() == serialize_int32(Int32(18000)))
    assert_true(info.bounds[4].upper.value() == serialize_int32(Int32(19500)))
    assert_equal(info.bounds[4].null_count, 1)
    # qty: int with a null.
    assert_true(info.bounds[5].lower.value() == serialize_int32(Int32(-1)))
    assert_true(info.bounds[5].upper.value() == serialize_int32(Int32(8)))
    assert_equal(info.bounds[5].null_count, 1)


def test_parquet_carries_field_ids_and_the_tables_requiredness() raises:
    var file = _encode_six()
    var md = _footer(file.bytes)
    assert_equal(len(md.schema), 7)
    assert_false(Bool(md.schema[0].field_id))
    var names = List[String]()
    names.append(String("id"))
    names.append(String("name"))
    names.append(String("amount"))
    names.append(String("flag"))
    names.append(String("day"))
    names.append(String("qty"))
    for i in range(6):
        assert_equal(md.schema[i + 1].name, names[i])
        assert_equal(md.schema[i + 1].field_id.value(), 10 + i)
    # `id` is required by the table although its Arrow field says nullable.
    assert_true(
        md.schema[1].repetition_type.value() == FieldRepetitionType.REQUIRED
    )
    for i in range(1, 6):
        assert_true(
            md.schema[i + 1].repetition_type.value()
            == FieldRepetitionType.OPTIONAL
        )


def test_the_parquet_bytes_decode_to_the_values_written() raises:
    var file = _encode_six()
    var back = decode_parquet_file_from_bytes(_view(Span(file.bytes)))
    assert_equal(back.num_rows(), 4)
    assert_equal(back.num_columns(), 6)
    var id = back.column_as_primitive[DType.int64](0)
    assert_equal(id.get(0), Int64(3))
    assert_equal(id.get(1), Int64(1))
    assert_equal(id.get(2), Int64(2))
    assert_equal(id.get(3), Int64(5))
    var name = back.column_as_string(1)
    assert_equal(name.get(0), "b")
    assert_true(name.is_null(1))
    assert_equal(name.get(2), "a")
    assert_equal(name.get(3), "é")
    var amount = back.column_as_primitive[DType.float64](2)
    assert_equal(amount.get(0), Float64(1.5))
    assert_true(amount.is_null(1))
    assert_equal(amount.get(3), Float64(0.25))
    var flag = back.column_as_boolean(3)
    assert_true(flag.get(0))
    assert_false(flag.get(1))
    assert_true(flag.is_null(2))
    var day = back.column_as_primitive[DType.int32](4)
    assert_equal(day.get(0), Int32(19000))
    assert_true(day.is_null(1))
    assert_true(back.schema.field_arrow_type(4) == ArrowType.DATE32)
    var qty = back.column_as_primitive[DType.int32](5)
    assert_equal(qty.get(1), Int32(8))
    assert_true(qty.is_null(2))


def _two_column_batch(n: Int, all_null_second: Bool) raises -> RecordBatch:
    """`n` rows of a long `id` (0..n-1) and an int `qty` that is null in every
    row when `all_null_second`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("qty", ArrowType.INT32, True))
    var id = PrimitiveArray[DType.int64].allocate(n)
    var qty = PrimitiveArray[DType.int32].allocate(n)
    if all_null_second:
        qty = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        id.set(i, Int64(i))
        if all_null_second:
            qty._set_null(i)
        else:
            qty.set(i, Int32(i))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    rb.add_column(Column.from_primitive[DType.int32](qty))
    return rb.build(sb.build())


def test_an_all_null_column_has_counts_and_no_bounds() raises:
    var file = encode_iceberg_data_file(
        _two_column_batch(3, True),
        _ids(2),
        _required(True, 2),
        String("u.parquet"),
        CompressionCodec.SNAPPY,
    )
    assert_equal(file.info.record_count, 3)
    assert_true(Bool(file.info.bounds[0].lower))
    assert_false(Bool(file.info.bounds[1].lower))
    assert_false(Bool(file.info.bounds[1].upper))
    assert_equal(file.info.bounds[1].null_count, 3)
    assert_equal(file.info.bounds[1].value_count, 3)


def test_a_zero_row_batch_is_still_a_parquet_file() raises:
    var file = encode_iceberg_data_file(
        _two_column_batch(0, False),
        _ids(2),
        _required(True, 2),
        String("u.parquet"),
        CompressionCodec.SNAPPY,
    )
    assert_equal(file.info.record_count, 0)
    assert_equal(file.info.file_size_in_bytes, len(file.bytes))
    assert_equal(len(file.info.bounds), 2)
    for i in range(2):
        assert_false(Bool(file.info.bounds[i].lower))
        assert_false(Bool(file.info.bounds[i].upper))
        assert_equal(file.info.bounds[i].null_count, 0)
        assert_equal(file.info.bounds[i].value_count, 0)
    assert_equal(len(_footer(file.bytes).schema), 3)
    var back = decode_parquet_file_from_bytes(_view(Span(file.bytes)))
    assert_equal(back.num_rows(), 0)


def test_float_bounds_skip_nan_and_cover_both_zeros() raises:
    var nan64 = Float64(0) / Float64(0)
    var nan32 = Float32(0) / Float32(0)
    var neg_zero64 = bitcast[DType.float64, 1](UInt64(0x8000000000000000))
    var neg_zero32 = bitcast[DType.float32, 1](UInt32(0x80000000))
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    sb.add_field(Field("only_nan", ArrowType.FLOAT64, True))
    var d = PrimitiveArray[DType.float64].allocate(4)
    d.set(0, nan64)
    d.set(1, Float64(0))
    d.set(2, neg_zero64)
    d.set(3, Float64(2.5))
    var f4 = PrimitiveArray[DType.float32].allocate(4)
    f4.set(0, nan32)
    f4.set(1, Float32(-3.5))
    f4.set(2, Float32(0))
    f4.set(3, neg_zero32)
    var only4 = PrimitiveArray[DType.float64].allocate(4)
    for i in range(4):
        only4.set(i, nan64)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.float64](d))
    rb.add_column(Column.from_primitive[DType.float32](f4))
    rb.add_column(Column.from_primitive[DType.float64](only4))
    var file = encode_iceberg_data_file(
        rb.build(sb.build()),
        _ids(3),
        _required(False, 3),
        String("u.parquet"),
        CompressionCodec.SNAPPY,
    )
    var info = file.info.copy()
    # Lower 0 is written as -0.0 and upper 2.5 as is; NaN is no bound.
    assert_true(info.bounds[0].lower.value() == serialize_float64(neg_zero64))
    assert_true(info.bounds[0].upper.value() == serialize_float64(Float64(2.5)))
    assert_true(info.bounds[1].lower.value() == serialize_float32(Float32(-3.5)))
    # Upper bound of {-3.5, 0, -0.0} is +0.0.
    assert_true(info.bounds[1].upper.value() == serialize_float32(Float32(0)))
    assert_false(Bool(info.bounds[2].lower))
    assert_false(Bool(info.bounds[2].upper))
    assert_equal(info.bounds[2].null_count, 0)
    assert_equal(info.bounds[2].value_count, 4)


def _required_column_with_a_null(with_null: Bool) raises -> RecordBatch:
    """A long `id` that holds a validity buffer, with row 1 null when
    `with_null`, and a long `v`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var id = PrimitiveArray[DType.int64].allocate_nullable(3)
    var v = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        id.set(i, Int64(i))
        v.set(i, Int64(i))
    if with_null:
        id._set_null(1)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    rb.add_column(Column.from_primitive[DType.int64](v))
    return rb.build(sb.build())


def test_a_null_in_a_required_column_is_refused_by_name() raises:
    var msg = String("")
    try:
        _ = encode_iceberg_data_file(
            _required_column_with_a_null(True),
            _ids(2),
            _required(True, 2),
            String("u.parquet"),
            CompressionCodec.SNAPPY,
        )
    except e:
        msg = _message(e)
    assert_equal(
        msg,
        "ICEBERG_NULL_IN_REQUIRED_COLUMN: column id is required and the rows"
        " hold 1 null(s)",
    )
    # The same rows are fine when the column is optional.
    var ok = encode_iceberg_data_file(
        _required_column_with_a_null(True),
        _ids(2),
        _required(False, 2),
        String("u.parquet"),
        CompressionCodec.SNAPPY,
    )
    assert_equal(ok.info.bounds[0].null_count, 1)
    var md = _footer(ok.bytes)
    assert_true(
        md.schema[1].repetition_type.value() == FieldRepetitionType.OPTIONAL
    )


def test_a_required_column_with_a_validity_buffer_and_no_null_is_accepted() raises:
    var file = encode_iceberg_data_file(
        _required_column_with_a_null(False),
        _ids(2),
        _required(True, 2),
        String("u.parquet"),
        CompressionCodec.SNAPPY,
    )
    assert_equal(file.info.bounds[0].null_count, 0)
    assert_true(
        _footer(file.bytes).schema[1].repetition_type.value()
        == FieldRepetitionType.REQUIRED
    )


def test_an_unsupported_type_is_refused_before_the_null_check() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("small", ArrowType.INT8, True))
    var id = PrimitiveArray[DType.int64].allocate_nullable(2)
    id._set_null(0)
    var small = PrimitiveArray[DType.int8].allocate(2)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](id))
    rb.add_column(Column.from_primitive[DType.int8](small))
    var msg = String("")
    try:
        _ = encode_iceberg_data_file(
            rb.build(sb.build()),
            _ids(2),
            _required(True, 2),
            String("u.parquet"),
            CompressionCodec.SNAPPY,
        )
    except e:
        msg = _message(e)
    assert_equal(
        msg,
        "ICEBERG_TYPE_UNSUPPORTED: column small has Arrow type int8, which"
        " the Iceberg writer does not write yet",
    )


def test_a_batch_with_no_columns_or_a_wrong_length_list_is_refused() raises:
    var empty_builder = RecordBatchBuilder()
    var empty_schema = SchemaBuilder()
    var empty = empty_builder.build(empty_schema.build())
    var msg = String("")
    try:
        _ = encode_iceberg_data_file(
            empty,
            List[Int](),
            List[Bool](),
            String("u.parquet"),
            CompressionCodec.SNAPPY,
        )
    except e:
        msg = _message(e)
    assert_equal(msg, "encode_iceberg_data_file: batch has no columns")

    var msg2 = String("")
    try:
        _ = encode_iceberg_data_file(
            _two_column_batch(2, False),
            _ids(3),
            _required(True, 2),
            String("u.parquet"),
            CompressionCodec.SNAPPY,
        )
    except e:
        msg2 = _message(e)
    assert_equal(
        msg2,
        "encode_iceberg_data_file: 3 field id(s) and 2 required flag(s) for 2"
        " column(s)",
    )

    var msg3 = String("")
    try:
        _ = encode_iceberg_data_file(
            _two_column_batch(2, False),
            _ids(2),
            _required(True, 1),
            String("u.parquet"),
            CompressionCodec.SNAPPY,
        )
    except e:
        msg3 = _message(e)
    assert_equal(
        msg3,
        "encode_iceberg_data_file: 2 field id(s) and 1 required flag(s) for 2"
        " column(s)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
