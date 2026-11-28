# =============================================================================
# test_orc_file_schema: an ORC file's tail and schema, from the Footer alone
# =============================================================================
#
# What each test proves:
#
#   * test_the_schema_is_the_readers_for_every_codec: for a file written with
#     each codec the writer has (NONE, ZLIB, SNAPPY, LZ4, ZSTD),
#     `read_orc_bytes_schema` gives the names, types and nullability that
#     `read_orc_bytes` gives the same bytes, in file order, and `read_orc_tail`
#     gives the codec and the row count. Catches a tail parse that reads only
#     an uncompressed Footer (four codecs would raise) and a schema that
#     differs from the reader's.
#   * test_the_schema_reads_no_stripe: every byte between the header and the
#     Footer (the stripes) overwritten, the schema and the row count are still
#     read, while a full read of the same bytes raises. Catches a schema read
#     that decodes rows.
#   * test_a_nested_file_has_the_nested_paths_schema: a file of no stripe whose
#     columns are a long, a struct and a list has the schema the nested read
#     path gives (STRUCT and LIST top-level columns, in file order).
#   * test_a_nested_root_without_names_names_its_columns_by_position: a nested
#     file whose root struct names no field has the reader's `_col0`, `_col1`.
#   * test_an_acid_file_has_its_row_columns: a Hive ACID file's schema is its
#     `row` struct's columns, lifted, as the reader gives them (the five
#     metadata columns suppressed).
#   * test_bytes_that_are_not_orc_are_refused_by_name: bytes without the
#     leading `ORC` magic, and bytes too short to hold a PostScript, raise
#     `OrcSchemaError.MALFORMED_PROTOBUF`, never a schema.
#   * test_a_root_that_is_not_a_struct_is_refused: a Footer whose root type is
#     a long raises `OrcDecodeError.ROOT_NOT_STRUCT`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from orc import (
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_ZSTD,
    ORC_KIND_INT,
    ORC_KIND_LIST,
    ORC_KIND_LONG,
    ORC_KIND_STRING,
    ORC_KIND_STRUCT,
    OrcWriterOptions,
    encode_footer,
    encode_post_script,
    encode_type_node,
    read_orc_bytes,
    read_orc_bytes_schema,
    read_orc_tail,
    write_orc_bytes,
)


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("score", ArrowType.FLOAT64, False))
    var ids: List[Int64] = [1, 2, 3, 4, 5]
    var names: List[String] = ["a", "bb", "ccc", "dddd", "e"]
    var scores: List[Float64] = [0.5, 1.5, 2.5, 3.5, 4.5]
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids)
        )
    )
    b.add_column(Column.from_string(StringArray.from_strings(names)))
    b.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(scores)
        )
    )
    return b.build(sb.build())


def _same_schema(got: Schema, want: Schema, label: String) raises:
    assert_equal(got.num_columns(), want.num_columns(), label + ": columns")
    for i in range(want.num_columns()):
        var at = label + ": column " + String(i)
        assert_equal(got.field_name(i), want.field_name(i), at)
        assert_true(
            got.field_arrow_type(i) == want.field_arrow_type(i),
            at + ": " + String(got.field_arrow_type(i)),
        )
        assert_equal(got.field_nullable(i), want.field_nullable(i), at)


def _check_codec(codec: Int, label: String) raises:
    var bytes = write_orc_bytes(_batch(), OrcWriterOptions(codec, 10000, "UTC"))
    var schema = read_orc_bytes_schema(Span(bytes))
    _same_schema(schema, read_orc_bytes(Span(bytes)).schema, label)
    assert_equal(schema.field_name(0), "id", label)
    assert_equal(schema.field_name(1), "name", label)
    assert_equal(schema.field_name(2), "score", label)
    assert_true(schema.field_arrow_type(1) == ArrowType.STRING, label)
    var tail = read_orc_tail(Span(bytes))
    assert_equal(tail.post_script.compression, codec, label + ": codec")
    assert_equal(tail.footer.number_of_rows, 5, label + ": rows")


def test_the_schema_is_the_readers_for_every_codec() raises:
    _check_codec(ORC_COMPRESSION_NONE, "none")
    _check_codec(ORC_COMPRESSION_ZLIB, "zlib")
    _check_codec(ORC_COMPRESSION_SNAPPY, "snappy")
    _check_codec(ORC_COMPRESSION_LZ4, "lz4")
    _check_codec(ORC_COMPRESSION_ZSTD, "zstd")


def test_the_schema_reads_no_stripe() raises:
    var bytes = write_orc_bytes(
        _batch(), OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, "UTC")
    )
    var tail = read_orc_tail(Span(bytes))
    # The stripes lie between the 3-byte header and the file metadata.
    for i in range(3, tail.metadata_start):
        bytes[i] = UInt8(0xFF)
    var raised = False
    try:
        _ = read_orc_bytes(Span(bytes))
    except:
        raised = True
    assert_true(raised, "a full read of overwritten stripes raises")
    var schema = read_orc_bytes_schema(Span(bytes))
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(2), "score")
    assert_equal(read_orc_tail(Span(bytes)).footer.number_of_rows, 5)


def _no_names() -> List[String]:
    return List[String]()


def _no_stripe_file(var types: List[List[UInt8]]) -> List[UInt8]:
    """An uncompressed ORC file of no stripe and no row: the magic, a Footer
    of `types`, the PostScript and its length byte."""
    var footer = encode_footer(
        3, 0, List[List[UInt8]](), types, 0, List[List[UInt8]](), 0
    )
    var ps = encode_post_script(
        len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORC"
    )
    var out: List[UInt8] = [UInt8(ord("O")), UInt8(ord("R")), UInt8(ord("C"))]
    var ps_len = len(ps)
    out.extend(footer^)
    out.extend(ps^)
    out.append(UInt8(ps_len))
    return out^


