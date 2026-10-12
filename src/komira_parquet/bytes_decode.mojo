# =============================================================================
# bytes_decode — decode a row group from bytes the caller already holds
# =============================================================================
#
# The I/O-free decode entry points. The caller fetches a row group's bytes
# however it likes (pread, an object-store range GET, a mapping) and hands
# them over as a `ByteView` with the absolute file range they cover
# (`ByteRange`); the footer gives each column chunk's absolute offsets, and
# these functions find the chunk inside the view, decode it
# (`column_decoder.decode_column_pages`, then the type re-stamps of
# `morsel_reader.restamp_decoded_column`) and build the batch.
#
#   | entry                                  | decodes                       |
#   |----------------------------------------|-------------------------------|
#   | row_group_byte_range(rg)               | (nothing: the bytes to fetch) |
#   | decode_row_group_from_bytes            | a projection of a row group   |
#   | decode_row_group_columns_subset        | listed columns of a row group |
#   | decode_column_chunk_from_bytes         | one column chunk, with the    |
#   |                                        | caller's reusable context     |
#   | decode_numeric_dict_codes_from_bytes   | an INT32 / INT64 dictionary   |
#   |                                        | chunk as codes + entries      |
#
# Every chunk must lie inside the given range; one that does not is refused
# (the caller fetched too few bytes). Every chunk decoded is counted
# (`komira_counters.parquet_note_column_chunk_decoded`). The functions hold
# no state, so workers may call them concurrently on their own bytes.
# =============================================================================

from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_counters.parquet_read_counter import (
    parquet_note_column_chunk_decoded,
)
from komira_parquet_api.metadata import ColumnChunk, RowGroup, SchemaElement
from komira_parquet_api.types import FieldRepetitionType, ParquetType

from .column_decode_context import ColumnDecodeContext
from .column_decoder import (
    NumericDictCodes,
    NumericDictCodesHolder,
    decode_column_pages,
)
from .decode_helpers import field_from_schema_element, flba_schema_info
from .morsel_reader import ColumnProjection, restamp_decoded_column


@fieldwise_init
struct ByteRange(Copyable, Movable):
    """The absolute file byte range `[start, end)` a `ByteView` covers."""

    var start: Int
    var end: Int

    def length(self) -> Int:
        """The number of bytes in the range."""
        return self.end - self.start

    def contains(self, abs_offset: Int, abs_length: Int) -> Bool:
        """`[abs_offset, abs_offset + abs_length)` lies inside this range
        (a negative offset or length never does)."""
        return (
            abs_offset >= self.start
            and abs_length >= 0
            and abs_offset + abs_length <= self.end
        )


def _chunk_lo(chunk: ColumnChunk) -> Int:
    """A chunk's first byte: its dictionary page when that comes first,
    else its first data page."""
    var lo = chunk.meta_data.data_page_offset
    if chunk.meta_data.dictionary_page_offset:
        var d = chunk.meta_data.dictionary_page_offset.value()
        if d < lo:
            lo = d
    return lo


def row_group_byte_range(rg: RowGroup) -> ByteRange:
    """The smallest range covering every column chunk of `rg` (the bytes
    to fetch before decoding it); `ByteRange(0, 0)` for no columns."""
    var n = len(rg.columns)
    if n == 0:
        return ByteRange(0, 0)
    var lo = _chunk_lo(rg.columns[0])
    var hi = lo + rg.columns[0].meta_data.total_compressed_size
    for i in range(1, n):
        ref c = rg.columns[i]
        var c_lo = _chunk_lo(c)
        var c_hi = c_lo + c.meta_data.total_compressed_size
        if c_lo < lo:
            lo = c_lo
        if c_hi > hi:
            hi = c_hi
    return ByteRange(lo, hi)


def _check_view(
    what: String, bytes_view: ByteView[_], byte_range: ByteRange
) raises:
    if bytes_view.len() != byte_range.length():
        raise Error(
            what
            + ": bytes_view length "
            + String(bytes_view.len())
            + " does not match byte_range length "
            + String(byte_range.length())
        )


def _chunk_view[
    mut: Bool, //, origin: Origin[mut=mut]
](
    what: String,
    bytes_view: ByteView[origin],
    byte_range: ByteRange,
    chunk: ColumnChunk,
) raises -> ByteView[origin]:
    """The chunk's bytes inside `bytes_view`, or an error naming the chunk
    when they are not all there."""
    var lo = _chunk_lo(chunk)
    var size = chunk.meta_data.total_compressed_size
    if not byte_range.contains(lo, size):
        raise Error(
            what
            + ": column chunk at file offset "
            + String(lo)
            + " size "
            + String(size)
            + " is not contained in byte_range ["
            + String(byte_range.start)
            + ", "
            + String(byte_range.end)
            + ")"
        )
    return bytes_view.sub(lo - byte_range.start, size)


def _nullable(elem: SchemaElement) -> Bool:
    """REQUIRED columns carry no definition levels; anything else does."""
    if elem.repetition_type:
        return elem.repetition_type.value() != FieldRepetitionType.REQUIRED
    return True


def _check_leaf(what: String, schema: List[SchemaElement], rg: RowGroup, col_idx: Int) raises:
    if col_idx < 0 or col_idx >= len(rg.columns) or col_idx + 1 >= len(schema):
        raise Error(
            what
            + ": column "
            + String(col_idx)
            + " is not a leaf of a row group of "
            + String(len(rg.columns))
            + " columns"
        )


