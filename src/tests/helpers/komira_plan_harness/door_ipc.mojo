# =============================================================================
# komira_plan_harness/door_ipc.mojo -- an Arrow IPC stream, as a Table.
# =============================================================================
#
# Door B of a plan door (door.mojo) returns its result as the bytes of an
# Arrow IPC stream: `[Schema][RecordBatch]*[EOS]`, every message framed with
# the continuation marker (Arrow columnar format, "Encapsulated message
# format" and "IPC Streaming Format"). This file turns those bytes into a
# komira_arrow Table, one chunk per RecordBatch message, with the schema the
# Schema message declares (names, nullability, types), so canon renders the
# result of both doors from the same kind of value.
#
# What it reads, and what it refuses by name (`PLAN_DOOR_IPC_*`):
#   - the column types of the flat subset below: Int (8/16/32/64, signed and
#     unsigned), FloatingPoint (single, double), Utf8, LargeUtf8, Binary,
#     LargeBinary, Bool, Date (day, millisecond). Any other type tag, and a
#     dictionary-encoded field, is PLAN_DOOR_IPC_UNSUPPORTED_TYPE: a result
#     the harness cannot read is a refusal, never a guess.
#   - a DictionaryBatch message is PLAN_DOOR_IPC_UNSUPPORTED_TYPE too (no
#     dictionary field is admitted, so none can be referenced);
#   - a stream that does not start with a Schema message, a frame without
#     the continuation marker, a frame past the end, a missing EOS or bytes
#     after it are PLAN_DOOR_IPC_MALFORMED, naming the byte offset.
# The record batch bodies are decoded by komira_arrow_ipc's
# decode_record_batch_message, which checks every buffer against the frame.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    DATE_UNIT_DAY,
    DATE_UNIT_MILLISECOND,
    IPC_CONTINUATION_MARKER,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
    PRECISION_DOUBLE,
    PRECISION_SINGLE,
    TYPE_BINARY,
    TYPE_BOOL,
    TYPE_DATE,
    TYPE_FLOATING_POINT,
    TYPE_INT,
    TYPE_LARGE_BINARY,
    TYPE_LARGE_UTF8,
    TYPE_UTF8,
    FieldDescriptor,
    FlatbufReader,
    flatbuf_reader_over,
    read_message,
    read_schema,
    read_type_date,
    read_type_floating_point,
    read_type_int,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab


def _malformed(at: Int, what: String) -> Error:
    return Error(
        String("PLAN_DOOR_IPC_MALFORMED: at byte ") + String(at) + ": " + what
    )


def _unsupported(name: String, what: String) -> Error:
    return Error(
        String("PLAN_DOOR_IPC_UNSUPPORTED_TYPE: field `") + name + "`: " + what
    )


def _int_type(bits: Int, signed: Bool, name: String) raises -> ArrowType:
    if bits == 8:
        return ArrowType.INT8 if signed else ArrowType.UINT8
    if bits == 16:
        return ArrowType.INT16 if signed else ArrowType.UINT16
    if bits == 32:
        return ArrowType.INT32 if signed else ArrowType.UINT32
    if bits == 64:
        return ArrowType.INT64 if signed else ArrowType.UINT64
    raise _unsupported(name, String("Int of bit width ") + String(bits))


def _field_type[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], f: FieldDescriptor) raises -> ArrowType:
    """The komira ArrowType of one field of the flat subset, or the refusal."""
    if f.dictionary_encoding:
        raise _unsupported(f.name, "dictionary-encoded")
    var tag = f.type_tag
    if tag == TYPE_INT:
        var it = read_type_int(reader, f.type_table_pos)
        return _int_type(it.bit_width, it.is_signed, f.name)
    if tag == TYPE_FLOATING_POINT:
        var p = read_type_floating_point(reader, f.type_table_pos).precision
        if p == PRECISION_SINGLE:
            return ArrowType.FLOAT32
        if p == PRECISION_DOUBLE:
            return ArrowType.FLOAT64
        raise _unsupported(f.name, String("FloatingPoint precision ") + String(Int(p)))
    if tag == TYPE_UTF8:
        return ArrowType.STRING
    if tag == TYPE_LARGE_UTF8:
        return ArrowType.LARGE_STRING
    if tag == TYPE_BINARY:
        return ArrowType.BINARY
    if tag == TYPE_LARGE_BINARY:
        return ArrowType.LARGE_BINARY
    if tag == TYPE_BOOL:
        return ArrowType.BOOL
    if tag == TYPE_DATE:
        var unit = read_type_date(reader, f.type_table_pos).unit
        if unit == DATE_UNIT_DAY:
            return ArrowType.DATE32
        if unit == DATE_UNIT_MILLISECOND:
            return ArrowType.DATE64
        raise _unsupported(f.name, String("Date unit ") + String(Int(unit)))
    raise _unsupported(f.name, String("type tag ") + String(Int(tag)))


