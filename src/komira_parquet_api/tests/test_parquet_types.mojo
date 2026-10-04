# =============================================================================
# Tests for Parquet format types and metadata structs
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_parquet_api import (
    PageType,
    Encoding,
    CompressionCodec,
    ParquetType,
    FieldRepetitionType,
    BoundaryOrder,
    KeyValue,
    Statistics,
    SchemaElement,
    PageHeader,
    ColumnMetaData,
    ColumnChunk,
    SortingColumn,
    RowGroup,
    FileMetaData,
)


# =============================================================================
# PageType tests
# =============================================================================


def test_page_type_equality() raises:
    """PageType constants compare equal to themselves and unequal to others."""
    assert_true(PageType.DATA_PAGE == PageType.DATA_PAGE)
    assert_true(PageType.DICTIONARY_PAGE == PageType.DICTIONARY_PAGE)
    assert_false(PageType.DATA_PAGE == PageType.DICTIONARY_PAGE)
    assert_true(PageType.DATA_PAGE != PageType.INDEX_PAGE)
    assert_true(PageType.DATA_PAGE_V2 == PageType.DATA_PAGE_V2)


def test_page_type_write() raises:
    """PageType writes human-readable names."""
    assert_equal(String(PageType.DATA_PAGE), "DATA_PAGE")
    assert_equal(String(PageType.INDEX_PAGE), "INDEX_PAGE")
    assert_equal(String(PageType.DICTIONARY_PAGE), "DICTIONARY_PAGE")
    assert_equal(String(PageType.DATA_PAGE_V2), "DATA_PAGE_V2")


def test_page_type_values() raises:
    """PageType numeric values match the Thrift spec."""
    assert_equal(Int(PageType.DATA_PAGE.value), 0)
    assert_equal(Int(PageType.INDEX_PAGE.value), 1)
    assert_equal(Int(PageType.DICTIONARY_PAGE.value), 2)
    assert_equal(Int(PageType.DATA_PAGE_V2.value), 3)


# =============================================================================
# Encoding tests
# =============================================================================


def test_encoding_equality() raises:
    """Encoding constants compare equal and unequal correctly."""
    assert_true(Encoding.PLAIN == Encoding.PLAIN)
    assert_true(Encoding.RLE_DICTIONARY == Encoding.RLE_DICTIONARY)
    assert_false(Encoding.PLAIN == Encoding.RLE)
    assert_true(Encoding.PLAIN != Encoding.DELTA_BINARY_PACKED)


def test_encoding_all_variants_write() raises:
    """Encoding writes correct names for all variants."""
    assert_equal(String(Encoding.PLAIN), "PLAIN")
    assert_equal(String(Encoding.PLAIN_DICTIONARY), "PLAIN_DICTIONARY")
    assert_equal(String(Encoding.RLE), "RLE")
    assert_equal(String(Encoding.BIT_PACKED), "BIT_PACKED")
    assert_equal(String(Encoding.DELTA_BINARY_PACKED), "DELTA_BINARY_PACKED")
    assert_equal(String(Encoding.DELTA_LENGTH_BYTE_ARRAY), "DELTA_LENGTH_BYTE_ARRAY")
    assert_equal(String(Encoding.DELTA_BYTE_ARRAY), "DELTA_BYTE_ARRAY")
    assert_equal(String(Encoding.RLE_DICTIONARY), "RLE_DICTIONARY")
    assert_equal(String(Encoding.BYTE_STREAM_SPLIT), "BYTE_STREAM_SPLIT")


def test_encoding_values() raises:
    """Encoding numeric values match the Thrift spec (note: gap at 1)."""
    assert_equal(Int(Encoding.PLAIN.value), 0)
    assert_equal(Int(Encoding.PLAIN_DICTIONARY.value), 2)
    assert_equal(Int(Encoding.RLE.value), 3)
    assert_equal(Int(Encoding.BIT_PACKED.value), 4)
    assert_equal(Int(Encoding.DELTA_BINARY_PACKED.value), 5)
    assert_equal(Int(Encoding.RLE_DICTIONARY.value), 8)
    assert_equal(Int(Encoding.BYTE_STREAM_SPLIT.value), 9)


# =============================================================================
# CompressionCodec tests
# =============================================================================


def test_compression_codec_equality() raises:
    """CompressionCodec constants compare correctly."""
    assert_true(CompressionCodec.UNCOMPRESSED == CompressionCodec.UNCOMPRESSED)
    assert_true(CompressionCodec.SNAPPY == CompressionCodec.SNAPPY)
    assert_false(CompressionCodec.SNAPPY == CompressionCodec.ZSTD)
    assert_true(CompressionCodec.GZIP != CompressionCodec.LZ4_RAW)


