# =============================================================================
# ParquetFileWriter: column pages in, a Parquet file's bytes out
# =============================================================================
#
# Writes one row group, one column chunk per column, each a single data page
# (or a dictionary page and a data page):
#
#   [PAR1] [column chunks] [Thrift FileMetaData] [footer length] [PAR1]
#
# The writer is built over a flattened schema (`make_schema_elements`,
# `make_schema_elements_nullable`): element 0 is the root, leaf `i` is element
# `i + 1`. Every `write_*` call encodes one whole column. A column's
# nullability comes from its schema element (OPTIONAL gets definition levels,
# REQUIRED does not), so the page always matches the schema the footer
# declares, whichever `write_*` method the caller picked.
#
# `close_to_bytes` returns the file; this package opens no file, so a caller
# that wants one writes the bytes where it likes. The writer is single-shot:
# `close_to_bytes` ends it.
# =============================================================================

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import (
    ColumnChunk,
    RowGroup,
    SchemaElement,
    Statistics,
)
from komira_parquet_api.types import CompressionCodec, FieldRepetitionType

from .column_page import ColumnPage, _append_bytes
from .file_assembly import (
    append_magic,
    column_chunk_for_page,
    finish_file,
    row_group_for_chunks,
)
from .writer_dict import encode_dict_string_column_page
from .writer_encode import (
    encode_boolean_column_page,
    encode_plain_column,
    encode_string_column_page,
)


