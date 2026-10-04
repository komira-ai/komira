# =============================================================================
# Parquet file metadata structs — mirrors the Parquet Thrift spec
# =============================================================================
#
# These types represent the metadata structures found in a Parquet file footer.
# They use Mojo idioms (Optional, List) instead of raw Thrift i32 constants
# and __isset flags.
#
# Hierarchy:
#   FileMetaData
#     -> List[SchemaElement]     (flattened schema tree)
#     -> List[RowGroup]
#          -> List[ColumnChunk]
#               -> ColumnMetaData
#                    -> Statistics
#     -> List[KeyValue]          (key-value metadata)
#
# All structs conform to Movable + Copyable so they can be stored in List.
# Constructor parameters for non-ImplicitlyCopyable types use `var` convention
# to take ownership and avoid implicit copies.
# =============================================================================

from .types import (
    PageType,
    Encoding,
    CompressionCodec,
    ParquetType,
    FieldRepetitionType,
    BoundaryOrder,
)


# =============================================================================
# KeyValue — key-value metadata pair
# =============================================================================


struct KeyValue(Movable, Copyable):
    """Key-value metadata pair from the Parquet file footer.

    Used for ARROW:schema, pandas metadata, and other custom metadata.

    Fields:
        key: The metadata key.
        value: The metadata value (optional).
    """

    var key: String
    var value: Optional[String]

    def __init__(out self, var key: String, var value: Optional[String] = None):
        self.key = key^
        self.value = value^


# =============================================================================
# Statistics — column-level or page-level statistics
# =============================================================================


struct Statistics(Movable, Copyable):
    """Serialized column statistics (stored as raw bytes for Thrift).

    Min/max values are stored as raw little-endian bytes matching the
    column's physical type. The is_min/max_value_exact fields indicate
    whether the values are exact or truncated (for string columns).

    Fields:
        null_count: Number of null values.
        distinct_count: Number of distinct values (optional, may not be set).
        min_value: Minimum value as raw bytes (correct sort order).
        max_value: Maximum value as raw bytes (correct sort order).
        is_min_value_exact: Whether min_value is exact (not truncated).
        is_max_value_exact: Whether max_value is exact (not truncated).
        min: Legacy minimum value (may have wrong sort order for signed ints).
        max: Legacy maximum value (may have wrong sort order for signed ints).
        hll_registers: A non-standard Statistics field 9: a precision-12
            HyperLogLog register array (4096 bytes, register-wise
            max-mergeable). A reader can merge these across row groups
            instead of summing `distinct_count`, which over-counts a key
            that appears in several row groups. Absent in files from other
            writers; a reader then falls back to summing `distinct_count`.
    """

    var null_count: Optional[Int]
    var distinct_count: Optional[Int]
    var min_value: Optional[List[UInt8]]
    var max_value: Optional[List[UInt8]]
    var is_min_value_exact: Bool
    var is_max_value_exact: Bool
    var min: Optional[List[UInt8]]
    var max: Optional[List[UInt8]]
    var hll_registers: Optional[List[UInt8]]

    def __init__(
        out self,
        null_count: Optional[Int] = None,
        distinct_count: Optional[Int] = None,
        var min_value: Optional[List[UInt8]] = None,
        var max_value: Optional[List[UInt8]] = None,
        is_min_value_exact: Bool = True,
        is_max_value_exact: Bool = True,
        var hll_registers: Optional[List[UInt8]] = None,
    ):
        self.null_count = null_count
        self.distinct_count = distinct_count
        self.min_value = min_value^
        self.max_value = max_value^
        self.is_min_value_exact = is_min_value_exact
        self.is_max_value_exact = is_max_value_exact
        self.min = None
        self.max = None
        self.hll_registers = hll_registers^


# =============================================================================
# SchemaElement — one node in the flattened schema tree
# =============================================================================


