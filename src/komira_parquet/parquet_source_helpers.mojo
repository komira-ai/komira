# =============================================================================
# parquet_source_helpers — a Parquet source's row-group reads, by index or name
# =============================================================================
#
# The free functions a Parquet scan source calls to turn a row group into a
# batch. They take concrete footer types and a `ParquetFileReader`, hold no
# state, and name no source type:
#
#   * schema: the Arrow schema of a footer's leaves (`_build_schema_from_meta`,
#     `_build_schema_from_elements`);
#   * by index: `_decode_columns_subset_per_chunk` reads and decodes each
#     listed column chunk on its own (never the whole row group), with a
#     fresh decode context per chunk or (`_with_ctx`) the caller's reused
#     one; `_decode_numeric_dict_codes_one_col` reads one INT32 / INT64
#     dictionary chunk as codes. On an mmap-backed file system each chunk is
#     a borrow of the mapping; on any other (an object store) every chunk's
#     range is requested up front and decoded as its bytes arrive;
#   * by name, across files: `_resolve_result_names_to_file_indices` maps a
#     result schema's names to this file's leaves, `_build_union_by_name_schema`
#     unites several files' schemas (first-seen order; one name with two
#     types raises), and `_decode_columns_by_name_remap` decodes a row group
#     into the result's slots, a column the file lacks as typed nulls
#     (`parquet_source_constants`);
#   * `_advise_prefetch_next_rg`, a read-ahead hint for the next row group.
#
# Choices are arguments, never environment reads: `numeric_dict_vec` keeps
# a preserved INT32 / INT64 dictionary chunk as a numeric dictionary column.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_fs.file_system import FileSystem
from komira_parquet_api.metadata import ColumnChunk, FileMetaData, RowGroup, SchemaElement

from .bytes_decode import (
    ByteRange as ParquetByteRange,
    decode_column_chunk_from_bytes,
    decode_numeric_dict_codes_from_bytes,
)
from .column_decode_context import ColumnDecodeContext
from .column_decoder import NumericDictCodes
from .decode_helpers import field_from_schema_element
from .file_reader import ParquetFileReader
from .parquet_source_constants import _build_typed_all_null_column


def _copy_schema_elements(meta: FileMetaData) -> List[SchemaElement]:
    """A copy of the footer's flattened schema."""
    return meta.schema.copy()


def _build_schema_from_elements(schema_elements: List[SchemaElement]) raises -> Schema:
    """The Arrow schema of every element after the root (the leaves of a
    flat file), from the schema list alone."""
    var sb = SchemaBuilder()
    for c in range(1, len(schema_elements)):
        sb.add_field(field_from_schema_element(schema_elements[c]))
    return sb.build()


def _build_schema_from_meta(meta: FileMetaData) raises -> Schema:
    """`_build_schema_from_elements(meta.schema)`."""
    return _build_schema_from_elements(meta.schema)


def _aligned_buffer_to_list(buf: SharedAlignedBuffer[HeapRegion], length: Int) -> List[UInt8]:
    """The first `length` bytes of `buf`, copied into a List."""
    var out = List[UInt8](capacity=length)
    var view = buf.view_range_ro(0, length)
    for i in range(length):
        out.append(view.read_u8_at(i))
    return out^


def _chunk_range(chunk: ColumnChunk) -> Tuple[Int, Int]:
    """(first byte, byte count) of a chunk: from its dictionary page when
    that comes first, else its first data page."""
    ref meta = chunk.meta_data
    var start = meta.data_page_offset
    if meta.dictionary_page_offset:
        var d = meta.dictionary_page_offset.value()
        if d > 0 and d < start:
            start = d
    return (start, meta.total_compressed_size)


def _check_cols(rg: RowGroup, schema: List[SchemaElement], col_indices: List[Int]) raises:
    for i in range(len(col_indices)):
        var c = col_indices[i]
        if c < 0 or c >= len(rg.columns) or c + 1 >= len(schema):
            raise Error(
                "parquet source: column "
                + String(c)
                + " is not a leaf of a row group of "
                + String(len(rg.columns))
                + " columns"
            )