def test_compression_codec_all_variants_write() raises:
    """CompressionCodec writes correct names for all variants."""
    assert_equal(String(CompressionCodec.UNCOMPRESSED), "UNCOMPRESSED")
    assert_equal(String(CompressionCodec.SNAPPY), "SNAPPY")
    assert_equal(String(CompressionCodec.GZIP), "GZIP")
    assert_equal(String(CompressionCodec.LZO), "LZO")
    assert_equal(String(CompressionCodec.BROTLI), "BROTLI")
    assert_equal(String(CompressionCodec.LZ4), "LZ4")
    assert_equal(String(CompressionCodec.ZSTD), "ZSTD")
    assert_equal(String(CompressionCodec.LZ4_RAW), "LZ4_RAW")


# =============================================================================
# ParquetType tests
# =============================================================================


def test_parquet_type_all_variants() raises:
    """ParquetType covers all 8 physical types with correct values."""
    assert_equal(Int(ParquetType.BOOLEAN.value), 0)
    assert_equal(Int(ParquetType.INT32.value), 1)
    assert_equal(Int(ParquetType.INT64.value), 2)
    assert_equal(Int(ParquetType.INT96.value), 3)
    assert_equal(Int(ParquetType.FLOAT.value), 4)
    assert_equal(Int(ParquetType.DOUBLE.value), 5)
    assert_equal(Int(ParquetType.BYTE_ARRAY.value), 6)
    assert_equal(Int(ParquetType.FIXED_LEN_BYTE_ARRAY.value), 7)


def test_parquet_type_equality() raises:
    """ParquetType equality and inequality."""
    assert_true(ParquetType.INT64 == ParquetType.INT64)
    assert_false(ParquetType.INT32 == ParquetType.INT64)
    assert_true(ParquetType.FLOAT != ParquetType.DOUBLE)
    assert_true(ParquetType.BYTE_ARRAY == ParquetType.BYTE_ARRAY)


def test_parquet_type_write() raises:
    """ParquetType writes correct names."""
    assert_equal(String(ParquetType.BOOLEAN), "BOOLEAN")
    assert_equal(String(ParquetType.INT32), "INT32")
    assert_equal(String(ParquetType.INT64), "INT64")
    assert_equal(String(ParquetType.INT96), "INT96")
    assert_equal(String(ParquetType.FLOAT), "FLOAT")
    assert_equal(String(ParquetType.DOUBLE), "DOUBLE")
    assert_equal(String(ParquetType.BYTE_ARRAY), "BYTE_ARRAY")
    assert_equal(String(ParquetType.FIXED_LEN_BYTE_ARRAY), "FIXED_LEN_BYTE_ARRAY")


def test_parquet_type_byte_width() raises:
    """ParquetType.byte_width returns correct sizes for fixed-width types."""
    assert_equal(ParquetType.BOOLEAN.byte_width().value(), 1)
    assert_equal(ParquetType.INT32.byte_width().value(), 4)
    assert_equal(ParquetType.FLOAT.byte_width().value(), 4)
    assert_equal(ParquetType.INT64.byte_width().value(), 8)
    assert_equal(ParquetType.DOUBLE.byte_width().value(), 8)
    assert_equal(ParquetType.INT96.byte_width().value(), 12)
    # Variable-length types return None
    assert_false(ParquetType.BYTE_ARRAY.byte_width())
    assert_false(ParquetType.FIXED_LEN_BYTE_ARRAY.byte_width())


# =============================================================================
# FieldRepetitionType tests
# =============================================================================


def test_field_repetition_type() raises:
    """FieldRepetitionType covers REQUIRED, OPTIONAL, REPEATED."""
    assert_true(FieldRepetitionType.REQUIRED == FieldRepetitionType.REQUIRED)
    assert_true(FieldRepetitionType.OPTIONAL != FieldRepetitionType.REPEATED)
    assert_equal(String(FieldRepetitionType.REQUIRED), "REQUIRED")
    assert_equal(String(FieldRepetitionType.OPTIONAL), "OPTIONAL")
    assert_equal(String(FieldRepetitionType.REPEATED), "REPEATED")
    assert_equal(Int(FieldRepetitionType.REQUIRED.value), 0)
    assert_equal(Int(FieldRepetitionType.OPTIONAL.value), 1)
    assert_equal(Int(FieldRepetitionType.REPEATED.value), 2)


# =============================================================================
# BoundaryOrder tests
# =============================================================================


