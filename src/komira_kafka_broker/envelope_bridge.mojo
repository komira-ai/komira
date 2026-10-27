# =============================================================================
# envelope_bridge.mojo: Kafka records <-> an Arrow RecordBatch with the fixed
# envelope schema.
# =============================================================================
#
# Translates between Kafka records `(key, value, headers, timestamp, offset)`
# and a komira_arrow `RecordBatch` with five fixed columns:
#
#     __key       binary  (nullable)   opaque bytes (Kafka is schemaless)
#     __value     binary  (nullable)   opaque bytes
#     __timestamp int64                record timestamp in ms
#     __offset    int64                record offset: on the produce side the
#                                      client's value, renumbered when the
#                                      broker commits
#     __headers   binary  (nullable)   the serialized Kafka header block
#                                      (count varint, then each name and
#                                      value) as opaque bytes; a record
#                                      without headers has the block of count
#                                      0, and a null or empty cell is read as
#                                      no headers
#
# The mapping lives here, at the Kafka edge, so the broker core only ever sees
# a RecordBatch and an offset. The module depends on komira_arrow and the
# record types of komira_kafka_server.wire only.
#
# No pointer type appears in any signature: these are value transforms over
# owned Lists and a RecordBatch.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion

from komira_kafka_server.wire.record_batch_v2 import KafkaHeader, KafkaRecord
from komira_kafka_server.wire import KafkaDecoder


comptime ENVELOPE_KEY: String = "__key"
comptime ENVELOPE_VALUE: String = "__value"
comptime ENVELOPE_TIMESTAMP: String = "__timestamp"
comptime ENVELOPE_OFFSET: String = "__offset"
comptime ENVELOPE_HEADERS: String = "__headers"


def envelope_schema() raises -> Schema:
    """The fixed envelope schema (the same 5 columns every Komira topic uses
    when fronted by the Kafka Format edge)."""
    var b = SchemaBuilder()
    b.add_field(Field(ENVELOPE_KEY, ArrowType.BINARY, True))
    b.add_field(Field(ENVELOPE_VALUE, ArrowType.BINARY, True))
    b.add_field(Field(ENVELOPE_TIMESTAMP, ArrowType.INT64, False))
    b.add_field(Field(ENVELOPE_OFFSET, ArrowType.INT64, False))
    b.add_field(Field(ENVELOPE_HEADERS, ArrowType.BINARY, True))
    return b.build()


# -----------------------------------------------------------------------------
# Header (de)serialization — the __headers column carries the Kafka header block
# as opaque bytes: varint count + each (nameLen varint, name, valueLen+1 varint
# (0=null), value). Uses unsigned varints (`_put_uvarint`).
# -----------------------------------------------------------------------------


def _put_uvarint(mut out: List[UInt8], value: Int):
    """Unsigned varint (the header block uses small non-negative counts/lens)."""
    var v = value
    while True:
        var low = UInt8(v & 0x7F)
        v = v >> 7
        if v != 0:
            out.append(low | UInt8(0x80))
        else:
            out.append(low)
            break


def _serialize_headers(headers: List[KafkaHeader]) -> List[UInt8]:
    var out = List[UInt8]()
    _put_uvarint(out, len(headers))
    for hi in range(len(headers)):
        ref h = headers[hi]
        _put_uvarint(out, len(h.key))
        for i in range(len(h.key)):
            out.append(h.key[i])
        if h.value:
            ref hv = h.value.value()
            _put_uvarint(out, len(hv) + 1)  # +1 so 0 == null
            for i in range(len(hv)):
                out.append(hv[i])
        else:
            _put_uvarint(out, 0)  # null value
    return out^


def _deserialize_headers(data: List[UInt8]) raises -> List[KafkaHeader]:
    var out = List[KafkaHeader]()
    if len(data) == 0:
        return out^
    var dec = KafkaDecoder(Span(data))
    var count = Int(dec.get_unsigned_varint())
    for _ in range(count):
        var name_len = Int(dec.get_unsigned_varint())
        var name = List[UInt8]()
        for _ in range(name_len):
            name.append(dec.get_int8().cast[DType.uint8]())
        var vlen_raw = Int(dec.get_unsigned_varint())
        var value: Optional[List[UInt8]]
        if vlen_raw == 0:
            value = Optional[List[UInt8]]()
        else:
            var vb = List[UInt8]()
            for _ in range(vlen_raw - 1):
                vb.append(dec.get_int8().cast[DType.uint8]())
            value = Optional(vb^)
        out.append(KafkaHeader(name^, value^))
    return out^


# -----------------------------------------------------------------------------
# Build a nullable BINARY column from a list of optional byte strings.
# -----------------------------------------------------------------------------