def decode_column_chunk_from_bytes(
    bytes_view: ByteView[_],
    byte_range: ByteRange,
    chunk: ColumnChunk,
    schema_elem: SchemaElement,
    preserve_dict: Bool,
    mut decode_ctx: ColumnDecodeContext,
) raises -> Column[HeapRegion]:
    """Decode one column chunk out of `bytes_view`.

    Args:
        bytes_view: Bytes covering at least the chunk.
        byte_range: The absolute file range `bytes_view` covers.
        chunk: The chunk's footer entry.
        schema_elem: Its leaf schema element (nullability, FLBA width,
            DECIMAL scale and precision, annotations).
        preserve_dict: A BYTE_ARRAY dictionary chunk stays a DICTIONARY
            column.
        decode_ctx: Reusable decode buffers; a caller decoding several
            chunks in turn passes the same one.

    Raises:
        Error if the chunk is not inside `byte_range`, or its pages do not
        decode.
    """
    var view = _chunk_view(
        "decode_column_chunk_from_bytes", bytes_view, byte_range, chunk
    )
    ref meta = chunk.meta_data
    parquet_note_column_chunk_decoded(meta.total_compressed_size)
    var info = flba_schema_info(schema_elem)
    var ts_unit = -1
    if schema_elem.logical_timestamp_unit:
        ts_unit = schema_elem.logical_timestamp_unit.value()
    var no_fuse = NumericDictCodesHolder()
    var col = decode_column_pages(
        view.into_span(),
        meta.type,
        meta.codec,
        meta.num_values,
        _nullable(schema_elem),
        False,
        no_fuse,
        decode_ctx,
        info[0],
        info[1],
        info[2],
        preserve_dict,
        info[3],
    )
    return restamp_decoded_column(col^, meta.type, info[1], ts_unit)


def decode_numeric_dict_codes_from_bytes(
    bytes_view: ByteView[_],
    byte_range: ByteRange,
    chunk: ColumnChunk,
    schema_elem: SchemaElement,
) raises -> Optional[NumericDictCodes]:
    """An INT32 / INT64 dictionary chunk as its codes and dictionary
    entries, without gathering a value per row; None for any other chunk
    (another type, a DECIMAL, PLAIN pages after the dictionary), which the
    caller decodes as values.

    A nullable chunk is taken: its codes are those of the non-null rows,
    so a count over them of the codes a predicate accepts counts the rows
    it accepts (a null row satisfies no comparison).

    Raises:
        Error if the chunk is not inside `byte_range`, or its pages do not
        decode.
    """
    ref meta = chunk.meta_data
    if meta.type != ParquetType.INT32 and meta.type != ParquetType.INT64:
        return None
    var view = _chunk_view(
        "decode_numeric_dict_codes_from_bytes", bytes_view, byte_range, chunk
    )
    parquet_note_column_chunk_decoded(meta.total_compressed_size)
    var info = flba_schema_info(schema_elem)
    var holder = NumericDictCodesHolder()
    var ctx = ColumnDecodeContext()
    # With the fused count on, a chunk it takes comes back in `holder` and
    # the column is an empty placeholder; any other chunk decodes to a
    # real column, which is dropped (the caller decodes it as values).
    _ = decode_column_pages(
        view.into_span(),
        meta.type,
        meta.codec,
        meta.num_values,
        _nullable(schema_elem),
        True,
        holder,
        ctx,
        info[0],
        info[1],
        info[2],
        True,
        info[3],
    )
    if not holder.out:
        return None
    return holder.out.take()


def decode_row_group_columns_subset(
    bytes_view: ByteView[_],
    byte_range: ByteRange,
    rg: RowGroup,
    schema: List[SchemaElement],
    col_indices: List[Int],
    preserve_dict: Bool = False,
) raises -> RecordBatch:
    """The listed leaf columns of `rg`, in that order, decoded out of
    `bytes_view` (which must cover exactly `byte_range`).

    Raises:
        Error if the view and range differ in length, an index is not a
        leaf, a chunk is not inside the range, or a chunk does not decode.
    """
    comptime what = "decode_row_group_columns_subset"
    _check_view(what, bytes_view, byte_range)
    var sb = SchemaBuilder()
    for i in range(len(col_indices)):
        _check_leaf(what, schema, rg, col_indices[i])
        sb.add_field(field_from_schema_element(schema[col_indices[i] + 1]))
    var out_schema = sb.build()
    var builder = RecordBatchBuilder.with_capacity(len(col_indices))
    for i in range(len(col_indices)):
        var c = col_indices[i]
        var ctx = ColumnDecodeContext()
        builder.add_column(
            decode_column_chunk_from_bytes(
                bytes_view,
                byte_range,
                rg.columns[c],
                schema[c + 1],
                preserve_dict,
                ctx,
            )
        )
    return builder.build(out_schema^)


def decode_row_group_from_bytes(
    bytes_view: ByteView[_],
    byte_range: ByteRange,
    rg: RowGroup,
    schema: List[SchemaElement],
    projection: ColumnProjection,
    preserve_dict: Bool = False,
) raises -> RecordBatch:
    """The projected columns of `rg`, decoded out of `bytes_view`.

    Args:
        bytes_view: The row group's bytes; its length must equal
            `byte_range.length()` (fetch `row_group_byte_range(rg)`).
        byte_range: The absolute file range the view covers.
        rg: The row group's footer entry.
        schema: The footer's flattened schema (root at 0, leaf `i` at
            `i + 1`).
        projection: Which leaf columns, in output order.
        preserve_dict: A BYTE_ARRAY dictionary chunk stays a DICTIONARY
            column.

    Raises:
        As `decode_row_group_columns_subset`.
    """
    return decode_row_group_columns_subset(
        bytes_view,
        byte_range,
        rg,
        schema,
        projection.projected_indices(len(rg.columns)),
        preserve_dict,
    )