def test_boundary_order() raises:
    """BoundaryOrder covers UNORDERED, ASCENDING, DESCENDING."""
    assert_true(BoundaryOrder.UNORDERED == BoundaryOrder.UNORDERED)
    assert_true(BoundaryOrder.ASCENDING != BoundaryOrder.DESCENDING)
    assert_equal(String(BoundaryOrder.UNORDERED), "UNORDERED")
    assert_equal(String(BoundaryOrder.ASCENDING), "ASCENDING")
    assert_equal(String(BoundaryOrder.DESCENDING), "DESCENDING")


# =============================================================================
# SchemaElement tests
# =============================================================================


def test_schema_element_leaf() raises:
    """SchemaElement for a leaf INT64 column."""
    var elem = SchemaElement(
        name="id",
        type=ParquetType.INT64,
        repetition_type=FieldRepetitionType.REQUIRED,
        num_children=0,
    )
    assert_equal(elem.name, "id")
    assert_true(elem.type.value() == ParquetType.INT64)
    assert_true(elem.repetition_type.value() == FieldRepetitionType.REQUIRED)
    assert_equal(elem.num_children, 0)
    assert_false(elem.type_length)
    assert_false(elem.scale)
    assert_false(elem.precision)


def test_schema_element_group() raises:
    """SchemaElement for a group node (root or nested)."""
    var elem = SchemaElement(name="schema", num_children=3)
    assert_equal(elem.name, "schema")
    assert_equal(elem.num_children, 3)
    assert_false(elem.type)  # group nodes have no physical type
    assert_false(elem.repetition_type)


def test_schema_element_decimal() raises:
    """SchemaElement for a Decimal column with scale and precision."""
    var elem = SchemaElement(
        name="price",
        type=ParquetType.FIXED_LEN_BYTE_ARRAY,
        type_length=16,
        repetition_type=FieldRepetitionType.OPTIONAL,
        num_children=0,
        converted_type=5,  # DECIMAL
        scale=2,
        precision=18,
    )
    assert_equal(elem.name, "price")
    assert_true(elem.type.value() == ParquetType.FIXED_LEN_BYTE_ARRAY)
    assert_equal(elem.type_length.value(), 16)
    assert_equal(elem.converted_type.value(), 5)
    assert_equal(elem.scale.value(), 2)
    assert_equal(elem.precision.value(), 18)


# =============================================================================
# Statistics tests
# =============================================================================


def test_statistics_empty() raises:
    """Default Statistics has no values set."""
    var stats = Statistics(null_count=None)
    assert_false(stats.null_count)
    assert_false(stats.distinct_count)
    assert_false(stats.min_value)
    assert_false(stats.max_value)
    assert_true(stats.is_min_value_exact)
    assert_true(stats.is_max_value_exact)


def test_statistics_with_counts() raises:
    """Statistics with null and distinct counts."""
    var stats = Statistics(
        null_count=42,
        distinct_count=1000,
    )
    assert_equal(stats.null_count.value(), 42)
    assert_equal(stats.distinct_count.value(), 1000)
    assert_false(stats.min_value)
    assert_false(stats.max_value)


def test_statistics_with_min_max() raises:
    """Statistics with min/max byte values."""
    var min_bytes: List[UInt8] = [UInt8(0), UInt8(0), UInt8(0), UInt8(1)]
    var max_bytes: List[UInt8] = [UInt8(0), UInt8(0), UInt8(3), UInt8(232)]
    var stats = Statistics(
        null_count=0,
        min_value=min_bytes^,
        max_value=max_bytes^,
        is_min_value_exact=True,
        is_max_value_exact=False,
    )
    assert_equal(stats.null_count.value(), 0)
    assert_equal(len(stats.min_value.value()), 4)
    assert_equal(len(stats.max_value.value()), 4)
    assert_true(stats.is_min_value_exact)
    assert_false(stats.is_max_value_exact)


# =============================================================================
# PageHeader tests
# =============================================================================


def test_page_header_data_page() raises:
    """PageHeader for a DATA_PAGE with PLAIN encoding."""
    var hdr = PageHeader(
        type=PageType.DATA_PAGE,
        uncompressed_page_size=65536,
        compressed_page_size=32768,
        num_values=8192,
        encoding=Encoding.PLAIN,
    )
    assert_true(hdr.type == PageType.DATA_PAGE)
    assert_equal(hdr.uncompressed_page_size, 65536)
    assert_equal(hdr.compressed_page_size, 32768)
    assert_equal(hdr.num_values, 8192)
    assert_true(hdr.encoding == Encoding.PLAIN)
    assert_true(hdr.definition_level_encoding == Encoding.RLE)
    assert_true(hdr.repetition_level_encoding == Encoding.RLE)