struct SchemaElement(Movable, Copyable):
    """A single element in the flattened schema tree.

    Parquet encodes its schema as a depth-first flattened list. Group nodes
    have num_children > 0 and no physical type. Leaf nodes have a physical
    type and num_children == 0.

    Fields:
        name: Field name.
        type: Physical type (only set for leaf columns).
        type_length: Fixed length for FIXED_LEN_BYTE_ARRAY columns.
        repetition_type: Required, optional, or repeated.
        num_children: Number of children (0 for leaf columns).
        converted_type: Deprecated converted type (still needed for compat).
        scale: Scale for Decimal logical type.
        precision: Precision for Decimal logical type.
    """

    var name: String
    var type: Optional[ParquetType]
    var type_length: Optional[Int]
    var repetition_type: Optional[FieldRepetitionType]
    var num_children: Int
    var converted_type: Optional[Int]
    var scale: Optional[Int]
    var precision: Optional[Int]
    # The modern thrift `LogicalType` union (SchemaElement field 10) carries
    # TIMESTAMP with an explicit unit + is_adjusted_to_utc flag that the
    # deprecated `converted_type` (field 6) cannot express (no NANOS unit, no
    # tz flag).
    # pyarrow writes timestamps ONLY via the LogicalType union with
    # converted_type=NONE, so without parsing field 10 a timestamp column
    # surfaces as bare INT64.  `logical_timestamp_unit` holds the TimeUnit
    # tag (1=MILLIS, 2=MICROS, 3=NANOS — the thrift TimeUnit union field ids);
    # `logical_timestamp_is_utc` carries isAdjustedToUTC (drives the Arrow
    # tz="UTC" tag).  None when the element is not a LogicalType TIMESTAMP.
    var logical_timestamp_unit: Optional[Int]
    var logical_timestamp_is_utc: Optional[Bool]

    def __init__(
        out self,
        var name: String,
        type: Optional[ParquetType] = None,
        type_length: Optional[Int] = None,
        repetition_type: Optional[FieldRepetitionType] = None,
        num_children: Int = 0,
        converted_type: Optional[Int] = None,
        scale: Optional[Int] = None,
        precision: Optional[Int] = None,
        logical_timestamp_unit: Optional[Int] = None,
        logical_timestamp_is_utc: Optional[Bool] = None,
    ):
        self.name = name^
        self.type = type
        self.type_length = type_length
        self.repetition_type = repetition_type
        self.num_children = num_children
        self.converted_type = converted_type
        self.scale = scale
        self.precision = precision
        self.logical_timestamp_unit = logical_timestamp_unit
        self.logical_timestamp_is_utc = logical_timestamp_is_utc


# =============================================================================
# PageHeader — header for a data, dictionary, or index page
# =============================================================================


struct PageHeader(Movable, Copyable):
    """Header for a Parquet page.

    Contains the page type, sizes, encoding information, and value count.
    For DATA_PAGE_V2, the definition/repetition level encodings are always
    RLE (levels are stored uncompressed before the compressed values).

    Fields:
        type: Page type (DATA_PAGE, DICTIONARY_PAGE, etc.).
        uncompressed_page_size: Uncompressed size in bytes.
        compressed_page_size: Compressed size in bytes.
        num_values: Number of values in this page.
        encoding: Encoding used for values.
        definition_level_encoding: Encoding for definition levels.
        repetition_level_encoding: Encoding for repetition levels.
        crc: Optional CRC32C checksum of the compressed page body. -1
            when the page header has no `crc` field (Thrift field 4).
    """

    var type: PageType
    var uncompressed_page_size: Int
    var compressed_page_size: Int
    var num_values: Int
    var encoding: Encoding
    var definition_level_encoding: Encoding
    var repetition_level_encoding: Encoding
    # DataPage V2 fields
    var num_nulls: Int
    var num_rows: Int
    var def_levels_byte_length: Int
    var rep_levels_byte_length: Int
    var is_compressed: Bool
    # CRC32C of the compressed page body (Thrift field 4 on PageHeader).
    # -1 means the page header did not include a `crc` field.
    var crc: Int

    def __init__(
        out self,
        type: PageType,
        uncompressed_page_size: Int,
        compressed_page_size: Int,
        num_values: Int,
        encoding: Encoding,
        definition_level_encoding: Encoding = Encoding.RLE,
        repetition_level_encoding: Encoding = Encoding.RLE,
        num_nulls: Int = 0,
        num_rows: Int = 0,
        def_levels_byte_length: Int = 0,
        rep_levels_byte_length: Int = 0,
        is_compressed: Bool = True,
        crc: Int = -1,
    ):
        self.type = type
        self.uncompressed_page_size = uncompressed_page_size
        self.compressed_page_size = compressed_page_size
        self.num_values = num_values
        self.encoding = encoding
        self.definition_level_encoding = definition_level_encoding
        self.repetition_level_encoding = repetition_level_encoding
        self.num_nulls = num_nulls
        self.num_rows = num_rows
        self.def_levels_byte_length = def_levels_byte_length
        self.rep_levels_byte_length = rep_levels_byte_length
        self.is_compressed = is_compressed
        self.crc = crc


