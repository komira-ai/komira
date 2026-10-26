# =============================================================================
# delta_codec -- the delta object: a framed blob for a few rows, Parquet for
#   more.
# =============================================================================
#
# A delta object holds the rows one table gained in one ingest. One added row
# written as a standalone Parquet file costs kilobytes of footer and per-column
# headers, many times the row. So a delta of fewer than `FRAMED_MAX_ROWS` rows,
# whose columns are all int64 or string and hold no null, is written as a
# compact framed blob; any other delta is written as Parquet. The first byte of
# every delta object says which, so a reader decodes both:
#
#   [ u8 tag ]   FRAME_TAG_PARQUET (0): the rest is a Parquet file
#                FRAME_TAG_FRAMED  (1): the rest is a framed blob
#
#   framed blob, little-endian:
#     [ codec_version: i64 = FRAMED_CODEC_VERSION ]
#     [ num_columns: i64 ] [ num_rows: i64 ]
#     repeated num_columns times:
#       [ type_code: i64 ]               # the column's ArrowType.type_id
#       INT64:                num_rows x [ value: i64 ]
#       STRING, LARGE_STRING: num_rows x [ byte_len: i64 ][ bytes ]
#
# A string cell is stored by length and copied byte for byte, never as text: an
# embedding cell is packed floats, which hold zero bytes and are not UTF-8, and
# they must come back unchanged. For the same reason the decoder does not check
# a cell for UTF-8; the schema says which columns are text.
#
# A framed object decodes to a batch whose columns are INT64 and STRING (a
# LARGE_STRING column decodes to STRING, which is what the Parquet reader
# returns for one) and are named `c0`, `c1`, ...: a reader finds columns by
# position, as it does for a Parquet delta.
#
# The framed object is read from object storage, so `decode_framed_delta_to_batch`
# refuses every malformed body: a wrong tag or codec version, no column, a
# negative or oversized dimension (checked against the bytes present before
# anything is allocated), an unknown column type, a cell that runs past the end
# and bytes left over.
#
# `delta_object_parquet_bytes` hands back the Parquet file; decoding it is the
# Parquet reader's job (`decode_parquet_file_from_bytes`), which the snapshot
# store calls.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_builder import ArrowStringBuilder
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)

from .wire import get_i64_le, put_i64_le


# The first byte of a delta object.
comptime FRAME_TAG_PARQUET: UInt8 = 0
comptime FRAME_TAG_FRAMED: UInt8 = 1

# The version of the framed blob; the decoder accepts only this one.
comptime FRAMED_CODEC_VERSION: Int64 = 1

# A delta of fewer rows than this (and only int64 and string columns, no null)
# is framed. The row count is known without serializing twice, and it separates
# a few rows, where Parquet's fixed per-file structure dwarfs the data, from a
# batch, where its encoding and compression pay for themselves. Byte size would
# be a poor axis: one embedding cell is wider than many short rows.
comptime FRAMED_MAX_ROWS: Int = 64

# String offsets are int32, so a body that could hold more than this many string
# bytes is refused whole.
comptime _MAX_FRAMED_BYTES: Int = 2147483647


def _is_string_type(t: ArrowType) -> Bool:
    return t == ArrowType.STRING or t == ArrowType.LARGE_STRING


def _all_columns_framable(batch: RecordBatch) raises -> Bool:
    """True iff the batch has a column, every column is INT64 or a string type,
    and no column holds a null (the framed blob has no validity)."""
    if batch.num_columns() == 0:
        return False
    for c in range(batch.num_columns()):
        var t = batch.column_at(c).arrow_type
        if t == ArrowType.INT64:
            if batch.column_as_primitive_int64(c).null_count > 0:
                return False
        elif _is_string_type(t):
            if batch.column_as_string(c).null_count > 0:
                return False
        else:
            return False
    return True


def _align_string_schema(mut batch: RecordBatch) raises:
    """Make each string field of the schema name the width of its column's
    buffers (STRING for int32 offsets, LARGE_STRING for int64 offsets).

    A builder that stores its cells in a STRING column under a schema that says
    LARGE_STRING describes one layout twice: the accessors would read it as the
    other. Only the label changes; the buffers are untouched.
    """
    var differs = False
    for i in range(batch.schema.num_columns()):
        var ct = batch.column_at(i).arrow_type
        var st = batch.schema.field_arrow_type(i)
        if ct != st and _is_string_type(ct) and _is_string_type(st):
            differs = True
            break
    if not differs:
        return
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        var ct = batch.column_at(i).arrow_type
        var st = batch.schema.field_arrow_type(i)
        var t = ct if (ct != st and _is_string_type(ct) and _is_string_type(st)) else st
        sb.add_field(
            Field(
                batch.schema.field_name(i), t, batch.schema.field_nullable(i)
            )
        )
    batch.schema = sb.build()


def _encode_framed(batch: RecordBatch) raises -> List[UInt8]:
    var out = List[UInt8]()
    out.append(FRAME_TAG_FRAMED)
    put_i64_le(out, FRAMED_CODEC_VERSION)
    var ncols = batch.num_columns()
    var nrows = batch.num_rows()
    put_i64_le(out, Int64(ncols))
    put_i64_le(out, Int64(nrows))
    for c in range(ncols):
        var t = batch.column_at(c).arrow_type
        put_i64_le(out, Int64(Int(t.type_id)))
        if t == ArrowType.INT64:
            var col = batch.column_as_primitive_int64(c)
            for r in range(nrows):
                put_i64_le(out, col.get(r))
        else:
            var col = batch.column_as_string(c)
            for r in range(nrows):
                var sp = col.get_span(r)
                put_i64_le(out, Int64(len(sp)))
                out.extend(sp)
    return out^