def test_page_header_dictionary_page() raises:
    """PageHeader for a DICTIONARY_PAGE."""
    var hdr = PageHeader(
        type=PageType.DICTIONARY_PAGE,
        uncompressed_page_size=4096,
        compressed_page_size=2048,
        num_values=256,
        encoding=Encoding.PLAIN,
    )
    assert_true(hdr.type == PageType.DICTIONARY_PAGE)
    assert_equal(hdr.num_values, 256)


# =============================================================================
# ColumnMetaData tests
# =============================================================================


def test_column_metadata_construction() raises:
    """ColumnMetaData with all required fields."""
    var encodings: List[Encoding] = [Encoding.PLAIN, Encoding.RLE_DICTIONARY]
    var path: List[String] = ["col_a"]
    var cmd = ColumnMetaData(
        type=ParquetType.INT64,
        encodings=encodings^,
        path_in_schema=path^,
        codec=CompressionCodec.SNAPPY,
        num_values=100000,
        total_uncompressed_size=800000,
        total_compressed_size=400000,
        data_page_offset=1024,
    )
    assert_true(cmd.type == ParquetType.INT64)
    assert_equal(len(cmd.encodings), 2)
    assert_true(cmd.encodings[0] == Encoding.PLAIN)
    assert_true(cmd.encodings[1] == Encoding.RLE_DICTIONARY)
    assert_equal(cmd.path_in_schema[0], "col_a")
    assert_true(cmd.codec == CompressionCodec.SNAPPY)
    assert_equal(cmd.num_values, 100000)
    assert_equal(cmd.total_uncompressed_size, 800000)
    assert_equal(cmd.total_compressed_size, 400000)
    assert_equal(cmd.data_page_offset, 1024)
    assert_false(cmd.index_page_offset)
    assert_false(cmd.dictionary_page_offset)
    assert_false(cmd.statistics)


def test_column_metadata_with_dict_and_stats() raises:
    """ColumnMetaData with dictionary page offset and statistics."""
    var encodings: List[Encoding] = [Encoding.RLE_DICTIONARY, Encoding.PLAIN]
    var path: List[String] = ["name"]
    var stats = Statistics(null_count=5, distinct_count=100)
    var cmd = ColumnMetaData(
        type=ParquetType.BYTE_ARRAY,
        encodings=encodings^,
        path_in_schema=path^,
        codec=CompressionCodec.ZSTD,
        num_values=50000,
        total_uncompressed_size=500000,
        total_compressed_size=250000,
        data_page_offset=4096,
        dictionary_page_offset=2048,
        statistics=stats^,
    )
    assert_true(cmd.type == ParquetType.BYTE_ARRAY)
    assert_true(cmd.codec == CompressionCodec.ZSTD)
    assert_equal(cmd.dictionary_page_offset.value(), 2048)
    assert_equal(cmd.statistics.value().null_count.value(), 5)
    assert_equal(cmd.statistics.value().distinct_count.value(), 100)


# =============================================================================
# RowGroup + ColumnChunk tests
# =============================================================================


def test_row_group_with_column_chunks() raises:
    """RowGroup containing multiple column chunks."""
    # Build two column chunks
    var encodings1: List[Encoding] = [Encoding.PLAIN]
    var path1: List[String] = ["id"]
    var cmd1 = ColumnMetaData(
        type=ParquetType.INT64,
        encodings=encodings1^,
        path_in_schema=path1^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=1000,
        total_uncompressed_size=8000,
        total_compressed_size=8000,
        data_page_offset=100,
    )
    var cc1 = ColumnChunk(file_offset=100, meta_data=cmd1^)

    var encodings2: List[Encoding] = [Encoding.RLE_DICTIONARY, Encoding.PLAIN]
    var path2: List[String] = ["name"]
    var cmd2 = ColumnMetaData(
        type=ParquetType.BYTE_ARRAY,
        encodings=encodings2^,
        path_in_schema=path2^,
        codec=CompressionCodec.SNAPPY,
        num_values=1000,
        total_uncompressed_size=20000,
        total_compressed_size=10000,
        data_page_offset=8100,
    )
    var cc2 = ColumnChunk(file_offset=8100, meta_data=cmd2^)

    var columns = List[ColumnChunk]()
    columns.append(cc1^)
    columns.append(cc2^)

    var rg = RowGroup(
        columns=columns^,
        total_byte_size=18000,
        num_rows=1000,
    )

    assert_equal(len(rg.columns), 2)
    assert_equal(rg.num_rows, 1000)
    assert_equal(rg.total_byte_size, 18000)
    assert_true(rg.columns[0].meta_data.type == ParquetType.INT64)
    assert_true(rg.columns[1].meta_data.type == ParquetType.BYTE_ARRAY)
    assert_false(rg.sorting_columns)