def _slice(src: SharedAlignedBuffer[HeapRegion], start: Int, n: Int) -> SharedAlignedBuffer[HeapRegion]:
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


def _schema_of(meta: SharedAlignedBuffer[HeapRegion], header_pos: Int) raises -> Schema:
    var reader = flatbuf_reader_over(meta)
    var desc = read_schema(reader, header_pos)
    var sb = SchemaBuilder()
    for i in range(len(desc.fields)):
        ref f = desc.fields[i]
        sb.add_field(Field(f.name, _field_type(reader, f), nullable=f.nullable))
    return sb.build()


def decode_ipc_stream(bytes: List[UInt8]) raises -> Table:
    """The Table an Arrow IPC stream holds: one chunk per RecordBatch message,
    under the schema of its Schema message. Raises PLAN_DOOR_IPC_MALFORMED or
    PLAN_DOOR_IPC_UNSUPPORTED_TYPE (see the file header)."""
    var n = len(bytes)
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    src.copy_from_bytes_list(bytes)
    src.set_length(n)
    var schema = Optional[Schema](None)
    var types = List[ArrowType]()
    var chunks = Slab[RecordBatch]()
    var at = 0
    var saw_eos = False
    while at + 8 <= n:
        if src.read_u32_le_at(at) != IPC_CONTINUATION_MARKER:
            raise _malformed(at, "no continuation marker")
        var meta_size = Int(src.read_u32_le_at(at + 4))
        if meta_size == 0:
            saw_eos = True
            at += 8
            break
        if at + 8 + meta_size > n:
            raise _malformed(at, "message metadata runs past the end")
        var meta = _slice(src, at + 8, meta_size)
        var reader = flatbuf_reader_over(meta)
        var msg = read_message(reader, reader.read_root_offset())
        var body = Int(msg.body_length)
        var frame_size = 8 + meta_size + body
        if body < 0 or at + frame_size > n:
            raise _malformed(at, "message body runs past the end")
        if not schema:
            if msg.header_tag != MESSAGE_HEADER_SCHEMA:
                raise _malformed(at, "the stream does not start with a Schema message")
            var s = _schema_of(meta, msg.header_table_pos)
            for i in range(s.num_columns()):
                types.append(s.field_arrow_type(i))
            schema = Optional[Schema](s^)
        elif msg.header_tag == MESSAGE_HEADER_RECORD_BATCH:
            var cols = decode_record_batch_message(_slice(src, at, frame_size), types)
            var nc = len(cols)
            var builder = RecordBatchBuilder.with_capacity(nc)
            for c in range(nc):
                builder.add_column(cols.take_slot_unchecked(c))
            cols.set_len_unchecked(0)
            chunks.append(builder.build(schema.value().copy()))
        elif msg.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            raise _unsupported("(dictionary batch)", "a DictionaryBatch message")
        else:
            raise _malformed(
                at, String("unexpected message header ") + String(Int(msg.header_tag))
            )
        at += frame_size
    if not saw_eos:
        raise _malformed(at, "the stream ends without the end-of-stream marker")
    if at != n:
        raise _malformed(at, String(n - at) + " bytes after the end-of-stream marker")
    if not schema:
        raise _malformed(0, "no Schema message")
    return Table.from_chunks(chunks^, schema.take())
