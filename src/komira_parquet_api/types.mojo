# =============================================================================
# Parquet format enums — physical types, encodings, compression codecs
# =============================================================================
#
# These mirror the Parquet Thrift spec (parquet.thrift). Each enum is a struct
# with a UInt8 value and comptime constants. Values match the Thrift i32
# constants from the spec.
# =============================================================================


struct PageType(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Parquet page type (from parquet.thrift).

    Identifies the type of a page within a column chunk.

    Fields:
        value: Numeric identifier matching the Thrift enum.
    """

    var value: UInt8

    comptime DATA_PAGE = PageType(0)
    comptime INDEX_PAGE = PageType(1)
    comptime DICTIONARY_PAGE = PageType(2)
    comptime DATA_PAGE_V2 = PageType(3)

    def __init__(out self, value: UInt8):
        self.value = value

    def __init__(out self, value: Int):
        self.value = UInt8(value)

    @always_inline
    def __eq__(self, other: PageType) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: PageType) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == PageType.DATA_PAGE:
            writer.write("DATA_PAGE")
        elif self == PageType.INDEX_PAGE:
            writer.write("INDEX_PAGE")
        elif self == PageType.DICTIONARY_PAGE:
            writer.write("DICTIONARY_PAGE")
        elif self == PageType.DATA_PAGE_V2:
            writer.write("DATA_PAGE_V2")
        else:
            writer.write("PageType(", String(Int(self.value)), ")")


struct Encoding(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Parquet encoding (from parquet.thrift).

    Identifies how values are encoded within a page.

    Fields:
        value: Numeric identifier matching the Thrift enum.
    """

    var value: UInt8

    comptime PLAIN = Encoding(0)
    comptime PLAIN_DICTIONARY = Encoding(2)  # deprecated, same as RLE_DICTIONARY
    comptime RLE = Encoding(3)
    comptime BIT_PACKED = Encoding(4)  # deprecated but needed for old Impala files
    comptime DELTA_BINARY_PACKED = Encoding(5)
    comptime DELTA_LENGTH_BYTE_ARRAY = Encoding(6)
    comptime DELTA_BYTE_ARRAY = Encoding(7)
    comptime RLE_DICTIONARY = Encoding(8)
    comptime BYTE_STREAM_SPLIT = Encoding(9)

    def __init__(out self, value: UInt8):
        self.value = value

    def __init__(out self, value: Int):
        self.value = UInt8(value)

    @always_inline
    def __eq__(self, other: Encoding) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: Encoding) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == Encoding.PLAIN:
            writer.write("PLAIN")
        elif self == Encoding.PLAIN_DICTIONARY:
            writer.write("PLAIN_DICTIONARY")
        elif self == Encoding.RLE:
            writer.write("RLE")
        elif self == Encoding.BIT_PACKED:
            writer.write("BIT_PACKED")
        elif self == Encoding.DELTA_BINARY_PACKED:
            writer.write("DELTA_BINARY_PACKED")
        elif self == Encoding.DELTA_LENGTH_BYTE_ARRAY:
            writer.write("DELTA_LENGTH_BYTE_ARRAY")
        elif self == Encoding.DELTA_BYTE_ARRAY:
            writer.write("DELTA_BYTE_ARRAY")
        elif self == Encoding.RLE_DICTIONARY:
            writer.write("RLE_DICTIONARY")
        elif self == Encoding.BYTE_STREAM_SPLIT:
            writer.write("BYTE_STREAM_SPLIT")
        else:
            writer.write("Encoding(", String(Int(self.value)), ")")