# =============================================================================
# ColumnMetaData — metadata for a single column chunk
# =============================================================================


struct ColumnMetaData(Movable, Copyable):
    """Metadata for a column chunk within a row group.

    Contains the physical type, encodings, compression, offsets, sizes,
    and optional statistics.

    Fields:
        type: Physical type of this column.
        encodings: Encodings used in this column chunk.
        path_in_schema: Column path in the schema (list of path segments).
        codec: Compression codec used.
        num_values: Number of values (including nulls).
        total_uncompressed_size: Total uncompressed size in bytes.
        total_compressed_size: Total compressed size in bytes.
        data_page_offset: Byte offset of the first data page.
        index_page_offset: Byte offset of the index page (if any).
        dictionary_page_offset: Byte offset of the dictionary page (if any).
        statistics: Column-level statistics (optional).
        bloom_filter_offset: Byte offset of the bloom filter data (optional).
        bloom_filter_length: Byte length of the bloom filter data (optional).
    """

    var type: ParquetType
    var encodings: List[Encoding]
    var path_in_schema: List[String]
    var codec: CompressionCodec
    var num_values: Int
    var total_uncompressed_size: Int
    var total_compressed_size: Int
    var data_page_offset: Int
    var index_page_offset: Optional[Int]
    var dictionary_page_offset: Optional[Int]
    var statistics: Optional[Statistics]
    var bloom_filter_offset: Optional[Int]
    var bloom_filter_length: Optional[Int]

    def __init__(
        out self,
        type: ParquetType,
        var encodings: List[Encoding],
        var path_in_schema: List[String],
        codec: CompressionCodec,
        num_values: Int,
        total_uncompressed_size: Int,
        total_compressed_size: Int,
        data_page_offset: Int,
        index_page_offset: Optional[Int] = None,
        dictionary_page_offset: Optional[Int] = None,
        var statistics: Optional[Statistics] = None,
        bloom_filter_offset: Optional[Int] = None,
        bloom_filter_length: Optional[Int] = None,
    ):
        self.type = type
        self.encodings = encodings^
        self.path_in_schema = path_in_schema^
        self.codec = codec
        self.num_values = num_values
        self.total_uncompressed_size = total_uncompressed_size
        self.total_compressed_size = total_compressed_size
        self.data_page_offset = data_page_offset
        self.index_page_offset = index_page_offset
        self.dictionary_page_offset = dictionary_page_offset
        self.statistics = statistics^
        self.bloom_filter_offset = bloom_filter_offset
        self.bloom_filter_length = bloom_filter_length


# =============================================================================
# ColumnChunk — column chunk location + metadata
# =============================================================================