def _decode_chunks[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_indices: List[Int],
    preserve_dict: Bool,
    mut shared_ctx: ColumnDecodeContext,
    fresh_ctx_per_chunk: Bool,
    numeric_dict_vec: Bool,
) raises -> RecordBatch:
    """The listed columns of `rg`, each chunk read on its own and decoded
    with `shared_ctx` or, when `fresh_ctx_per_chunk`, a fresh context."""
    _check_cols(rg, schema, col_indices)
    var n = len(col_indices)
    var sb = SchemaBuilder()
    for i in range(n):
        sb.add_field(field_from_schema_element(schema[col_indices[i] + 1]))
    var out_schema = sb.build()
    var builder = RecordBatchBuilder.with_capacity(n)

    comptime if FS.IS_MMAP_BACKED:
        # A borrow of the mapping per chunk: there is no transfer to overlap.
        for i in range(n):
            var c = col_indices[i]
            var r = _chunk_range(rg.columns[c])
            var raw = reader.read_bytes(r[0], r[1])
            var br = ParquetByteRange(r[0], r[0] + r[1])
            if fresh_ctx_per_chunk:
                var ctx = ColumnDecodeContext(numeric_dict_vec)
                builder.add_column(
                    decode_column_chunk_from_bytes(
                        raw.view_range_ro(0, r[1]), br, rg.columns[c], schema[c + 1],
                        preserve_dict, ctx,
                    )
                )
            else:
                builder.add_column(
                    decode_column_chunk_from_bytes(
                        raw.view_range_ro(0, r[1]), br, rg.columns[c], schema[c + 1],
                        preserve_dict, shared_ctx,
                    )
                )
    else:
        # Every chunk's range requested up front; decoding chunk i overlaps
        # the transfer of the chunks after it. Buffers come back in order.
        var ranges = List[Tuple[Int64, Int64]]()
        for i in range(n):
            var r = _chunk_range(rg.columns[col_indices[i]])
            ranges.append((Int64(r[0]), Int64(r[1])))
        var fetched = reader.read_ranges_prefetched(ranges)
        for i in range(n):
            var c = col_indices[i]
            var r = _chunk_range(rg.columns[c])
            var br = ParquetByteRange(r[0], r[0] + r[1])
            if fresh_ctx_per_chunk:
                var ctx = ColumnDecodeContext(numeric_dict_vec)
                builder.add_column(
                    decode_column_chunk_from_bytes(
                        fetched[i].view_range_ro(0, r[1]), br, rg.columns[c],
                        schema[c + 1], preserve_dict, ctx,
                    )
                )
            else:
                builder.add_column(
                    decode_column_chunk_from_bytes(
                        fetched[i].view_range_ro(0, r[1]), br, rg.columns[c],
                        schema[c + 1], preserve_dict, shared_ctx,
                    )
                )
    return builder.build(out_schema^)


def _decode_columns_subset_per_chunk[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_indices: List[Int],
    preserve_dict: Bool,
    numeric_dict_vec: Bool = False,
) raises -> RecordBatch:
    """The listed leaf columns of `rg`, in that order: each chunk read on
    its own and decoded with a fresh context.

    Args:
        reader: The file's reader.
        rg: The row group's footer entry.
        schema: The footer's flattened schema.
        col_indices: 0-based leaf indices.
        preserve_dict: A BYTE_ARRAY dictionary chunk stays a DICTIONARY
            column.
        numeric_dict_vec: With `preserve_dict`, a non-null INT32 / INT64
            dictionary chunk becomes a numeric dictionary column.

    Raises:
        Error if an index is not a leaf, a chunk is outside the file, or a
        chunk does not decode.
    """
    var unused = ColumnDecodeContext()
    return _decode_chunks(
        reader, rg, schema, col_indices, preserve_dict, unused, True,
        preserve_dict and numeric_dict_vec,
    )


def _decode_columns_subset_per_chunk_with_ctx[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_indices: List[Int],
    preserve_dict: Bool,
    mut decode_ctx: ColumnDecodeContext,
) raises -> RecordBatch:
    """`_decode_columns_subset_per_chunk`, every chunk decoded with the
    caller's `decode_ctx`, whose buffers (and choices) carry across the
    chunks and row groups a worker decodes."""
    return _decode_chunks(
        reader, rg, schema, col_indices, preserve_dict, decode_ctx, False, False
    )


def _decode_numeric_dict_codes_one_col[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_idx: Int,
) raises -> Optional[NumericDictCodes]:
    """Leaf `col_idx` of `rg` as dictionary codes and entries when it is an
    INT32 / INT64 dictionary chunk (else None; see
    `bytes_decode.decode_numeric_dict_codes_from_bytes`). Reads that chunk
    only."""
    _check_cols(rg, schema, [col_idx])
    ref chunk = rg.columns[col_idx]
    var r = _chunk_range(chunk)
    var br = ParquetByteRange(r[0], r[0] + r[1])
    comptime if FS.IS_MMAP_BACKED:
        var raw = reader.read_bytes(r[0], r[1])
        return decode_numeric_dict_codes_from_bytes(
            raw.view_range_ro(0, r[1]), br, chunk, schema[col_idx + 1]
        )
    else:
        var ranges = List[Tuple[Int64, Int64]]()
        ranges.append((Int64(r[0]), Int64(r[1])))
        var fetched = reader.read_ranges_prefetched(ranges)
        return decode_numeric_dict_codes_from_bytes(
            fetched[0].view_range_ro(0, r[1]), br, chunk, schema[col_idx + 1]
        )