def encode_delta_table_object(var batch: RecordBatch) raises -> List[UInt8]:
    """Encode one table's added rows as a delta object.

    A batch of fewer than `FRAMED_MAX_ROWS` rows whose columns are all INT64 or
    string and hold no null becomes a framed blob; anything else becomes a
    Parquet file (Snappy). Byte 0 of the result is the tag that says which.

    Args:
        batch: The rows, consumed.

    Raises:
        If the batch has no column (an empty delta is not a delta), or the
        Parquet writer refuses a column.
    """
    if batch.num_columns() == 0:
        raise Error("encode_delta_table_object: batch has no columns")
    _align_string_schema(batch)
    if batch.num_rows() < FRAMED_MAX_ROWS and _all_columns_framable(batch):
        return _encode_framed(batch)
    var pq = write_record_batch_to_parquet_bytes(batch, CompressionCodec.SNAPPY)
    var out = List[UInt8](capacity=len(pq) + 1)
    out.append(FRAME_TAG_PARQUET)
    out.extend(Span(pq))
    return out^


def delta_object_is_framed(body: List[UInt8]) raises -> Bool:
    """Whether a delta object is a framed blob (True) or Parquet (False), read
    from its tag byte.

    Raises:
        On an empty body or a tag that is neither.
    """
    if len(body) == 0:
        raise Error("delta_object_is_framed: empty delta object body")
    var tag = body[0]
    if tag == FRAME_TAG_FRAMED:
        return True
    if tag == FRAME_TAG_PARQUET:
        return False
    raise Error(
        "delta_object_is_framed: unknown framing tag "
        + String(Int(tag))
        + " (expected "
        + String(Int(FRAME_TAG_PARQUET))
        + " parquet or "
        + String(Int(FRAME_TAG_FRAMED))
        + " framed)"
    )


def delta_object_parquet_bytes(body: List[UInt8]) raises -> List[UInt8]:
    """The Parquet file inside a Parquet delta object (the body without its tag).

    Raises:
        On an empty body, an unknown tag, or a framed object.
    """
    if delta_object_is_framed(body):
        raise Error("delta_object_parquet_bytes: body is framed, not Parquet")
    var out = List[UInt8](capacity=len(body) - 1)
    out.extend(Span(body)[1:])
    return out^


def decode_framed_delta_to_batch(body: List[UInt8]) raises -> RecordBatch:
    """Decode a framed delta object to a batch of INT64 and STRING columns
    named `c0`, `c1`, ... (see the file header).

    Raises:
        On any malformed body, as the file header lists.
    """
    var who = String("decode_framed_delta_to_batch")
    if len(body) == 0 or body[0] != FRAME_TAG_FRAMED:
        raise Error(who + ": not a framed body")
    if len(body) > _MAX_FRAMED_BYTES:
        raise Error(who + ": body of " + String(len(body)) + " bytes is too large")
    var off = 1
    var ver = get_i64_le(body, off, who)
    off += 8
    if ver != FRAMED_CODEC_VERSION:
        raise Error(
            who
            + ": unsupported framed codec version "
            + String(ver)
            + " (this build understands "
            + String(FRAMED_CODEC_VERSION)
            + ")"
        )
    var ncols_raw = get_i64_le(body, off, who)
    off += 8
    var nrows_raw = get_i64_le(body, off, who)
    off += 8
    if ncols_raw <= 0 or nrows_raw < 0:
        raise Error(
            who
            + ": invalid dimensions (columns="
            + String(ncols_raw)
            + ", rows="
            + String(nrows_raw)
            + ")"
        )
    # Every column holds a type code and, per row, at least eight bytes. A
    # dimension the bytes present cannot hold is refused before it sizes
    # anything.
    var words = (len(body) - off) // 8
    if ncols_raw > Int64(words) or nrows_raw > Int64(words):
        raise Error(who + ": truncated: the dimensions exceed the bytes present")
    var ncols = Int(ncols_raw)
    var nrows = Int(nrows_raw)
    # Both are at most the number of words, so the product cannot overflow.
    if ncols * (1 + nrows) > words:
        raise Error(
            who
            + ": truncated: "
            + String(ncols)
            + " columns of "
            + String(nrows)
            + " rows do not fit"
        )

    var rb = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for c in range(ncols):
        var type_code = get_i64_le(body, off, who)
        off += 8
        if type_code == Int64(Int(ArrowType.INT64.type_id)):
            var vals = List[Int64](capacity=nrows)
            for _r in range(nrows):
                vals.append(get_i64_le(body, off, who))
                off += 8
            rb.add_column(
                Column.from_primitive[DType.int64](
                    PrimitiveArray[DType.int64].from_list(vals)
                )
            )
            sb.add_field(Field("c" + String(c), ArrowType.INT64, False))
        elif type_code == Int64(Int(ArrowType.STRING.type_id)) or type_code == Int64(
            Int(ArrowType.LARGE_STRING.type_id)
        ):
            var cells = ArrowStringBuilder()
            for _r in range(nrows):
                var blen = get_i64_le(body, off, who)
                off += 8
                if blen < 0 or blen > Int64(len(body) - off):
                    raise Error(
                        who
                        + ": truncated string cell (length "
                        + String(blen)
                        + " at offset "
                        + String(off)
                        + ")"
                    )
                var n = Int(blen)
                cells.push_bytes(Span(body)[off : off + n])
                off += n
            rb.add_column(cells^.build())
            sb.add_field(Field("c" + String(c), ArrowType.STRING, False))
        else:
            raise Error(
                who + ": unframable column type code " + String(type_code)
            )
    if off != len(body):
        raise Error(
            who
            + ": "
            + String(len(body) - off)
            + " trailing bytes after the last column"
        )
    return rb.build(sb.build())
