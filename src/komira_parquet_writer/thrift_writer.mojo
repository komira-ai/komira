# =============================================================================
# Thrift Compact Protocol Writer — minimal serializer for Parquet metadata
# =============================================================================
#
# The ThriftCompactWriter struct: the low-level Thrift compact encoding
# methods and the Parquet metadata serializers (schema elements, column
# chunks, statistics, page headers, page indexes, the bloom filter header),
# plus serialize_file_metadata(), the footer.
#
# Where the HyperLogLog registers go: `Statistics.hll_registers` is not part
# of the Parquet format, so it is not written as a Statistics field. It
# travels in the column chunk's `ColumnMetaData.key_value_metadata` (field 8)
# under `HLL_REGISTERS_KEY`, encoded by `komira_parquet_api.hll_footer`, and
# Statistics field 9 is the spec's `nan_count` (an i64). The reader in
# `komira_parquet` reads both back from those places.
# =============================================================================

from komira_parquet_api.types import (
    PageType,
    Encoding,
)
from komira_parquet_api.metadata import (
    SchemaElement,
    ColumnChunk,
    RowGroup,
    FileMetaData,
    KeyValue,
    Statistics,
)
from komira_parquet_api.hll_footer import (
    HLL_REGISTERS_KEY,
    hll_registers_to_key_value,
)
from .page_size_limit import check_parquet_page_size


# Thrift Compact Protocol type IDs
comptime _COMPACT_BOOLEAN_TRUE: UInt8 = 1
comptime _COMPACT_BOOLEAN_FALSE: UInt8 = 2
comptime _COMPACT_I8: UInt8 = 3
comptime _COMPACT_I16: UInt8 = 4
comptime _COMPACT_I32: UInt8 = 5
comptime _COMPACT_I64: UInt8 = 6
comptime _COMPACT_BINARY: UInt8 = 8
comptime _COMPACT_LIST: UInt8 = 9
comptime _COMPACT_STRUCT: UInt8 = 12


@always_inline
def _zigzag_i32(n: Int) -> Int:
    """Zigzag encode a signed i32 value."""
    var n32 = Int32(n)
    var encoded = Int32((n32 << 1) ^ (n32 >> 31))
    return Int(UInt32(encoded))


@always_inline
def _zigzag_i64(n: Int) -> Int:
    """Zigzag encode a signed i64 value."""
    var n64 = Int64(n)
    var encoded = Int64((n64 << 1) ^ (n64 >> 63))
    return Int(UInt64(encoded))