def _read_rg_bulk_bytes[FS: FileSystem](
    reader: ParquetFileReader[FS], rg_offset: Int, rg_length: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A row group's whole byte range."""
    return reader.read_bytes(rg_offset, rg_length)


def _name_to_file_col_idx(meta: FileMetaData, name: String) -> Int:
    """The 0-based leaf index of the schema element named `name` (a flat
    file's elements after the root are its leaves), or -1."""
    for i in range(1, len(meta.schema)):
        if meta.schema[i].name == name:
            return i - 1
    return -1


def _resolve_result_names_to_file_indices(
    meta: FileMetaData, result_names: List[String]
) -> List[Int]:
    """Per result column name, this file's leaf index, or -1 when the
    file lacks it."""
    var out = List[Int](capacity=len(result_names))
    for i in range(len(result_names)):
        out.append(_name_to_file_col_idx(meta, result_names[i]))
    return out^


def _build_union_by_name_schema(
    file_schemas: List[Schema], file_paths: List[String]
) raises -> Tuple[List[String], List[ArrowType]]:
    """The union of the files' columns by name, in first-seen order (files
    in the given order, columns in file order): (names, types).

    Raises:
        Error naming both files and both types when one name has two
        Arrow types (no widening).
    """
    var names = List[String]()
    var types = List[ArrowType]()
    var owner = List[Int]()
    for f in range(len(file_schemas)):
        ref sch = file_schemas[f]
        for c in range(sch.num_columns()):
            var name = sch.field_name(c)
            var t = sch.field_arrow_type(c)
            var found = -1
            for u in range(len(names)):
                if names[u] == name:
                    found = u
                    break
            if found < 0:
                names.append(name)
                types.append(t)
                owner.append(f)
            elif types[found] != t:
                var first = owner[found]
                var first_path = (
                    file_paths[first] if first < len(file_paths) else "file[" + String(first) + "]"
                )
                var this_path = file_paths[f] if f < len(file_paths) else "file[" + String(f) + "]"
                raise Error(
                    "union_by_name: column '"
                    + name
                    + "' is "
                    + String(types[found])
                    + " in "
                    + first_path
                    + " but "
                    + String(t)
                    + " in "
                    + this_path
                    + " (the types must match exactly)"
                )
    return (names^, types^)


def _remap_is_positional_identity(remap: List[Int], total_file_cols: Int) -> Bool:
    """The remap reads every file column, in file order (result slot i is
    file leaf i)."""
    if len(remap) != total_file_cols:
        return False
    for i in range(len(remap)):
        if remap[i] != i:
            return False
    return True


def _decode_columns_by_name_remap[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema_copy: List[SchemaElement],
    remap: List[Int],
    result_names: List[String],
    result_types: List[ArrowType],
    n_rows: Int,
    preserve_dict: Bool,
    numeric_dict_vec: Bool = False,
) raises -> RecordBatch:
    """A row group decoded into the result schema's slots by name.

    `remap[i]` is this file's leaf for result slot `i` (decoded, with the
    file's field), or -1 (`n_rows` nulls of `result_types[i]`, a nullable
    field named `result_names[i]`).

    Raises:
        Error if the remap and the result lists differ in length, a leaf
        index is out of range, or a chunk does not decode.
    """
    var n = len(remap)
    if len(result_names) != n or len(result_types) != n:
        raise Error(
            "by-name remap: "
            + String(n)
            + " slots but "
            + String(len(result_names))
            + " names and "
            + String(len(result_types))
            + " types"
        )
    var present = List[Int]()
    for i in range(n):
        if remap[i] >= 0:
            present.append(remap[i])
    var decoded = _decode_columns_subset_per_chunk(
        reader, rg, schema_copy, present, preserve_dict, numeric_dict_vec
    )
    var cols = decoded.take_columns()
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder.with_capacity(n)
    var k = 0
    for i in range(n):
        if remap[i] >= 0:
            sb.add_field(decoded.schema.field_at(k))
            builder.add_column(cols.take_at(0))
            k += 1
        else:
            sb.add_field(Field(result_names[i], result_types[i], True))
            builder.add_column(_build_typed_all_null_column(result_types[i], n_rows))
    var out_schema = sb.build()
    return builder.build(out_schema^)


def _advise_prefetch_next_rg[FS: FileSystem](
    reader: ParquetFileReader[FS], meta: FileMetaData, next_rg_idx: Int
):
    """A best-effort read-ahead hint for row group `next_rg_idx`'s first
    column chunk; nothing when there is no such row group or column."""
    if next_rg_idx < 0 or next_rg_idx >= len(meta.row_groups):
        return
    ref rg = meta.row_groups[next_rg_idx]
    if len(rg.columns) == 0:
        return
    var r = _chunk_range(rg.columns[0])
    _ = reader.advise_prefetch(r[0], r[1])