struct CompressionCodec(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Parquet compression codec (from parquet.thrift).

    Identifies the compression algorithm used for a column chunk.

    Fields:
        value: Numeric identifier matching the Thrift enum.
    """

    var value: UInt8

    comptime UNCOMPRESSED = CompressionCodec(0)
    comptime SNAPPY = CompressionCodec(1)
    comptime GZIP = CompressionCodec(2)
    comptime LZO = CompressionCodec(3)
    comptime BROTLI = CompressionCodec(4)
    comptime LZ4 = CompressionCodec(5)  # deprecated but still in use
    comptime ZSTD = CompressionCodec(6)
    comptime LZ4_RAW = CompressionCodec(7)

    def __init__(out self, value: UInt8):
        self.value = value

    def __init__(out self, value: Int):
        self.value = UInt8(value)

    @always_inline
    def __eq__(self, other: CompressionCodec) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: CompressionCodec) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == CompressionCodec.UNCOMPRESSED:
            writer.write("UNCOMPRESSED")
        elif self == CompressionCodec.SNAPPY:
            writer.write("SNAPPY")
        elif self == CompressionCodec.GZIP:
            writer.write("GZIP")
        elif self == CompressionCodec.LZO:
            writer.write("LZO")
        elif self == CompressionCodec.BROTLI:
            writer.write("BROTLI")
        elif self == CompressionCodec.LZ4:
            writer.write("LZ4")
        elif self == CompressionCodec.ZSTD:
            writer.write("ZSTD")
        elif self == CompressionCodec.LZ4_RAW:
            writer.write("LZ4_RAW")
        else:
            writer.write("CompressionCodec(", String(Int(self.value)), ")")


struct ParquetType(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Parquet physical type (from parquet.thrift).

    Identifies the physical storage type of a column.

    Fields:
        value: Numeric identifier matching the Thrift enum.
    """

    var value: UInt8

    comptime BOOLEAN = ParquetType(0)
    comptime INT32 = ParquetType(1)
    comptime INT64 = ParquetType(2)
    comptime INT96 = ParquetType(3)  # deprecated
    comptime FLOAT = ParquetType(4)
    comptime DOUBLE = ParquetType(5)
    comptime BYTE_ARRAY = ParquetType(6)
    comptime FIXED_LEN_BYTE_ARRAY = ParquetType(7)

    def __init__(out self, value: UInt8):
        self.value = value

    def __init__(out self, value: Int):
        self.value = UInt8(value)

    @always_inline
    def __eq__(self, other: ParquetType) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: ParquetType) -> Bool:
        return self.value != other.value

    def byte_width(self) -> Optional[Int]:
        """Byte width of fixed-width types. Returns None for variable-length types."""
        if self == ParquetType.BOOLEAN:
            return Int(1)
        elif self == ParquetType.INT32 or self == ParquetType.FLOAT:
            return Int(4)
        elif self == ParquetType.INT64 or self == ParquetType.DOUBLE:
            return Int(8)
        elif self == ParquetType.INT96:
            return Int(12)
        else:
            return None

    def write_to[W: Writer](self, mut writer: W):
        if self == ParquetType.BOOLEAN:
            writer.write("BOOLEAN")
        elif self == ParquetType.INT32:
            writer.write("INT32")
        elif self == ParquetType.INT64:
            writer.write("INT64")
        elif self == ParquetType.INT96:
            writer.write("INT96")
        elif self == ParquetType.FLOAT:
            writer.write("FLOAT")
        elif self == ParquetType.DOUBLE:
            writer.write("DOUBLE")
        elif self == ParquetType.BYTE_ARRAY:
            writer.write("BYTE_ARRAY")
        elif self == ParquetType.FIXED_LEN_BYTE_ARRAY:
            writer.write("FIXED_LEN_BYTE_ARRAY")
        else:
            writer.write("ParquetType(", String(Int(self.value)), ")")


struct FieldRepetitionType(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Parquet field repetition type (from parquet.thrift).

    Controls whether a field is required, optional, or repeated.

    Fields:
        value: Numeric identifier matching the Thrift enum.
    """

    var value: UInt8

    comptime REQUIRED = FieldRepetitionType(0)
    comptime OPTIONAL = FieldRepetitionType(1)
    comptime REPEATED = FieldRepetitionType(2)

    def __init__(out self, value: UInt8):
        self.value = value

    def __init__(out self, value: Int):
        self.value = UInt8(value)

    @always_inline
    def __eq__(self, other: FieldRepetitionType) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: FieldRepetitionType) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == FieldRepetitionType.REQUIRED:
            writer.write("REQUIRED")
        elif self == FieldRepetitionType.OPTIONAL:
            writer.write("OPTIONAL")
        elif self == FieldRepetitionType.REPEATED:
            writer.write("REPEATED")
        else:
            writer.write("FieldRepetitionType(", String(Int(self.value)), ")")


struct BoundaryOrder(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Boundary order for page-level statistics in Column Index.

    Indicates whether min/max values across pages are ordered,
    enabling binary search for predicate pushdown.

    Fields:
        value: Numeric identifier matching the Thrift enum.
    """

    var value: UInt8

    comptime UNORDERED = BoundaryOrder(0)
    comptime ASCENDING = BoundaryOrder(1)
    comptime DESCENDING = BoundaryOrder(2)

    def __init__(out self, value: UInt8):
        self.value = value

    def __init__(out self, value: Int):
        self.value = UInt8(value)

    @always_inline
    def __eq__(self, other: BoundaryOrder) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: BoundaryOrder) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == BoundaryOrder.UNORDERED:
            writer.write("UNORDERED")
        elif self == BoundaryOrder.ASCENDING:
            writer.write("ASCENDING")
        elif self == BoundaryOrder.DESCENDING:
            writer.write("DESCENDING")
        else:
            writer.write("BoundaryOrder(", String(Int(self.value)), ")")
