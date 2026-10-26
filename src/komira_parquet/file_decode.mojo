# =============================================================================
# file_decode — a whole in-memory Parquet file to one RecordBatch
# =============================================================================
#
# `decode_parquet_file_from_bytes` takes the bytes of a complete Parquet file
# the caller already holds (read from an object store, produced by the
# writer, received over a wire) and returns every row group's rows as ONE
# batch, in file order. It is the I/O-free whole-file counterpart of the row
# group entry points of `bytes_decode`, which it is built on: the trailer
# (`PAR1` at both ends and the footer length) is checked, the footer parsed
# (`metadata_parser.parse_full_metadata`), each row group decoded out of its
# own byte range (`bytes_decode.decode_row_group_from_bytes`) and the row
# groups concatenated (`komira_arrow.concat`).
#
# Every malformed input is refused with an `Error` that names what is wrong:
# a buffer too short to hold a file, a missing magic, a footer length that
# does not fit the buffer, a footer that does not parse, a column chunk
# outside the data region, a nested column (this is the flat reader) and a
# file with no row group.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab

from .bytes_decode import decode_row_group_from_bytes, row_group_byte_range
from .metadata_parser import parse_full_metadata
from .morsel_reader import ColumnProjection

comptime _MAGIC_LEN = 4
comptime _TRAILER_LEN = 8
comptime _MIN_FILE_LEN = 12  # magic + footer length + magic, no footer


def _magic_at(file: ByteView[_], offset: Int) -> Bool:
    # "PAR1"
    return (
        file.read_u8_at(offset) == 0x50
        and file.read_u8_at(offset + 1) == 0x41
        and file.read_u8_at(offset + 2) == 0x52
        and file.read_u8_at(offset + 3) == 0x31
    )


def decode_parquet_file_from_bytes(
    file: ByteView[_],
    projection: ColumnProjection = ColumnProjection.all(),
) raises -> RecordBatch:
    """Decode a whole in-memory Parquet file into one batch.

    The row groups are decoded in file order and concatenated, so row `i` of
    the result is row `i` of the file. A row group that holds no rows
    contributes none.

    Args:
        file: The complete file, from its leading `PAR1` to its trailing one.
        projection: Which leaf columns, in output order (default: all).

    Returns:
        One batch with the footer's flat schema (the projected columns) and
        every row of the file.

    Raises:
        Error: `file` is shorter than the smallest possible file, lacks the
            `PAR1` magic at either end, names a footer length that does not
            fit, has a footer that does not parse, has no row group, has a
            nested column, has a column chunk outside the data region, or a
            chunk does not decode.
    """
    var n = file.len()
    if n < _MIN_FILE_LEN:
        raise Error(
            "decode_parquet_file_from_bytes: "
            + String(n)
            + " bytes is too short to be a Parquet file (at least "
            + String(_MIN_FILE_LEN)
            + " are needed)"
        )
    if not _magic_at(file, 0) or not _magic_at(file, n - _MAGIC_LEN):
        raise Error("decode_parquet_file_from_bytes: missing PAR1 magic")
    var footer_len = Int(file.read_u32_le_at(n - _TRAILER_LEN))
    var footer_start = n - _TRAILER_LEN - footer_len
    if footer_len == 0 or footer_start < _MAGIC_LEN:
        raise Error(
            "decode_parquet_file_from_bytes: footer length "
            + String(footer_len)
            + " does not fit in a file of "
            + String(n)
            + " bytes"
        )
    var md = parse_full_metadata(file.sub(footer_start, footer_len))
    if len(md.row_groups) == 0:
        raise Error("decode_parquet_file_from_bytes: the file has no row group")
    for i in range(1, len(md.schema)):
        if md.schema[i].num_children > 0:
            raise Error(
                "decode_parquet_file_from_bytes: column '"
                + md.schema[i].name
                + "' is nested; only flat files are read"
            )
    var groups = Slab[RecordBatch](capacity=len(md.row_groups))
    for g in range(len(md.row_groups)):
        ref rg = md.row_groups[g]
        var br = row_group_byte_range(rg)
        if len(rg.columns) > 0 and (
            br.start < _MAGIC_LEN
            or br.end < br.start
            or br.end > footer_start
        ):
            raise Error(
                "decode_parquet_file_from_bytes: row group "
                + String(g)
                + " names bytes ["
                + String(br.start)
                + ", "
                + String(br.end)
                + ") outside the data region ["
                + String(_MAGIC_LEN)
                + ", "
                + String(footer_start)
                + ")"
            )
        groups.append(
            decode_row_group_from_bytes(
                file.sub(br.start, br.length()),
                br,
                rg,
                md.schema,
                projection,
            )
        )
    if len(groups) == 1:
        var only = groups.pop()
        return only.take()
    return concat_record_batches_nway(groups^)
