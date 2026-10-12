# =============================================================================
# ColumnPage: one column chunk's encoded pages, and the page assembler
# =============================================================================
#
# Every page encoder in this package returns a `ColumnPage`: the bytes of a
# column chunk (one data page, or a dictionary page followed by one data
# page), with the sizes, codec, encodings and statistics the footer's
# ColumnMetaData needs. The writer that assembles a file (a later part of
# this package) copies `data` into the file and builds the metadata from the
# rest; nothing here writes a file.
#
# `_assemble_data_page` is the one place a DataPage V1 is built: body =
# [def levels][values] (levels only for an OPTIONAL column), compressed as
# one unit, behind a PageHeader whose two i32 size fields are checked before
# the body is compressed and again after (a codec can expand a body).
# =============================================================================

from std.memory import memcpy

from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType

from .page_size_limit import check_parquet_page_size
from .thrift_writer import ThriftCompactWriter
from .writer_helpers import _compress_page_body


def dtype_to_parquet_type[dtype: DType]() -> ParquetType:
    """The Parquet physical type a fixed-width Arrow DType is written as.

    8-, 16- and 32-bit integers are INT32 and 64-bit integers INT64, signed
    or not (the bits are written unchanged; an unsigned column needs an
    unsigned logical type in its schema element to read back as unsigned).
    """
    comptime if dtype == DType.int32 or dtype == DType.uint32:
        return ParquetType.INT32
    elif dtype == DType.int16 or dtype == DType.uint16:
        return ParquetType.INT32
    elif dtype == DType.int8 or dtype == DType.uint8:
        return ParquetType.INT32
    elif dtype == DType.int64 or dtype == DType.uint64:
        return ParquetType.INT64
    elif dtype == DType.float32:
        return ParquetType.FLOAT
    elif dtype == DType.float64:
        return ParquetType.DOUBLE
    elif dtype == DType.bool:
        return ParquetType.BOOLEAN
    else:
        comptime assert False, "unsupported DType for Parquet"
        return ParquetType.INT32


struct ColumnPage(Copyable, Movable):
    """One column chunk's encoded pages, ready for file assembly.

    Fields:
        data: The chunk's bytes: [dictionary page][data page] when
            `dict_page_size > 0`, else one data page. Each page is its
            header followed by its (possibly compressed) body.
        column_index: 0-based leaf column index in the output file.
        num_values: Rows in the chunk, nulls included.
        uncompressed_size: Sum of the page bodies before compression
            (headers excluded).
        compressed_size: Sum of the page bodies as written (headers
            excluded). `len(data) - compressed_size` is the header bytes.
        parquet_type: The column's physical type.
        column_name: The leaf name.
        statistics: The chunk's statistics, when the encoder computes them.
        dict_page_size: Bytes of the dictionary page (header + body) at the
            front of `data`; 0 when there is none.
        encodings: Every encoding the chunk uses (ColumnMetaData field 2).
        codec: The compression codec of every page body.
    """

    var data: List[UInt8]
    var column_index: Int
    var num_values: Int
    var uncompressed_size: Int
    var compressed_size: Int
    var parquet_type: ParquetType
    var column_name: String
    var statistics: Optional[Statistics]
    var dict_page_size: Int
    var encodings: List[Encoding]
    var codec: CompressionCodec

    def __init__(
        out self,
        var data: List[UInt8],
        column_index: Int,
        num_values: Int,
        uncompressed_size: Int,
        compressed_size: Int,
        parquet_type: ParquetType,
        var column_name: String,
        var encodings: List[Encoding],
        codec: CompressionCodec,
        var statistics: Optional[Statistics] = None,
        dict_page_size: Int = 0,
    ):
        self.data = data^
        self.column_index = column_index
        self.num_values = num_values
        self.uncompressed_size = uncompressed_size
        self.compressed_size = compressed_size
        self.parquet_type = parquet_type
        self.column_name = column_name^
        self.statistics = statistics^
        self.dict_page_size = dict_page_size
        self.encodings = encodings^
        self.codec = codec


def _require_no_nulls_when_required(
    who: String, column_name: String, nullable: Bool, null_count: Int
) raises:
    """A REQUIRED column has no way to say "null": refuse one that holds nulls.

    Writing the null slots' bytes as values would publish values that are
    not in the column, so every encoder in this package raises instead.
    """
    if not nullable and null_count > 0:
        raise Error(
            who
            + ": column '"
            + column_name
            + "' is REQUIRED but holds "
            + String(null_count)
            + " null(s); declare it OPTIONAL (nullable=True)"
        )


def _append_bytes(mut dest: List[UInt8], src: List[UInt8]):
    """Append `src` to `dest` with one bulk copy."""
    var n = len(src)
    if n == 0:
        return
    var cur = len(dest)
    dest.resize(cur + n, UInt8(0))
    # SAFETY: `dest` was just resized to hold `cur + n` bytes and `src` holds
    # `n`; both Lists are alive through the copy.
    memcpy(dest=dest.unsafe_ptr() + cur, src=src.unsafe_ptr(), count=n)


def _value_encodings(nullable: Bool, encoding: Encoding) -> List[Encoding]:
    """ColumnMetaData encodings of a chunk with one data page: RLE for the
    definition levels when the column is OPTIONAL, then the value encoding."""
    var encs = List[Encoding]()
    if nullable:
        encs.append(Encoding.RLE)
    encs.append(encoding)
    return encs^


def _assemble_data_page(
    column_index: Int,
    num_values: Int,
    def_level_data: List[UInt8],
    value_data: List[UInt8],
    parquet_type: ParquetType,
    column_name: String,
    encoding: Encoding,
    nullable: Bool,
    codec: CompressionCodec,
    var statistics: Optional[Statistics],
) raises -> ColumnPage:
    """Build one DataPage V1 column chunk: [header][compressed body].

    The body is [def levels][values] for an OPTIONAL column and [values] for
    a REQUIRED one (`def_level_data` is ignored when `nullable` is False);
    levels and values are compressed together, as parquet.thrift's V1 page
    requires.

    Raises:
        Error: named `ParquetPageSizeOverflow` when the body, before or after
            compression, does not fit the PageHeader's i32 size fields. The
            first check runs before the codec is spent on a page that can
            never be written.
    """
    var def_len = len(def_level_data) if nullable else 0
    var val_len = len(value_data)
    var uncompressed_size = def_len + val_len
    check_parquet_page_size(
        "_assemble_data_page",
        column_name,
        "uncompressed_page_size",
        uncompressed_size,
    )

    var body = List[UInt8](capacity=max(uncompressed_size, 1))
    if def_len > 0:
        _append_bytes(body, def_level_data)
    _append_bytes(body, value_data)

    var body_bytes = _compress_page_body(codec, body^)
    var compressed_size = len(body_bytes)
    check_parquet_page_size(
        "_assemble_data_page",
        column_name,
        "compressed_page_size",
        compressed_size,
    )

    var header_writer = ThriftCompactWriter()
    header_writer.write_data_page_header(
        uncompressed_size, compressed_size, num_values, encoding
    )
    var header_bytes = header_writer.take_bytes()

    var page_data = List[UInt8](capacity=len(header_bytes) + compressed_size)
    _append_bytes(page_data, header_bytes)
    _append_bytes(page_data, body_bytes)

    return ColumnPage(
        page_data^,
        column_index,
        num_values,
        uncompressed_size,
        compressed_size,
        parquet_type,
        String(column_name),
        _value_encodings(nullable, encoding),
        codec,
        statistics=statistics^,
    )