struct ThriftCompactWriter(Movable):
    """Minimal Thrift Compact Protocol writer for Parquet metadata.

    Fields:
        buf: Output byte buffer.
        field_id_stack: Stack of last field IDs for nested struct contexts.
        last_field_id: Current field ID tracker for delta encoding.
    """

    var buf: List[UInt8]
    var field_id_stack: List[Int]
    var last_field_id: Int

    def __init__(out self):
        self.buf = List[UInt8]()
        self.field_id_stack = List[Int]()
        self.last_field_id = 0

    def take_bytes(mut self) -> List[UInt8]:
        """Take the serialized bytes, leaving the writer empty."""
        var result = self.buf^
        self.buf = List[UInt8]()
        return result^

    @staticmethod
    def zigzag_i32(n: Int) -> Int:
        """Zigzag encode a signed i32 value (public for tests)."""
        return _zigzag_i32(n)

    @staticmethod
    def zigzag_i64(n: Int) -> Int:
        """Zigzag encode a signed i64 value (public for tests)."""
        return _zigzag_i64(n)

    # --- Low-level encoding ---

    @always_inline
    def write_byte(mut self, b: UInt8):
        self.buf.append(b)

    @always_inline
    def write_varint(mut self, value: Int):
        """Write unsigned variable-length integer (ULEB128)."""
        var v = value
        if v < 0:
            var uv = UInt64(v)
            while True:
                var byte = UInt8(uv & 0x7F)
                uv = uv >> 7
                if uv != 0:
                    byte = byte | UInt8(0x80)
                self.buf.append(byte)
                if uv == 0:
                    break
            return
        while True:
            var byte = UInt8(v & 0x7F)
            v = v >> 7
            if v != 0:
                byte = byte | UInt8(0x80)
            self.buf.append(byte)
            if v == 0:
                break

    # --- Field writing ---

    @always_inline
    def write_field_header(mut self, field_id: Int, type_id: UInt8):
        """Write a Thrift Compact Protocol field header."""
        var delta = field_id - self.last_field_id
        if delta > 0 and delta <= 15:
            self.write_byte(UInt8(delta << 4) | type_id)
        else:
            self.write_byte(type_id)
            self.write_varint(_zigzag_i32(field_id))
        self.last_field_id = field_id

    def write_stop(mut self):
        """Write a struct STOP marker (0x00)."""
        self.write_byte(UInt8(0))

    def write_i32_field(mut self, field_id: Int, value: Int):
        """Write an i32 field."""
        self.write_field_header(field_id, _COMPACT_I32)
        self.write_varint(_zigzag_i32(value))

    def write_i64_field(mut self, field_id: Int, value: Int):
        """Write an i64 field."""
        self.write_field_header(field_id, _COMPACT_I64)
        self.write_varint(_zigzag_i64(value))

    def write_i16_field(mut self, field_id: Int, value: Int):
        """Write an i16 field."""
        self.write_field_header(field_id, _COMPACT_I16)
        self.write_varint(_zigzag_i32(value))

    def write_bool_field(mut self, field_id: Int, value: Bool):
        """Write a boolean field (encoded in the type ID)."""
        var type_id = _COMPACT_BOOLEAN_TRUE if value else _COMPACT_BOOLEAN_FALSE
        self.write_field_header(field_id, type_id)

    def write_binary_field(mut self, field_id: Int, data: List[UInt8]):
        """Write a binary field (length-prefixed bytes)."""
        self.write_field_header(field_id, _COMPACT_BINARY)
        self.write_varint(len(data))
        for i in range(len(data)):
            self.buf.append(data[i])

    def write_string_field(mut self, field_id: Int, value: String):
        """Write a string field (Thrift BINARY with UTF-8 content)."""
        self.write_field_header(field_id, _COMPACT_BINARY)
        # MOJO 1.0.0: `as_c_string_slice()` forms a SECOND view over the same
        # String and invalidates the `as_bytes()` span. The pointer walk was
        # never needed -- index the byte span we already hold. Same bytes,
        # same order, one borrow.
        var s = value
        var s_bytes = s.as_bytes()
        var byte_len = len(s_bytes)
        self.write_varint(byte_len)
        for i in range(byte_len):
            self.buf.append(s_bytes[i])
        _ = s

    def write_string_in_list(mut self, value: String):
        """Write a string as a list element (varint length + bytes, no field header)."""
        var s = value
        var s_bytes = s.as_bytes()
        var byte_len = len(s_bytes)
        self.write_varint(byte_len)
        for i in range(byte_len):
            self.buf.append(s_bytes[i])
        _ = s

    def write_optional_i32_field(mut self, field_id: Int, value: Optional[Int]):
        """Write an optional i32 field (skip if None)."""
        if value:
            self.write_i32_field(field_id, value.value())

    def write_optional_i64_field(mut self, field_id: Int, value: Optional[Int]):
        """Write an optional i64 field (skip if None)."""
        if value:
            self.write_i64_field(field_id, value.value())

    def write_optional_string_field(mut self, field_id: Int, value: Optional[String]):
        """Write an optional string field (skip if None)."""
        if value:
            self.write_string_field(field_id, value.value())

    # --- Struct context management ---

    def write_struct_begin(mut self, field_id: Int):
        """Begin a struct field (write field header and push context)."""
        self.write_field_header(field_id, _COMPACT_STRUCT)
        self.field_id_stack.append(self.last_field_id)
        self.last_field_id = 0

    def write_struct_end(mut self):
        """End a struct field (write STOP and pop context)."""
        self.write_stop()
        if len(self.field_id_stack) > 0:
            self.last_field_id = self.field_id_stack.pop()
        else:
            self.last_field_id = 0

    def push_struct(mut self):
        """Begin a standalone struct (top-level, not as a field)."""
        self.field_id_stack.append(self.last_field_id)
        self.last_field_id = 0

    def pop_struct(mut self):
        """End a standalone struct."""
        self.write_stop()
        if len(self.field_id_stack) > 0:
            self.last_field_id = self.field_id_stack.pop()
        else:
            self.last_field_id = 0

    def push_list_element_struct(mut self):
        """Begin a struct that is an element of a list."""
        self.field_id_stack.append(self.last_field_id)
        self.last_field_id = 0

    def pop_list_element_struct(mut self):
        """End a struct that is an element of a list."""
        self.write_stop()
        if len(self.field_id_stack) > 0:
            self.last_field_id = self.field_id_stack.pop()
        else:
            self.last_field_id = 0

    # --- List writing ---

    def write_list_begin(mut self, field_id: Int, elem_type: UInt8, count: Int):
        """Write a list field header."""
        self.write_field_header(field_id, _COMPACT_LIST)
        if count < 15:
            self.write_byte(UInt8(count << 4) | elem_type)
        else:
            self.write_byte(UInt8(0xF0) | elem_type)
            self.write_varint(count)

    # =================================================================
    # High-level Parquet metadata serialization methods
    # =================================================================

    def write_schema_element(mut self, elem: SchemaElement):
        """Serialize a SchemaElement as a Thrift list element struct."""
        self.push_list_element_struct()
        if elem.type:
            self.write_i32_field(1, Int(elem.type.value().value))
        self.write_optional_i32_field(2, elem.type_length)
        if elem.repetition_type:
            self.write_i32_field(3, Int(elem.repetition_type.value().value))
        self.write_string_field(4, elem.name)
        if elem.num_children > 0:
            self.write_i32_field(5, elem.num_children)
        self.write_optional_i32_field(6, elem.converted_type)
        self.write_optional_i32_field(7, elem.scale)
        self.write_optional_i32_field(8, elem.precision)
        self.pop_list_element_struct()

    def write_statistics(mut self, stats: Statistics):
        """Serialize Statistics as field 12 of ColumnMetaData.

        parquet.thrift Statistics field map (spec):
          1: optional binary max          (legacy, not written)
          2: optional binary min          (legacy, not written)
          3: optional i64 null_count
          4: optional i64 distinct_count
          5: optional binary max_value
          6: optional binary min_value
          7: optional bool is_max_value_exact
          8: optional bool is_min_value_exact
          9: optional i64 nan_count

        `stats.hll_registers` is not written here: `write_column_chunk`
        puts it in the chunk's key-value metadata (see the module header).
        """
        self.write_struct_begin(12)
        if stats.null_count:
            self.write_i64_field(3, stats.null_count.value())
        if stats.distinct_count:
            # Field 4 (i64). Optional — only emitted when the writer
            # populated it. Negative values are not legal under the
            # spec; stats.mojo only ever emits >= 0.
            self.write_i64_field(4, stats.distinct_count.value())
        if stats.max_value:
            self.write_binary_field(5, stats.max_value.value())
        if stats.min_value:
            self.write_binary_field(6, stats.min_value.value())
        self.write_bool_field(7, stats.is_max_value_exact)
        self.write_bool_field(8, stats.is_min_value_exact)
        # Field 9: nan_count (i64), set by the FLOAT / DOUBLE statistics
        # (`writer_float_stats`) when the count is exact.
        self.write_optional_i64_field(9, stats.nan_count)
        self.write_struct_end()

    def write_column_key_values(
        mut self, meta_key_values: Optional[List[KeyValue]], stats: Optional[Statistics]
    ) raises:
        """Serialize ColumnMetaData field 8, `key_value_metadata`.

        The pairs are the chunk's own `key_value_metadata` without any
        `HLL_REGISTERS_KEY` pair, then the HLL registers of `stats` (if it
        carries any) as one `HLL_REGISTERS_KEY` pair. A footer read back by
        the reader carries the registers twice (in `Statistics.hll_registers`
        and as a key-value pair); dropping the incoming pair and re-encoding
        the registers writes the key exactly once. Nothing is written when
        there is no pair.

        Raises:
            If the registers are not a precision-12 register array
            (`hll_registers_to_key_value`).
        """
        var pairs = List[KeyValue]()
        if meta_key_values:
            ref kvs = meta_key_values.value()
            for i in range(len(kvs)):
                if kvs[i].key != HLL_REGISTERS_KEY:
                    pairs.append(kvs[i].copy())
        if stats and stats.value().hll_registers:
            pairs.append(
                hll_registers_to_key_value(
                    Span(stats.value().hll_registers.value())
                )
            )
        if len(pairs) == 0:
            return
        self.write_list_begin(8, _COMPACT_STRUCT, len(pairs))
        for i in range(len(pairs)):
            self.write_key_value(pairs[i])

    def write_column_chunk(mut self, chunk: ColumnChunk) raises:
        """Serialize a ColumnChunk as a Thrift list element struct.

        Raises:
            If the chunk's statistics carry HLL registers that are not a
            precision-12 register array.
        """
        self.push_list_element_struct()
        var meta = chunk.meta_data.copy()
        self.write_i64_field(2, meta.data_page_offset)
        # Field 3: ColumnMetaData (inline struct)
        self.write_struct_begin(3)
        self.write_i32_field(1, Int(meta.type.value))
        self.write_list_begin(2, _COMPACT_I32, len(meta.encodings))
        for i in range(len(meta.encodings)):
            self.write_varint(_zigzag_i32(Int(meta.encodings[i].value)))
        self.write_list_begin(3, _COMPACT_BINARY, len(meta.path_in_schema))
        for i in range(len(meta.path_in_schema)):
            self.write_string_in_list(meta.path_in_schema[i])
        self.write_i32_field(4, Int(meta.codec.value))
        self.write_i64_field(5, meta.num_values)
        self.write_i64_field(6, meta.total_uncompressed_size)
        self.write_i64_field(7, meta.total_compressed_size)
        self.write_column_key_values(meta.key_value_metadata, meta.statistics)
        self.write_i64_field(9, meta.data_page_offset)
        self.write_optional_i64_field(10, meta.index_page_offset)
        self.write_optional_i64_field(11, meta.dictionary_page_offset)
        if meta.statistics:
            self.write_statistics(meta.statistics.value())
        # Field 14: bloom_filter_offset (optional)
        self.write_optional_i64_field(14, meta.bloom_filter_offset)
        # Field 15: bloom_filter_length (optional)
        self.write_optional_i32_field(15, meta.bloom_filter_length)
        self.write_struct_end()  # ColumnMetaData
        # ColumnChunk-level fields for page indexes (per Apache Parquet
        # parquet.thrift spec):
        #   4: offset_index_offset (i64)
        #   5: offset_index_length (i32)
        #   6: column_index_offset (i64)
        #   7: column_index_length (i32)
        # A writer that swaps the two pairs produces files its own reader
        # (with the same swap) accepts and parquet-rs / DuckDB / pyarrow
        # reject; test_thrift_writer_direct pins the field ids.
        self.write_optional_i64_field(4, chunk.offset_index_offset)
        self.write_optional_i32_field(5, chunk.offset_index_length)
        self.write_optional_i64_field(6, chunk.column_index_offset)
        self.write_optional_i32_field(7, chunk.column_index_length)
        self.pop_list_element_struct()  # ColumnChunk

    def write_row_group(mut self, rg: RowGroup) raises:
        """Serialize a RowGroup as a Thrift list element struct."""
        self.push_list_element_struct()
        self.write_list_begin(1, _COMPACT_STRUCT, len(rg.columns))
        for i in range(len(rg.columns)):
            self.write_column_chunk(rg.columns[i])
        self.write_i64_field(2, rg.total_byte_size)
        self.write_i64_field(3, rg.num_rows)
        self.pop_list_element_struct()

    def write_key_value(mut self, kv: KeyValue):
        """Serialize a KeyValue as a Thrift list element struct."""
        self.push_list_element_struct()
        self.write_string_field(1, kv.key)
        self.write_optional_string_field(2, kv.value)
        self.pop_list_element_struct()

    def write_data_page_header(
        mut self,
        uncompressed_size: Int,
        compressed_size: Int,
        num_values: Int,
        encoding: Encoding,
        crc: Optional[UInt32] = None,
    ) raises:
        """Serialize a DataPage V1 PageHeader.

        ⛔ THE SIZE FIELDS ARE i32 AND THIS SERIALISER TRUNCATES SILENTLY.
        `write_i32_field` -> `_zigzag_i32` opens with `var n32 = Int32(n)`, an
        unchecked narrowing: a 2^31-byte page body wrote a header claiming
        -2147483648 bytes and the write reported success. `check_parquet_page_size`
        is the BACKSTOP for that — it covers this and every other emitter in
        the package, several of which build their header inline and never pass
        through `writer_encode`'s page-assembly helpers.

        ⚠ IT IS A BACKSTOP, NOT THE PRIMARY GUARD. `_assemble_column_page` /
        `_assemble_column_page_no_def` check the same thing one level up, where
        the COLUMN NAME is in scope and the check lands BEFORE compression is
        spent on a page that can never be written. This layer knows neither, so
        its message names the field and not the column. Do not delete that one
        as redundant.

        Args:
            uncompressed_size: Uncompressed page body size in bytes.
            compressed_size: Compressed page body size in bytes.
            num_values: Number of values in the page.
            encoding: Encoding used for values.
            crc: Optional CRC-32C checksum of the page body.

        Raises:
            Error: named `ParquetPageSizeOverflow`, when either size field
                would be silently truncated to i32.
        """
        check_parquet_page_size(
            "ThriftCompactWriter.write_data_page_header",
            "uncompressed_page_size",
            uncompressed_size,
        )
        check_parquet_page_size(
            "ThriftCompactWriter.write_data_page_header",
            "compressed_page_size",
            compressed_size,
        )
        self.push_struct()
        self.write_i32_field(1, Int(PageType.DATA_PAGE.value))
        self.write_i32_field(2, uncompressed_size)
        self.write_i32_field(3, compressed_size)
        if crc:
            # Field 4: crc (optional i32 in PageHeader)
            self.write_i32_field(4, Int(crc.value()))
        self.write_struct_begin(5)
        self.write_i32_field(1, num_values)
        self.write_i32_field(2, Int(encoding.value))
        self.write_i32_field(3, Int(Encoding.RLE.value))
        self.write_i32_field(4, Int(Encoding.RLE.value))
        self.write_struct_end()  # DataPageHeader
        self.pop_struct()  # PageHeader

    def write_data_page_v2_header(
        mut self,
        uncompressed_size: Int,
        compressed_size: Int,
        num_values: Int,
        num_nulls: Int,
        num_rows: Int,
        encoding: Encoding,
        def_levels_byte_length: Int,
        rep_levels_byte_length: Int,
        is_compressed: Bool = True,
        crc: Optional[UInt32] = None,
    ) raises:
        """Serialize a DataPage V2 PageHeader.

        V2 format separates levels from values:
          - Repetition levels: uncompressed, rep_levels_byte_length bytes
          - Definition levels: uncompressed, def_levels_byte_length bytes
          - Values: compressed (if is_compressed), remaining bytes

        The uncompressed_size and compressed_size in the page header refer
        to the VALUES portion only (excluding level bytes) per the spec.

        Args:
            uncompressed_size: Uncompressed size of the entire page body.
            compressed_size: Compressed size of the entire page body.
            num_values: Total number of values (including nulls).
            num_nulls: Number of null values in this page.
            num_rows: Number of rows in this page.
            encoding: Encoding used for values.
            def_levels_byte_length: Byte length of definition levels section.
            rep_levels_byte_length: Byte length of repetition levels section.
            is_compressed: Whether the values section is compressed.
            crc: Optional CRC-32C checksum.

        Raises:
            Error: named `ParquetPageSizeOverflow`, when either size field
                would be silently truncated to i32. Same ceiling as V1 — the
                page-header size fields are i32 in BOTH page versions, so a
                guard on V1 alone would leave the identical hole open here.
        """
        check_parquet_page_size(
            "ThriftCompactWriter.write_data_page_v2_header",
            "uncompressed_page_size",
            uncompressed_size,
        )
        check_parquet_page_size(
            "ThriftCompactWriter.write_data_page_v2_header",
            "compressed_page_size",
            compressed_size,
        )
        self.push_struct()
        self.write_i32_field(1, Int(PageType.DATA_PAGE_V2.value))
        self.write_i32_field(2, uncompressed_size)
        self.write_i32_field(3, compressed_size)
        if crc:
            self.write_i32_field(4, Int(crc.value()))
        # Field 8: DataPageHeaderV2
        self.write_struct_begin(8)
        self.write_i32_field(1, num_values)
        self.write_i32_field(2, num_nulls)
        self.write_i32_field(3, num_rows)
        self.write_i32_field(4, Int(encoding.value))
        self.write_i32_field(5, def_levels_byte_length)
        self.write_i32_field(6, rep_levels_byte_length)
        if not is_compressed:
            # Field 7: is_compressed, default true, only write if false
            self.write_bool_field(7, False)
        self.write_struct_end()  # DataPageHeaderV2
        self.pop_struct()  # PageHeader

    # =================================================================
    # Page index serialization (ColumnIndex, OffsetIndex)
    # =================================================================

    def write_column_index(
        mut self,
        null_pages: List[Bool],
        min_values: List[List[UInt8]],
        max_values: List[List[UInt8]],
        boundary_order: Int,
        null_counts: Optional[List[Int]] = None,
    ):
        """Serialize a ColumnIndex as Thrift Compact Protocol.

        ColumnIndex fields (per parquet.thrift):
          1: list<bool> null_pages
          2: list<binary> min_values
          3: list<binary> max_values
          4: BoundaryOrder boundary_order
          5: list<i64> null_counts (optional)

        Args:
            null_pages: Whether each page is all-null.
            min_values: Per-page min values as raw bytes.
            max_values: Per-page max values as raw bytes.
            boundary_order: BoundaryOrder enum value (0=UNORDERED, 1=ASC, 2=DESC).
            null_counts: Optional per-page null counts.
        """
        self.push_struct()
        var num_pages = len(null_pages)

        # Field 1: list<bool> null_pages
        self.write_list_begin(1, _COMPACT_BOOLEAN_TRUE, num_pages)
        for i in range(num_pages):
            # Booleans in a list are written as single bytes (1=true, 0=false)
            self.write_byte(UInt8(1) if null_pages[i] else UInt8(0))

        # Field 2: list<binary> min_values
        self.write_list_begin(2, _COMPACT_BINARY, num_pages)
        for i in range(num_pages):
            self.write_varint(len(min_values[i]))
            for j in range(len(min_values[i])):
                self.buf.append(min_values[i][j])

        # Field 3: list<binary> max_values
        self.write_list_begin(3, _COMPACT_BINARY, num_pages)
        for i in range(num_pages):
            self.write_varint(len(max_values[i]))
            for j in range(len(max_values[i])):
                self.buf.append(max_values[i][j])

        # Field 4: BoundaryOrder (i32 enum)
        self.write_i32_field(4, boundary_order)

        # Field 5: list<i64> null_counts (optional)
        if null_counts:
            var nc = null_counts.value().copy()
            self.write_list_begin(5, _COMPACT_I64, len(nc))
            for i in range(len(nc)):
                self.write_varint(_zigzag_i64(nc[i]))

        self.pop_struct()

    def write_offset_index(
        mut self,
        offsets: List[Int],
        compressed_sizes: List[Int],
        first_row_indices: List[Int],
    ):
        """Serialize an OffsetIndex as Thrift Compact Protocol.

        OffsetIndex fields (per parquet.thrift):
          1: list<PageLocation> page_locations
            PageLocation:
              1: i64 offset
              2: i32 compressed_page_size
              3: i64 first_row_index

        Args:
            offsets: File byte offset per page.
            compressed_sizes: Compressed byte size per page.
            first_row_indices: First row number per page.
        """
        self.push_struct()
        var num_pages = len(offsets)

        # Field 1: list<struct> page_locations
        self.write_list_begin(1, _COMPACT_STRUCT, num_pages)
        for i in range(num_pages):
            self.push_list_element_struct()
            self.write_i64_field(1, offsets[i])
            self.write_i32_field(2, compressed_sizes[i])
            self.write_i64_field(3, first_row_indices[i])
            self.pop_list_element_struct()

        self.pop_struct()

    # =================================================================
    # Bloom filter header serialization
    # =================================================================

    def write_bloom_filter_header(
        mut self,
        num_bytes: Int,
    ):
        """Serialize a BloomFilterHeader as Thrift Compact Protocol.

        BloomFilterHeader fields (per parquet.thrift):
          1: i32 numBytes
          2: BloomFilterAlgorithm algorithm (struct with SPLIT_BLOCK_ALGORITHM)
          3: BloomFilterHash hash (struct with XXHASH)
          4: BloomFilterCompression compression (struct with UNCOMPRESSED)

        The algorithm, hash, and compression fields are union types with
        a single variant each — they are serialized as a struct containing
        a struct field at position 1 (the union variant).

        Args:
            num_bytes: Size of the bloom filter bitset in bytes.
        """
        self.push_struct()

        # Field 1: numBytes
        self.write_i32_field(1, num_bytes)

        # Field 2: BloomFilterAlgorithm (struct containing SPLIT_BLOCK_ALGORITHM)
        self.write_struct_begin(2)
        # SPLIT_BLOCK_ALGORITHM is field 1 of BloomFilterAlgorithm, value is empty struct
        self.write_struct_begin(1)
        self.write_struct_end()  # empty SPLIT_BLOCK_ALGORITHM
        self.write_struct_end()  # BloomFilterAlgorithm

        # Field 3: BloomFilterHash (struct containing XXHASH)
        self.write_struct_begin(3)
        # XXHASH is field 1 of BloomFilterHash, value is empty struct
        self.write_struct_begin(1)
        self.write_struct_end()  # empty XXHASH
        self.write_struct_end()  # BloomFilterHash

        # Field 4: BloomFilterCompression (struct containing UNCOMPRESSED)
        self.write_struct_begin(4)
        # UNCOMPRESSED is field 1, value is empty struct
        self.write_struct_begin(1)
        self.write_struct_end()  # empty UNCOMPRESSED
        self.write_struct_end()  # BloomFilterCompression

        self.pop_struct()  # BloomFilterHeader