def _check_int32_offset(data_len: Int) raises:
    """The offsets of a BINARY column are Int32: a data buffer past 2 GiB would
    wrap them. Split out so a test can reach the limit without building 2 GiB."""
    if data_len > Int(Int32.MAX):
        raise Error(
            "envelope_bridge: a binary column larger than 2 GiB does not"
            " fit Int32 offsets"
        )


def _build_binary_column(values: List[Optional[List[UInt8]]]) raises -> Column[HeapRegion]:
    """Build a nullable BINARY Column. Null entries get a 0-length slice + a
    cleared validity bit; non-null entries are appended to the data buffer with
    a set validity bit. If every entry is non-null the validity bitmap is
    omitted (the fast no-null path)."""
    var n = len(values)
    var offsets = List[Int32]()
    offsets.append(Int32(0))
    var data = List[UInt8]()
    var any_null = False
    for i in range(n):
        if values[i]:
            ref b = values[i].value()
            for j in range(len(b)):
                data.append(b[j])
        else:
            any_null = True
        _check_int32_offset(len(data))
        offsets.append(Int32(len(data)))

    if not any_null:
        var arr = BinaryArray.from_buffers(
            offsets, data, Optional[Bitmap[HeapRegion]](), 0
        )
        return Column.from_binary(arr^)

    var validity = Bitmap.create(n)
    var null_count = 0
    for i in range(n):
        if values[i]:
            validity.set(i)
        else:
            null_count += 1
    var arr = BinaryArray.from_buffers(
        offsets, data, Optional(validity^), null_count
    )
    return Column.from_binary(arr^)


# =============================================================================
# §1 — Kafka records -> envelope RecordBatch (the PRODUCE direction).
# =============================================================================


def kafka_records_to_envelope(
    records: List[KafkaRecord],
) raises -> RecordBatch:
    """Build an envelope RecordBatch (the fixed 5-column schema) from decoded
    Kafka records. Key/value/headers are carried as opaque bytes (Kafka is
    schemaless). Used by the Produce handler before `BrokerCore.produce`."""
    var n = len(records)

    var keys = List[Optional[List[UInt8]]]()
    var values = List[Optional[List[UInt8]]]()
    var timestamps = List[Scalar[DType.int64]]()
    var offsets = List[Scalar[DType.int64]]()
    var headers_col = List[Optional[List[UInt8]]]()

    for i in range(n):
        ref r = records[i]
        keys.append(r.key.copy())
        values.append(r.value.copy())
        timestamps.append(Scalar[DType.int64](r.timestamp))
        offsets.append(Scalar[DType.int64](r.offset))
        # A record without headers is still a block: the count 0.
        headers_col.append(Optional(_serialize_headers(r.headers)))

    var key_col = _build_binary_column(keys)
    var value_col = _build_binary_column(values)
    var ts_col = Column.from_primitive(PrimitiveArray[DType.int64].from_list(timestamps))
    var off_col = Column.from_primitive(PrimitiveArray[DType.int64].from_list(offsets))
    var hdr_col = _build_binary_column(headers_col)

    var builder = RecordBatchBuilder()
    builder.add_column(key_col^)
    builder.add_column(value_col^)
    builder.add_column(ts_col^)
    builder.add_column(off_col^)
    builder.add_column(hdr_col^)
    return builder.build(envelope_schema())


# =============================================================================
# §2 — envelope RecordBatch -> Kafka records (the FETCH direction).
# =============================================================================


def envelope_to_kafka_records(
    batch: RecordBatch, base_offset: Int64
) raises -> List[KafkaRecord]:
    """Decode an envelope RecordBatch back into Kafka records. `base_offset` is
    the broker-authoritative first offset of this batch — records are numbered
    `base_offset, base_offset+1, ...` (the envelope's own __offset column is the
    producer's pre-commit value; the manifest-assigned offset is authoritative,
    so the Fetch path renumbers here)."""
    var n = batch.num_rows()
    var key_arr = batch.column_at(0).as_binary()
    var value_arr = batch.column_at(1).as_binary()
    var ts_arr = batch.column_as_primitive_int64(2)
    var hdr_arr = batch.column_at(4).as_binary()

    var out = List[KafkaRecord]()
    for i in range(n):
        var key: Optional[List[UInt8]]
        if key_arr.is_null(i):
            key = Optional[List[UInt8]]()
        else:
            key = Optional(key_arr.get(i))
        var value: Optional[List[UInt8]]
        if value_arr.is_null(i):
            value = Optional[List[UInt8]]()
        else:
            value = Optional(value_arr.get(i))
        var headers: List[KafkaHeader]
        if hdr_arr.is_null(i):
            headers = List[KafkaHeader]()
        else:
            headers = _deserialize_headers(hdr_arr.get(i))
        out.append(
            KafkaRecord(
                key^,
                value^,
                headers^,
                Int64(ts_arr.get(i)),
                base_offset + Int64(i),
            )
        )
    return out^