struct ColumnChunk(Movable, Copyable):
    """A column chunk within a row group.

    The file_path is optional — if None, the column chunk is in the same
    file as the metadata. The file_offset points to the start of the
    column chunk in the file.

    Fields:
        file_path: Path to the file containing this column chunk (None = same file).
        file_offset: Byte offset of this column chunk in the file.
        meta_data: Column chunk metadata (type, encodings, statistics, etc.).
        column_index_offset: Byte offset of the ColumnIndex for this column.
        column_index_length: Byte length of the ColumnIndex.
        offset_index_offset: Byte offset of the OffsetIndex for this column.
        offset_index_length: Byte length of the OffsetIndex.
    """

    var file_path: Optional[String]
    var file_offset: Int
    var meta_data: ColumnMetaData
    var column_index_offset: Optional[Int]
    var column_index_length: Optional[Int]
    var offset_index_offset: Optional[Int]
    var offset_index_length: Optional[Int]

    def __init__(
        out self,
        file_offset: Int,
        var meta_data: ColumnMetaData,
        var file_path: Optional[String] = None,
        column_index_offset: Optional[Int] = None,
        column_index_length: Optional[Int] = None,
        offset_index_offset: Optional[Int] = None,
        offset_index_length: Optional[Int] = None,
    ):
        self.file_path = file_path^
        self.file_offset = file_offset
        self.meta_data = meta_data^
        self.column_index_offset = column_index_offset
        self.column_index_length = column_index_length
        self.offset_index_offset = offset_index_offset
        self.offset_index_length = offset_index_length


# =============================================================================
# SortingColumn — sorting specification for a row group
# =============================================================================


struct SortingColumn(Movable, Copyable):
    """Sorting column specification for a row group.

    Fields:
        column_idx: 0-based column index in the row group's schema.
        descending: True if descending order.
        nulls_first: True if nulls come first.
    """

    var column_idx: Int
    var descending: Bool
    var nulls_first: Bool

    def __init__(
        out self,
        column_idx: Int,
        descending: Bool = False,
        nulls_first: Bool = False,
    ):
        self.column_idx = column_idx
        self.descending = descending
        self.nulls_first = nulls_first


# =============================================================================
# RowGroup — metadata for a row group
# =============================================================================


struct RowGroup(Movable, Copyable):
    """Metadata for a row group.

    A Parquet file contains one or more row groups, each containing a
    set of column chunks. Row groups enable parallel reads and are the
    unit of predicate pushdown at the file level.

    Fields:
        columns: Column chunk metadata for each column.
        total_byte_size: Total byte size of all column chunks (uncompressed).
        num_rows: Number of rows in this row group.
        sorting_columns: Sorting specification (optional).
    """

    var columns: List[ColumnChunk]
    var total_byte_size: Int
    var num_rows: Int
    var sorting_columns: Optional[List[SortingColumn]]

    def __init__(
        out self,
        var columns: List[ColumnChunk],
        total_byte_size: Int,
        num_rows: Int,
        var sorting_columns: Optional[List[SortingColumn]] = None,
    ):
        self.columns = columns^
        self.total_byte_size = total_byte_size
        self.num_rows = num_rows
        self.sorting_columns = sorting_columns^


# =============================================================================
# FileMetaData — top-level Parquet file metadata (from footer)
# =============================================================================


struct FileMetaData(Movable, Copyable):
    """File-level metadata from the Parquet footer.

    This is the top-level metadata structure read from the last 8+ bytes
    of a Parquet file. It contains the schema (flattened tree), row group
    metadata, key-value metadata, and format version.

    Fields:
        version: Parquet format version (1 or 2).
        schema: Schema elements (flattened depth-first tree).
        num_rows: Total number of rows across all row groups.
        row_groups: Metadata for each row group.
        key_value_metadata: Key-value metadata pairs (optional).
        created_by: Library identifier that created the file (optional).
    """

    var version: Int
    var schema: List[SchemaElement]
    var num_rows: Int
    var row_groups: List[RowGroup]
    var key_value_metadata: Optional[List[KeyValue]]
    var created_by: Optional[String]

    def __init__(
        out self,
        version: Int,
        var schema: List[SchemaElement],
        num_rows: Int,
        var row_groups: List[RowGroup],
        var key_value_metadata: Optional[List[KeyValue]] = None,
        var created_by: Optional[String] = None,
    ):
        self.version = version
        self.schema = schema^
        self.num_rows = num_rows
        self.row_groups = row_groups^
        self.key_value_metadata = key_value_metadata^
        self.created_by = created_by^