def test_a_nested_file_has_the_nested_paths_schema() raises:
    # struct<id:bigint, info:struct<a:int>, tags:array<string>>
    var types = List[List[UInt8]]()
    var root_children: List[Int] = [1, 2, 4]
    var root_names: List[String] = ["id", "info", "tags"]
    types.append(encode_type_node(ORC_KIND_STRUCT, root_children, root_names, 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_LONG, List[Int](), _no_names(), 0, 0, 0))
    var info_children: List[Int] = [3]
    var info_names: List[String] = ["a"]
    types.append(encode_type_node(ORC_KIND_STRUCT, info_children, info_names, 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_INT, List[Int](), _no_names(), 0, 0, 0))
    var tags_children: List[Int] = [5]
    types.append(encode_type_node(ORC_KIND_LIST, tags_children, _no_names(), 0, 0, 0))
    types.append(encode_type_node(ORC_KIND_STRING, List[Int](), _no_names(), 0, 0, 0))
    var bytes = _no_stripe_file(types^)
    var schema = read_orc_bytes_schema(Span(bytes))
    _same_schema(schema, read_orc_bytes(Span(bytes)).schema, "nested")
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(1), "info")
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.STRUCT)
    assert_true(schema.field_arrow_type(2) == ArrowType.LIST)
    assert_equal(read_orc_tail(Span(bytes)).footer.number_of_rows, 0)



def _leaf(kind: Int) -> List[UInt8]:
    return encode_type_node(kind, List[Int](), _no_names(), 0, 0, 0)


def test_a_nested_root_without_names_names_its_columns_by_position() raises:
    # struct<bigint, struct<a:int>> with no root field names.
    var types = List[List[UInt8]]()
    var root_children: List[Int] = [1, 2]
    types.append(encode_type_node(ORC_KIND_STRUCT, root_children, _no_names(), 0, 0, 0))
    types.append(_leaf(ORC_KIND_LONG))
    var inner: List[Int] = [3]
    var inner_names: List[String] = ["a"]
    types.append(encode_type_node(ORC_KIND_STRUCT, inner, inner_names, 0, 0, 0))
    types.append(_leaf(ORC_KIND_INT))
    var bytes = _no_stripe_file(types^)
    var schema = read_orc_bytes_schema(Span(bytes))
    _same_schema(schema, read_orc_bytes(Span(bytes)).schema, "unnamed")
    assert_equal(schema.field_name(0), "_col0")
    assert_equal(schema.field_name(1), "_col1")


def test_an_acid_file_has_its_row_columns() raises:
    var types = List[List[UInt8]]()
    var children: List[Int] = [1, 2, 3, 4, 5, 6]
    var names: List[String] = [
        "operation",
        "originalTransaction",
        "bucket",
        "rowId",
        "currentTransaction",
        "row",
    ]
    types.append(encode_type_node(ORC_KIND_STRUCT, children, names, 0, 0, 0))
    types.append(_leaf(ORC_KIND_INT))
    types.append(_leaf(ORC_KIND_LONG))
    types.append(_leaf(ORC_KIND_INT))
    types.append(_leaf(ORC_KIND_LONG))
    types.append(_leaf(ORC_KIND_LONG))
    var row_children: List[Int] = [7, 8]
    var row_names: List[String] = ["a", "b"]
    types.append(encode_type_node(ORC_KIND_STRUCT, row_children, row_names, 0, 0, 0))
    types.append(_leaf(ORC_KIND_LONG))
    types.append(_leaf(ORC_KIND_STRING))
    var bytes = _no_stripe_file(types^)
    var schema = read_orc_bytes_schema(Span(bytes))
    _same_schema(schema, read_orc_bytes(Span(bytes)).schema, "acid")
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "a")
    assert_equal(schema.field_name(1), "b")
    assert_true(schema.field_arrow_type(1) == ArrowType.STRING)

def _raises_with(bytes: List[UInt8], want: String) raises:
    var message = String("")
    try:
        _ = read_orc_bytes_schema(Span(bytes))
    except e:
        message = String(e)
    assert_true(message.startswith(want), message)


def test_bytes_that_are_not_orc_are_refused_by_name() raises:
    var parquet: List[UInt8] = [
        UInt8(ord("P")), UInt8(ord("A")), UInt8(ord("R")), UInt8(ord("1")),
        0, 0, 0, 0, 0, 0, UInt8(4),
    ]
    _raises_with(parquet, "OrcSchemaError.MALFORMED_PROTOBUF")
    var short: List[UInt8] = [UInt8(ord("O")), UInt8(ord("R"))]
    _raises_with(short, "OrcSchemaError.MALFORMED_PROTOBUF")
    var message = String("")
    try:
        _ = read_orc_tail(Span(short))
    except e:
        message = String(e)
    assert_true(message.startswith("OrcSchemaError.MALFORMED_PROTOBUF"), message)


def test_a_root_that_is_not_a_struct_is_refused() raises:
    var types = List[List[UInt8]]()
    types.append(encode_type_node(ORC_KIND_LONG, List[Int](), _no_names(), 0, 0, 0))
    _raises_with(_no_stripe_file(types^), "OrcDecodeError.ROOT_NOT_STRUCT")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