# =============================================================================
# FileMetaData tests
# =============================================================================


def test_file_metadata_construction() raises:
    """FileMetaData with schema, row groups, and key-value metadata."""
    # Build a simple schema: root group with 2 leaf columns
    var root = SchemaElement(name="schema", num_children=2)
    var col1 = SchemaElement(
        name="id",
        type=ParquetType.INT64,
        repetition_type=FieldRepetitionType.REQUIRED,
    )
    var col2 = SchemaElement(
        name="value",
        type=ParquetType.DOUBLE,
        repetition_type=FieldRepetitionType.OPTIONAL,
    )
    var schema = List[SchemaElement]()
    schema.append(root^)
    schema.append(col1^)
    schema.append(col2^)

    # Build a row group with one column chunk (minimal)
    var encodings: List[Encoding] = [Encoding.PLAIN]
    var path: List[String] = ["id"]
    var cmd = ColumnMetaData(
        type=ParquetType.INT64,
        encodings=encodings^,
        path_in_schema=path^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=500,
        total_uncompressed_size=4000,
        total_compressed_size=4000,
        data_page_offset=100,
    )
    var cc = ColumnChunk(file_offset=100, meta_data=cmd^)
    var columns = List[ColumnChunk]()
    columns.append(cc^)
    var rg = RowGroup(columns=columns^, total_byte_size=4000, num_rows=500)
    var row_groups = List[RowGroup]()
    row_groups.append(rg^)

    # Key-value metadata
    var kv1 = KeyValue("ARROW:schema", String("...base64..."))
    var kv2 = KeyValue("writer.version", String("0.4.0"))
    var kvs = List[KeyValue]()
    kvs.append(kv1^)
    kvs.append(kv2^)

    var fmd = FileMetaData(
        version=2,
        schema=schema^,
        num_rows=500,
        row_groups=row_groups^,
        key_value_metadata=kvs^,
        created_by=String("example-writer 0.4.0"),
    )

    assert_equal(fmd.version, 2)
    assert_equal(len(fmd.schema), 3)
    assert_equal(fmd.schema[0].name, "schema")
    assert_equal(fmd.schema[0].num_children, 2)
    assert_equal(fmd.schema[1].name, "id")
    assert_equal(fmd.schema[2].name, "value")
    assert_equal(fmd.num_rows, 500)
    assert_equal(len(fmd.row_groups), 1)
    assert_equal(fmd.row_groups[0].num_rows, 500)
    assert_equal(len(fmd.key_value_metadata.value()), 2)
    assert_equal(fmd.key_value_metadata.value()[0].key, "ARROW:schema")
    assert_equal(fmd.created_by.value(), "example-writer 0.4.0")


def test_key_value_no_value() raises:
    """KeyValue with no value (value is None)."""
    var kv = KeyValue("marker_key")
    assert_equal(kv.key, "marker_key")
    assert_false(kv.value)


def test_sorting_column() raises:
    """SortingColumn construction with defaults and explicit values."""
    var sc1 = SortingColumn(column_idx=0)
    assert_equal(sc1.column_idx, 0)
    assert_false(sc1.descending)
    assert_false(sc1.nulls_first)

    var sc2 = SortingColumn(column_idx=2, descending=True, nulls_first=True)
    assert_equal(sc2.column_idx, 2)
    assert_true(sc2.descending)
    assert_true(sc2.nulls_first)


def test_column_chunk_with_file_path() raises:
    """ColumnChunk with an explicit file path (split-file Parquet)."""
    var encodings: List[Encoding] = [Encoding.PLAIN]
    var path: List[String] = ["data"]
    var cmd = ColumnMetaData(
        type=ParquetType.INT32,
        encodings=encodings^,
        path_in_schema=path^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=100,
        total_uncompressed_size=400,
        total_compressed_size=400,
        data_page_offset=0,
    )
    var cc = ColumnChunk(
        file_offset=0,
        meta_data=cmd^,
        file_path=String("part-00000.parquet"),
    )
    assert_equal(cc.file_path.value(), "part-00000.parquet")
    assert_equal(cc.file_offset, 0)
    assert_true(cc.meta_data.type == ParquetType.INT32)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
