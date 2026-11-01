# =============================================================================
# EncodedColumn: one column encoded on its own, assembled into a file later
# =============================================================================
#
# A column-parallel writer encodes each column on its own worker and hands the
# results to one assembler. `EncodedColumn` is that result for a fixed-width
# column written as one PLAIN data page: the page header and the body kept
# apart, with the sizes the footer needs. `write_parquet_file_from_encoded`
# puts them into a file and returns its bytes.
#
# The page is built by `encode_plain_column`, the same encoder
# `ParquetFileWriter.write_batch` uses, so a column encoded here and one
# written through the writer are the same bytes.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.metadata import SchemaElement, Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType

from .column_page import ColumnPage, dtype_to_parquet_type
from .writer import ParquetFileWriter
from .writer_encode import encode_plain_column
from .writer_helpers import make_schema_elements


struct EncodedColumn(Copyable, Movable):
    """A column encoded as one PLAIN data page, header apart from body.

    Fields:
        page_header_bytes: The Thrift PageHeader.
        data_bytes: The page body as written (compressed when `codec` is).
        column_index: 0-based leaf index in the output file.
        num_values: Rows in the column.
        data_size: The body's size before compression.
        compressed_size: The body's size as written.
        parquet_type: The physical type.
        column_name: The leaf name.
        codec: The compression codec of the body.
        statistics: The column's statistics, when the encoder computed them.
    """

    var page_header_bytes: List[UInt8]
    var data_bytes: List[UInt8]
    var column_index: Int
    var num_values: Int
    var data_size: Int
    var compressed_size: Int
    var parquet_type: ParquetType
    var column_name: String
    var codec: CompressionCodec
    var statistics: Optional[Statistics]

    def __init__(
        out self,
        var page_header_bytes: List[UInt8],
        var data_bytes: List[UInt8],
        column_index: Int,
        num_values: Int,
        data_size: Int,
        parquet_type: ParquetType,
        var column_name: String,
        codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
        compressed_size: Int = -1,
        var statistics: Optional[Statistics] = None,
    ):
        self.page_header_bytes = page_header_bytes^
        self.data_bytes = data_bytes^
        self.column_index = column_index
        self.num_values = num_values
        self.data_size = data_size
        self.compressed_size = (
            compressed_size if compressed_size >= 0 else data_size
        )
        self.parquet_type = parquet_type
        self.column_name = column_name^
        self.codec = codec
        self.statistics = statistics^


def encode_column_to_buffer[
    dtype: DType
](
    column_index: Int,
    array: PrimitiveArray[dtype],
    column_name: String,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> EncodedColumn:
    """Encode a REQUIRED fixed-width column into an `EncodedColumn`.

    Raises:
        Error: the array holds a null (a REQUIRED column has no definition
            levels to carry it), or the page is over the i32 PageHeader
            ceiling.
    """
    var page = encode_plain_column[dtype](
        column_index, array, column_name, nullable=False, codec=codec
    )
    var header_len = len(page.data) - page.compressed_size
    var header = List[UInt8](capacity=max(header_len, 1))
    var body = List[UInt8](capacity=max(page.compressed_size, 1))
    for i in range(header_len):
        header.append(page.data[i])
    for i in range(header_len, len(page.data)):
        body.append(page.data[i])
    return EncodedColumn(
        header^,
        body^,
        column_index,
        array.length,
        page.uncompressed_size,
        page.parquet_type,
        column_name,
        codec=codec,
        compressed_size=page.compressed_size,
        statistics=page.statistics.copy(),
    )


def write_parquet_file_from_encoded(
    var schema_elements: List[SchemaElement],
    var encoded_columns: List[EncodedColumn],
) raises -> List[UInt8]:
    """The bytes of a file holding `encoded_columns` as one row group.

    Raises:
        Error: the columns' row counts differ, an index is out of range or
            repeated, or a leaf of the schema has no column.
    """
    var writer = ParquetFileWriter.create(schema_elements^)
    for i in range(len(encoded_columns)):
        ref enc = encoded_columns[i]
        var data = List[UInt8](
            capacity=len(enc.page_header_bytes) + len(enc.data_bytes)
        )
        for b in range(len(enc.page_header_bytes)):
            data.append(enc.page_header_bytes[b])
        for b in range(len(enc.data_bytes)):
            data.append(enc.data_bytes[b])
        var encodings = List[Encoding]()
        encodings.append(Encoding.PLAIN)
        writer.write_column_page(
            ColumnPage(
                data^,
                enc.column_index,
                enc.num_values,
                enc.data_size,
                enc.compressed_size,
                enc.parquet_type,
                enc.column_name,
                encodings^,
                enc.codec,
                enc.statistics.copy(),
            )
        )
    return writer.close_to_bytes()


def write_batch_parallel_homogeneous[
    dtype: DType
](
    var column_names: List[String],
    var encoded_columns: List[EncodedColumn],
) raises -> List[UInt8]:
    """The bytes of a file of pre-encoded columns that all have `dtype`.

    Raises:
        Error: `column_names` and `encoded_columns` differ in length, or as
            `write_parquet_file_from_encoded`.
    """
    var num_cols = len(encoded_columns)
    if num_cols != len(column_names):
        raise Error(
            "write_batch_parallel_homogeneous: column_names length ("
            + String(len(column_names))
            + ") != encoded_columns length ("
            + String(num_cols)
            + ")"
        )
    var parquet_type = dtype_to_parquet_type[dtype]()
    var types = List[ParquetType]()
    for _ in range(num_cols):
        types.append(parquet_type)
    var schema = make_schema_elements(column_names^, types)
    return write_parquet_file_from_encoded(schema^, encoded_columns^)