def serialize_file_metadata(metadata: FileMetaData) raises -> List[UInt8]:
    """Serialize FileMetaData to Thrift Compact Protocol bytes.

    Raises:
        If a column chunk's statistics carry HLL registers that are not a
        precision-12 register array.
    """
    var w = ThriftCompactWriter()
    w.push_struct()
    w.write_i32_field(1, metadata.version)
    w.write_list_begin(2, _COMPACT_STRUCT, len(metadata.schema))
    for i in range(len(metadata.schema)):
        w.write_schema_element(metadata.schema[i])
    w.write_i64_field(3, metadata.num_rows)
    w.write_list_begin(4, _COMPACT_STRUCT, len(metadata.row_groups))
    for i in range(len(metadata.row_groups)):
        w.write_row_group(metadata.row_groups[i])
    if metadata.key_value_metadata:
        var kv_list = metadata.key_value_metadata.value().copy()
        if len(kv_list) > 0:
            w.write_list_begin(5, _COMPACT_STRUCT, len(kv_list))
            for i in range(len(kv_list)):
                w.write_key_value(kv_list[i])
    w.write_optional_string_field(6, metadata.created_by)

    # -------------------------------------------------------------------
    # Field 7: column_orders — WITHOUT THIS, EVERY min_value/max_value WE
    # WRITE IS INVISIBLE TO parquet-cpp (pyarrow, pandas, polars, Spark).
    #
    # MEASURED 2026-09-02, pyarrow 24.0.0, on a file this writer produced whose
    # Statistics carried min_value/max_value (Thrift fields 5/6) with the
    # right values: `is_stats_set == True` but `has_min_max == False`, and
    # `statistics.min` / `.max` both None. parquet-cpp's
    # `MakeTypedColumnStats` reads the NEW-STYLE min_value/max_value only
    # when the column's ColumnOrder is TYPE_DEFINED_ORDER, and otherwise
    # falls back to the DEPRECATED `min`/`max` (fields 1/2) — which this
    # writer does not emit, and should not (they carry the wrong sort order
    # for signed integers, which is why the spec deprecated them). Splicing
    # a column_orders list into that same file flipped pyarrow to
    # `has_min_max == True` with the values we had written all along.
    # DuckDB and parquet-cpp both emit this field; we were the outlier.
    #
    # ⚠ DECLARING TYPE_ORDER IS AN ASSERTION ABOUT OUR OWN STATISTICS: that
    # min/max use the type-defined sort order (SIGNED for INT32/INT64 and
    # for DECIMAL's big-endian i128; UNSIGNED bytewise for BYTE_ARRAY). It
    # holds for every statistic this package emits — the integer paths use
    # signed SIMD min/max, `compute_statistics_string` compares bytes
    # unsigned, and the FLOAT/DOUBLE paths (`writer_float_stats`) follow
    # parquet.thrift's floating-point rules (no NaN in min/max, -0.0 as a
    # zero min, +0.0 as a zero max, nan_count). A future encoder that emits
    # min/max in any other order MUST NOT be added without revisiting this
    # field, or readers will prune wrongly.
    #
    # Spec: parquet.thrift FileMetaData.7 — "the length must be equal to the
    # number of columns in the schema", i.e. one entry per LEAF, in
    # schema-leaf order. Wire shape per entry: `ColumnOrder{1: TypeDefinedOrder{}}`
    # = an empty struct inside a struct.
    # -------------------------------------------------------------------
    var num_leaves = 0
    for i in range(len(metadata.schema)):
        if metadata.schema[i].type:
            num_leaves += 1
    if num_leaves > 0:
        w.write_list_begin(7, _COMPACT_STRUCT, num_leaves)
        for _ in range(num_leaves):
            w.push_list_element_struct()
            w.write_struct_begin(1)  # TYPE_ORDER
            w.write_struct_end()  # empty TypeDefinedOrder
            w.pop_list_element_struct()

    w.pop_struct()
    return w.take_bytes()