struct ParquetFileWriter(Movable):
    """Writes whole columns as one row group and returns the file's bytes.

    Fields:
        schema_elements: The flattened schema (root, then one per leaf).
        column_pages: The encoded columns, in the order written.
        num_rows: The row count every column must match (set by the first).
        closed: True after `close_to_bytes`.
        codec: The compression codec of every page body.
    """

    var schema_elements: List[SchemaElement]
    var column_pages: List[ColumnPage]
    var num_rows: Int
    var closed: Bool
    var codec: CompressionCodec

    @staticmethod
    def create(
        var schema_elements: List[SchemaElement],
        codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
    ) -> ParquetFileWriter:
        """A writer over `schema_elements` (root first, then the leaves)."""
        return ParquetFileWriter(schema_elements^, codec)

    def __init__(
        out self,
        var schema_elements: List[SchemaElement],
        codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
    ):
        self.schema_elements = schema_elements^
        self.column_pages = List[ColumnPage]()
        self.num_rows = 0
        self.closed = False
        self.codec = codec

    def _begin_column(mut self, column_index: Int, length: Int) raises -> Bool:
        """Check that a column may be written and return whether its schema
        element is OPTIONAL.

        Raises:
            Error: the writer is closed, `column_index` is out of range, the
                column was already written, or `length` differs from the
                row count of the columns before it.
        """
        if self.closed:
            raise Error("ParquetFileWriter: writer is already closed")
        var schema_idx = column_index + 1
        if column_index < 0 or schema_idx >= len(self.schema_elements):
            raise Error(
                "ParquetFileWriter: column_index "
                + String(column_index)
                + " out of range (schema has "
                + String(len(self.schema_elements) - 1)
                + " leaf columns)"
            )
        for i in range(len(self.column_pages)):
            if self.column_pages[i].column_index == column_index:
                raise Error(
                    "ParquetFileWriter: column "
                    + String(column_index)
                    + " was already written"
                )
        if len(self.column_pages) == 0:
            self.num_rows = length
        elif length != self.num_rows:
            raise Error(
                "ParquetFileWriter: column "
                + String(column_index)
                + " has "
                + String(length)
                + " rows, expected "
                + String(self.num_rows)
            )
        ref elem = self.schema_elements[schema_idx]
        if elem.repetition_type:
            return elem.repetition_type.value() == FieldRepetitionType.OPTIONAL
        return False

    def write_batch[dtype: DType](
        mut self,
        column_index: Int,
        array: PrimitiveArray[dtype],
    ) raises:
        """Write a fixed-width column as a PLAIN data page, with statistics.
        An OPTIONAL column gets definition levels and its nulls are skipped.
        """
        var nullable = self._begin_column(column_index, array.length)
        var name = self.schema_elements[column_index + 1].name
        var page = encode_plain_column[dtype](
            column_index, array, name, nullable=nullable, codec=self.codec
        )
        self.column_pages.append(page^)

    def write_batch_with_stats[dtype: DType](
        mut self,
        column_index: Int,
        array: PrimitiveArray[dtype],
        var stats: Statistics,
    ) raises:
        """`write_batch` with the caller's statistics in place of the ones
        the encoder computes."""
        var nullable = self._begin_column(column_index, array.length)
        var name = self.schema_elements[column_index + 1].name
        var page = encode_plain_column[dtype](
            column_index, array, name, nullable=nullable, codec=self.codec
        )
        page.statistics = stats^
        self.column_pages.append(page^)

    def write_nullable_batch[dtype: DType](
        mut self,
        column_index: Int,
        array: PrimitiveArray[dtype],
    ) raises:
        """`write_batch` for a column that may hold nulls. Nullability is the
        schema's: a REQUIRED column holding a null is refused."""
        self.write_batch[dtype](column_index, array)

    def write_string_batch(
        mut self,
        column_index: Int,
        string_array: StringArray[HeapRegion],
    ) raises:
        """Write a string column as a PLAIN BYTE_ARRAY data page."""
        var nullable = self._begin_column(column_index, string_array.length)
        var name = self.schema_elements[column_index + 1].name
        var page = encode_string_column_page(
            column_index,
            string_array,
            name,
            nullable=nullable,
            codec=self.codec,
        )
        self.column_pages.append(page^)

    def write_string_batch_dict(
        mut self,
        column_index: Int,
        string_array: StringArray[HeapRegion],
    ) raises:
        """Write a string column dictionary-encoded, or PLAIN when the
        column is too high-cardinality for a dictionary to pay.

        This is the method to prefer for string columns: low-cardinality
        columns come out much smaller at a small CPU cost.
        """
        var nullable = self._begin_column(column_index, string_array.length)
        var name = self.schema_elements[column_index + 1].name
        var dict_page = encode_dict_string_column_page(
            column_index,
            string_array,
            name,
            nullable=nullable,
            codec=self.codec,
        )
        if dict_page:
            self.column_pages.append(dict_page.take())
            return
        var page = encode_string_column_page(
            column_index,
            string_array,
            name,
            nullable=nullable,
            codec=self.codec,
        )
        self.column_pages.append(page^)

    def write_boolean_batch(
        mut self,
        column_index: Int,
        boolean_array: BooleanArray,
    ) raises:
        """Write a boolean column as a PLAIN bit-packed data page."""
        var nullable = self._begin_column(column_index, boolean_array.length)
        var name = self.schema_elements[column_index + 1].name
        var page = encode_boolean_column_page(
            column_index,
            boolean_array,
            name,
            nullable=nullable,
            codec=self.codec,
        )
        self.column_pages.append(page^)

    def write_column_page(mut self, var page: ColumnPage) raises:
        """Add a column chunk a page builder produced (DELTA_BINARY_PACKED,
        BYTE_STREAM_SPLIT, numeric dictionary, Decimal128 ...), checked as
        the `write_*` methods are. The page's own `column_index` places it.

        The caller built the page against this schema, so its nullability
        is the caller's to match.
        """
        _ = self._begin_column(page.column_index, page.num_values)
        self.column_pages.append(page^)

    def close_to_bytes(mut self) raises -> List[UInt8]:
        """Assemble the file (magic, column chunks, footer, footer length,
        magic) and return its bytes. Ends the writer.

        A file with no column written is a footer-only file with no row
        group. Every leaf of the schema must have been written if any was:
        a row group with fewer chunks than leaves is not a valid file.

        Raises:
            Error: the writer is already closed, a leaf column was never
                written, or the footer cannot be serialized.
        """
        if self.closed:
            raise Error("ParquetFileWriter: writer is already closed")
        var leaves = len(self.schema_elements) - 1
        if len(self.column_pages) > 0 and len(self.column_pages) != leaves:
            raise Error(
                "ParquetFileWriter: "
                + String(len(self.column_pages))
                + " of "
                + String(leaves)
                + " columns were written"
            )
        self.closed = True

        var file_bytes = List[UInt8]()
        append_magic(file_bytes)
        var chunks = List[ColumnChunk]()
        # Chunks go to the footer in schema order, whatever order they were
        # written in; the file holds them in written order.
        var by_leaf = List[Int]()
        for _ in range(leaves):
            by_leaf.append(-1)
        var offsets = List[Int]()
        for i in range(len(self.column_pages)):
            offsets.append(len(file_bytes))
            _append_bytes(file_bytes, self.column_pages[i].data)
            by_leaf[self.column_pages[i].column_index] = i
        for leaf in range(leaves):
            var i = by_leaf[leaf]
            if i >= 0:
                chunks.append(
                    column_chunk_for_page(self.column_pages[i], offsets[i])
                )
        var row_groups = List[RowGroup]()
        if len(chunks) > 0:
            row_groups.append(row_group_for_chunks(chunks^, self.num_rows))
        finish_file(file_bytes, self.schema_elements, self.num_rows, row_groups^)
        return file_bytes^
