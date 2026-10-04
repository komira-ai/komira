# =============================================================================
# src/komira_kafka_server/wire/record_batch_v2.mojo — Kafka message-set "RecordBatch v2"
# =============================================================================
#
# The Kafka v2 RecordBatch (message format magic=2,
# KIP-98 / the format Kafka has used since 0.11). This is the on-wire container
# the Produce request carries and the Fetch response returns. Pure bytes (no
# first-party deps) — a wire edge like the rest of `komira_kafka_server.wire`.
#
# -----------------------------------------------------------------------------
# WIRE LAYOUT (one RecordBatch). All multi-byte header fields are BIG-ENDIAN.
# -----------------------------------------------------------------------------
#
#   baseOffset            INT64      (we emit 0; Fetch sets the real base)
#   batchLength           INT32      (bytes AFTER this field to end of batch)
#   partitionLeaderEpoch  INT32      (-1 when unknown)
#   magic                 INT8       (== 2)
#   crc                   UINT32     (CRC-32C over the bytes AFTER this field —
#                                     i.e. from `attributes` to end of batch)
#   attributes            INT16      (bit0-2 compression; 0 == none)
#   lastOffsetDelta       INT32      (== recordCount - 1)
#   firstTimestamp        INT64
#   maxTimestamp          INT64
#   producerId            INT64      (-1 == no idempotence)
#   producerEpoch         INT16      (-1)
#   baseSequence          INT32      (-1)
#   recordsCount          INT32
#   records               Record*    (recordsCount of them, see below)
#
# Each Record (varint/zigzag deltas — KIP-98):
#   length          VARINT (zigzag)  — byte length of the rest of THIS record
#   attributes      INT8             — currently unused, 0
#   timestampDelta  VARLONG (zigzag) — record ts - firstTimestamp
#   offsetDelta     VARINT (zigzag)  — record offset - baseOffset
#   keyLength       VARINT (zigzag)  — -1 == null key
#   key             bytes[keyLength]
#   valueLength     VARINT (zigzag)  — -1 == null value
#   value           bytes[valueLength]
#   headersCount    VARINT (zigzag)
#   headers         Header*          (each: keyLen VARINT + key bytes +
#                                     valueLen VARINT(-1=null) + value bytes)
#
# -----------------------------------------------------------------------------
# Compression: the batch `attributes` bits 0-2
# carry the producer compression codec (gzip=1 / snappy=2 / lz4=3 / zstd=4).
# When non-zero, the Record* array (everything after `recordsCount`) is one
# compressed blob; the header through `recordsCount` stays plaintext. This
# module STAYS a pure zero-dep wire edge, so it does NOT decompress — it
# exposes the codec id + the raw records span (`split_record_batch_header`) so
# the SERVER layer can decompress with a page codec and then call
# `parse_records_from_span` over the plaintext. `decode_record_batch_v2`
# (the all-in-one decoder) still rejects compression != none with a clear
# error, because it cannot decompress here. Control batches (attributes bit5)
# are rejected on decode.
#
# -----------------------------------------------------------------------------
# Validation: every decode entry point refuses what a Kafka broker refuses as a
# corrupt batch: a `batchLength` below the header or beyond the buffer, a magic
# other than 2, a CRC-32C mismatch over `attributes` to batch end, a negative
# `recordsCount`, a record whose fields do not span exactly its declared length,
# a null header key, bytes left after the declared records, and a message set
# that ends in a fragment. The fields after `crc` are parsed from the checked
# bytes. `baseOffset` and `partitionLeaderEpoch` sit outside the CRC by design.
#
# Encapsulation: ZERO UnsafePointer in any signature. Encode appends to an owned
# `List[UInt8]`; decode borrows a `Span[UInt8, origin]` via the wire decoder.
# =============================================================================

from komira_kafka_server.wire.crc32c import crc32c_span
from komira_kafka_server.wire.wire import KafkaDecoder, KafkaEncoder


comptime RECORD_BATCH_MAGIC_V2: Int8 = 2
# attributes bits 0-2 = compression codec.
comptime COMPRESSION_MASK: Int16 = 0x07
# attributes bit 4 = transactional batch (a batch written inside a Kafka
# transaction; the broker tags its chunk txn-open).
comptime TRANSACTIONAL_BIT: Int16 = 0x10
# attributes bit 5 = control batch.
comptime CONTROL_BATCH_BIT: Int16 = 0x20


# =============================================================================
# §1 — zigzag varint / varlong (KIP-98 record-level deltas).
# =============================================================================
#
# Kafka records use Protobuf-style zigzag-encoded signed varints: map a signed
# n to an unsigned u via `(n << 1) ^ (n >> 31)` (varint, 32-bit) or
# `(n << 1) ^ (n >> 63)` (varlong, 64-bit), then emit 7-bit LE groups with the
# MSB continuation bit. These are DISTINCT from the unsigned varint in wire.mojo
# (which the request/response flexible headers use).


def put_varint(mut out: List[UInt8], value: Int32):
    """Encode a zigzag-signed 32-bit varint."""
    var u = (UInt32(value.cast[DType.uint32]()) << 1) ^ UInt32(
        (value >> 31).cast[DType.uint32]()
    )
    while True:
        var low = UInt8(u & UInt32(0x7F))
        u = u >> UInt32(7)
        if u != UInt32(0):
            out.append(low | UInt8(0x80))
        else:
            out.append(low)
            break


def put_varlong(mut out: List[UInt8], value: Int64):
    """Encode a zigzag-signed 64-bit varlong."""
    var u = (UInt64(value.cast[DType.uint64]()) << 1) ^ UInt64(
        (value >> 63).cast[DType.uint64]()
    )
    while True:
        var low = UInt8(u & UInt64(0x7F))
        u = u >> UInt64(7)
        if u != UInt64(0):
            out.append(low | UInt8(0x80))
        else:
            out.append(low)
            break


def get_varint[origin: Origin[mut=False]](mut dec: KafkaDecoder[origin]) raises -> Int32:
    """Decode a zigzag-signed 32-bit varint off the wire decoder."""
    var u = UInt32(0)
    var shift = UInt32(0)
    var count = 0
    while True:
        var b = dec.get_int8().cast[DType.uint8]()
        count += 1
        u = u | (UInt32(b & 0x7F) << shift)
        if (b & 0x80) == 0:
            break
        shift += 7
        if count >= 5:
            raise Error("komira_kafka_server.wire.record_v2: varint exceeds 5 bytes")
    # zigzag decode: (u >> 1) ^ -(u & 1)
    var decoded = (u >> 1) ^ (UInt32(0) - (u & UInt32(1)))
    return decoded.cast[DType.int32]()


def get_varlong[origin: Origin[mut=False]](mut dec: KafkaDecoder[origin]) raises -> Int64:
    """Decode a zigzag-signed 64-bit varlong off the wire decoder."""
    var u = UInt64(0)
    var shift = UInt64(0)
    var count = 0
    while True:
        var b = dec.get_int8().cast[DType.uint8]()
        count += 1
        u = u | (UInt64(b & 0x7F) << shift)
        if (b & 0x80) == 0:
            break
        shift += 7
        if count >= 10:
            raise Error("komira_kafka_server.wire.record_v2: varlong exceeds 10 bytes")
    var decoded = (u >> 1) ^ (UInt64(0) - (u & UInt64(1)))
    return decoded.cast[DType.int64]()


# =============================================================================
# §2 — KafkaRecord — one decoded record (key/value/headers/ts/offset).
# =============================================================================


struct KafkaHeader(Copyable, Movable, Deinitable):
    """One record header: a name (UTF-8 bytes) + a value (nullable bytes).

    Copyable (the fields — List[UInt8] / Optional[List[UInt8]] — are copyable)
    so headers can live in a `List[KafkaHeader]` (Mojo 1.0.0b1 List requires
    Copyable). These are transient codec DTOs, NOT byte-slab elements, so no
    pointer can go stale across destroy and recreate."""

    var key: List[UInt8]
    var value: Optional[List[UInt8]]

    def __init__(out self, var key: List[UInt8], var value: Optional[List[UInt8]]):
        self.key = key^
        self.value = value^

    def copy(self) -> Self:
        return Self(self.key.copy(), self.value.copy())


struct KafkaRecord(Copyable, Movable, Deinitable):
    """One Kafka record. Key/value are nullable opaque bytes (Kafka is
    schemaless). `timestamp` + `offset` are absolute (deltas resolved against
    the batch's firstTimestamp / baseOffset on decode).

    Copyable so records can live in a `List[KafkaRecord]` (transient codec DTO,
    not a byte-slab element — no pointer field)."""

    var key: Optional[List[UInt8]]
    var value: Optional[List[UInt8]]
    var headers: List[KafkaHeader]
    var timestamp: Int64
    var offset: Int64

    def __init__(
        out self,
        var key: Optional[List[UInt8]],
        var value: Optional[List[UInt8]],
        var headers: List[KafkaHeader],
        timestamp: Int64,
        offset: Int64,
    ):
        self.key = key^
        self.value = value^
        self.headers = headers^
        self.timestamp = timestamp
        self.offset = offset

    def copy(self) -> Self:
        return Self(
            self.key.copy(),
            self.value.copy(),
            self.headers.copy(),
            self.timestamp,
            self.offset,
        )


# =============================================================================
# §3 — encode — build a v2 RecordBatch from a list of records.
# =============================================================================


def _put_int16_be(mut out: List[UInt8], v: Int16):
    var u = v.cast[DType.uint16]()
    out.append(UInt8((u >> 8) & 0xFF))
    out.append(UInt8(u & 0xFF))


def _put_int32_be(mut out: List[UInt8], v: Int32):
    var u = v.cast[DType.uint32]()
    out.append(UInt8((u >> 24) & 0xFF))
    out.append(UInt8((u >> 16) & 0xFF))
    out.append(UInt8((u >> 8) & 0xFF))
    out.append(UInt8(u & 0xFF))


def _put_uint32_be(mut out: List[UInt8], u: UInt32):
    out.append(UInt8((u >> 24) & 0xFF))
    out.append(UInt8((u >> 16) & 0xFF))
    out.append(UInt8((u >> 8) & 0xFF))
    out.append(UInt8(u & 0xFF))


def _put_int64_be(mut out: List[UInt8], v: Int64):
    var u = v.cast[DType.uint64]()
    for shift in range(7, -1, -1):
        out.append(UInt8((u >> UInt64(shift * 8)) & UInt64(0xFF)))


def _encode_one_record(
    mut out: List[UInt8],
    rec: KafkaRecord,
    first_timestamp: Int64,
    offset_delta: Int,
):
    """Encode one record's body (everything AFTER the record's own length
    varint) into a temporary buffer, then frame it with its zigzag length.

    `offset_delta` is the record's index within the batch (0-based) — the v2
    format stores per-record offsetDeltas relative to the batch baseOffset, so
    the records are renumbered base_offset..base_offset+N-1 by position (NOT by
    whatever absolute offset the source KafkaRecord carried)."""
    var body = List[UInt8]()
    body.append(UInt8(0))  # record attributes (unused)
    put_varlong(body, rec.timestamp - first_timestamp)  # timestampDelta
    put_varint(body, Int32(offset_delta))  # offsetDelta

    # key (varint length, -1 == null)
    if rec.key:
        ref k = rec.key.value()
        put_varint(body, Int32(len(k)))
        for i in range(len(k)):
            body.append(k[i])
    else:
        put_varint(body, Int32(-1))

    # value (varint length, -1 == null)
    if rec.value:
        ref v = rec.value.value()
        put_varint(body, Int32(len(v)))
        for i in range(len(v)):
            body.append(v[i])
    else:
        put_varint(body, Int32(-1))

    # headers
    put_varint(body, Int32(len(rec.headers)))
    for hi in range(len(rec.headers)):
        ref h = rec.headers[hi]
        put_varint(body, Int32(len(h.key)))
        for i in range(len(h.key)):
            body.append(h.key[i])
        if h.value:
            ref hv = h.value.value()
            put_varint(body, Int32(len(hv)))
            for i in range(len(hv)):
                body.append(hv[i])
        else:
            put_varint(body, Int32(-1))

    # Frame with the record length (zigzag varint of the body length).
    put_varint(out, Int32(len(body)))
    for i in range(len(body)):
        out.append(body[i])


def encode_record_batch_v2(
    records: List[KafkaRecord], base_offset: Int64
) raises -> List[UInt8]:
    """Encode a list of records as ONE v2 RecordBatch (compression=none).

    The records' offsets are renumbered `base_offset .. base_offset+N-1` in the
    order given (the Fetch path passes the committed base offset; the Produce
    path decodes with whatever the client sent). `firstTimestamp` is taken from
    record 0; `maxTimestamp` is the max over all records.

    Raises if `records` is empty (a batch always has >= 1 record)."""
    var n = len(records)
    if n == 0:
        raise Error("encode_record_batch_v2: empty record list")

    var first_ts = records[0].timestamp
    var max_ts = records[0].timestamp
    for i in range(1, n):
        if records[i].timestamp > max_ts:
            max_ts = records[i].timestamp

    # Build the records section + the post-CRC header section ("attributes"
    # onward) into one buffer, so the CRC covers exactly the right bytes.
    var post_crc = List[UInt8]()
    _put_int16_be(post_crc, Int16(0))  # attributes (compression none, no control)
    _put_int32_be(post_crc, Int32(n - 1))  # lastOffsetDelta
    _put_int64_be(post_crc, first_ts)  # firstTimestamp
    _put_int64_be(post_crc, max_ts)  # maxTimestamp
    _put_int64_be(post_crc, Int64(-1))  # producerId
    _put_int16_be(post_crc, Int16(-1))  # producerEpoch
    _put_int32_be(post_crc, Int32(-1))  # baseSequence
    _put_int32_be(post_crc, Int32(n))  # recordsCount
    for i in range(n):
        _encode_one_record(post_crc, records[i], first_ts, i)

    var crc = crc32c_span(Span(post_crc))

    # Now the leading header (baseOffset .. crc) + the post-CRC section.
    # batchLength counts everything AFTER the batchLength field itself:
    #   partitionLeaderEpoch(4) + magic(1) + crc(4) + len(post_crc).
    var batch_length = 4 + 1 + 4 + len(post_crc)

    var out = List[UInt8]()
    _put_int64_be(out, base_offset)  # baseOffset
    _put_int32_be(out, Int32(batch_length))  # batchLength
    _put_int32_be(out, Int32(-1))  # partitionLeaderEpoch
    out.append(UInt8(RECORD_BATCH_MAGIC_V2.cast[DType.uint8]()))  # magic
    _put_uint32_be(out, crc)  # crc
    for i in range(len(post_crc)):
        out.append(post_crc[i])
    return out^


# =============================================================================
# §3b — encode (COMPRESSED) — build a v2 RecordBatch from a PRE-COMPRESSED
#        records blob + the per-batch metadata.
# =============================================================================
#
# The FETCH path (server) optionally compresses the Record* array. Because
# this subpackage stays a pure zero-dep wire edge, it does NOT run a codec: the
# SERVER compresses the plaintext records blob (with the correct Kafka framing
# per codec) and hands the COMPRESSED blob + the codec id + the batch metadata
# here. We build the header with the compression bits set in `attributes`, set
# `recordsCount` to the *logical* (uncompressed) record count, and emit the
# compressed blob as the batch body. The CRC-32C is computed over the actual
# on-wire post-`attributes` bytes (i.e. the compressed blob), exactly as a
# real broker emits — so any Kafka client validates + decompresses it.


def encode_record_batch_v2_compressed(
    compressed_records: Span[UInt8, _],
    records_count: Int,
    first_timestamp: Int64,
    max_timestamp: Int64,
    base_offset: Int64,
    last_offset_delta: Int32,
    compression_codec: Int,
) raises -> List[UInt8]:
    """Encode ONE v2 RecordBatch whose Record* array is ALREADY COMPRESSED.

    `compressed_records` is the codec-compressed (and correctly Kafka-framed)
    bytes of the entire Record* array. `compression_codec` is the attributes
    codec id (1=gzip / 2=snappy / 3=lz4 / 4=zstd); 0=none should use the plain
    `encode_record_batch_v2` instead. `records_count` is the LOGICAL
    (uncompressed) record count — clients use it to know how many records the
    decompressed blob yields. `last_offset_delta` is `records_count - 1`.

    The CRC-32C covers the bytes from `attributes` to the batch end, which now
    INCLUDES the compressed blob (matching a real broker)."""
    if records_count <= 0:
        raise Error("encode_record_batch_v2_compressed: empty record list")
    if compression_codec <= 0 or compression_codec > 4:
        raise Error(
            "encode_record_batch_v2_compressed: invalid compression codec "
            + String(compression_codec)
            + " (expected 1=gzip/2=snappy/3=lz4/4=zstd)"
        )

    # attributes: bits 0-2 = codec. timestampType / control / txn bits = 0.
    var attributes = Int16(compression_codec & 0x07)

    var post_crc = List[UInt8]()
    _put_int16_be(post_crc, attributes)  # attributes (compression set)
    _put_int32_be(post_crc, last_offset_delta)  # lastOffsetDelta
    _put_int64_be(post_crc, first_timestamp)  # firstTimestamp
    _put_int64_be(post_crc, max_timestamp)  # maxTimestamp
    _put_int64_be(post_crc, Int64(-1))  # producerId
    _put_int16_be(post_crc, Int16(-1))  # producerEpoch
    _put_int32_be(post_crc, Int32(-1))  # baseSequence
    _put_int32_be(post_crc, Int32(records_count))  # recordsCount
    # The compressed Record* array IS the batch body.
    for i in range(len(compressed_records)):
        post_crc.append(compressed_records[i])

    var crc = crc32c_span(Span(post_crc))

    var batch_length = 4 + 1 + 4 + len(post_crc)
    var out = List[UInt8]()
    _put_int64_be(out, base_offset)  # baseOffset
    _put_int32_be(out, Int32(batch_length))  # batchLength
    _put_int32_be(out, Int32(-1))  # partitionLeaderEpoch
    out.append(UInt8(RECORD_BATCH_MAGIC_V2.cast[DType.uint8]()))  # magic
    _put_uint32_be(out, crc)  # crc
    for i in range(len(post_crc)):
        out.append(post_crc[i])
    return out^


def encode_record_array_plaintext(
    records: List[KafkaRecord], base_offset: Int64
) raises -> List[UInt8]:
    """Encode JUST the Record* array (the bytes after `recordsCount`) as
    plaintext, renumbering offsets `base_offset .. base_offset+N-1` by position.

    Returns the array bytes (the SERVER compresses these for a compressed Fetch
    batch). Distinct from `encode_record_batch_v2`, which wraps the array in the
    full batch header. Raises on an empty list."""
    var n = len(records)
    if n == 0:
        raise Error("encode_record_array_plaintext: empty record list")
    var first_ts = records[0].timestamp
    var out = List[UInt8]()
    for i in range(n):
        _encode_one_record(out, records[i], first_ts, i)
    return out^


def record_batch_first_timestamp(records: List[KafkaRecord]) -> Int64:
    """The firstTimestamp (record 0's timestamp) for a batch."""
    return records[0].timestamp if len(records) > 0 else Int64(0)


def record_batch_max_timestamp(records: List[KafkaRecord]) -> Int64:
    """The maxTimestamp over a batch's records."""
    if len(records) == 0:
        return Int64(0)
    var m = records[0].timestamp
    for i in range(1, len(records)):
        if records[i].timestamp > m:
            m = records[i].timestamp
    return m


# =============================================================================
# §4 — decode — parse a v2 RecordBatch off a borrowed span.
# =============================================================================


struct DecodedRecordBatch(Movable, Deinitable):
    """The result of decoding ONE v2 RecordBatch: its records + the batch's
    base offset (records carry their resolved absolute offset / timestamp)."""

    var base_offset: Int64
    var records: List[KafkaRecord]

    def __init__(out self, base_offset: Int64, var records: List[KafkaRecord]):
        self.base_offset = base_offset
        self.records = records^


def _read_nullable_bytes[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> Optional[List[UInt8]]:
    """Read a varint-length-prefixed byte string (length -1 == null)."""
    var n = Int(get_varint(dec))
    if n < 0:
        return Optional[List[UInt8]]()
    var out = List[UInt8]()
    for _ in range(n):
        out.append(dec.get_int8().cast[DType.uint8]())
    return Optional(out^)


def _read_bytes[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin], n: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(dec.get_int8().cast[DType.uint8]())
    return out^


struct BatchHeader(Movable, Deinitable):
    """The decoded header of ONE v2 RecordBatch + the position/length of its
    (possibly-compressed) records blob within the original buffer.

    The server uses this to detect compression and locate the records bytes
    WITHOUT this zero-dep module having to decompress: it reads the codec id,
    slices `[records_pos : records_pos + records_len]`, decompresses (if
    compressed) with a page codec, and calls `parse_records_from_span`
    over the plaintext."""

    var base_offset: Int64
    var first_timestamp: Int64
    var compression_codec: Int  # attributes bits 0-2 (0=none)
    var is_control: Bool
    var records_count: Int
    # Byte offsets into the ORIGINAL buffer the decoder was constructed over:
    var records_pos: Int  # start of the Record* array (after recordsCount)
    var records_len: Int  # bytes of the Record* array (to the batch end)
    # Idempotence — the per-batch producer-sequence identity (KIP-98). The
    # producer sets these when enable.idempotence=true; they are -1 / -1 / -1
    # for a non-idempotent producer. The server uses (producer_id,
    # producer_epoch, base_sequence) to dedupe + fence retries.
    var producer_id: Int64  # -1 == no idempotence
    var producer_epoch: Int16  # -1 == no idempotence
    var base_sequence: Int32  # -1 == no idempotence
    # Transactions — attributes bit 4 (a batch written inside a Kafka
    # transaction). The broker tags such a batch's chunk txn-open.
    var is_transactional: Bool

    def __init__(
        out self,
        base_offset: Int64,
        first_timestamp: Int64,
        compression_codec: Int,
        is_control: Bool,
        records_count: Int,
        records_pos: Int,
        records_len: Int,
        producer_id: Int64,
        producer_epoch: Int16,
        base_sequence: Int32,
        is_transactional: Bool = False,
    ):
        self.base_offset = base_offset
        self.first_timestamp = first_timestamp
        self.compression_codec = compression_codec
        self.is_control = is_control
        self.records_count = records_count
        self.records_pos = records_pos
        self.records_len = records_len
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.base_sequence = base_sequence
        self.is_transactional = is_transactional


comptime _V2_HEADER_AFTER_LENGTH: Int = 49
"""Bytes of the fixed v2 header that FOLLOW `batchLength`: partitionLeaderEpoch
(4) + magic (1) + crc (4) + the 40 CRC-covered bytes from `attributes` through
`recordsCount`. A smaller `batchLength` cannot hold a header."""

comptime _V2_POST_CRC_HEADER: Int = 40
"""Bytes from `attributes` through `recordsCount`: the CRC-covered header."""


def _read_verified_batch[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin], who: String, mut post_crc: List[UInt8]
) raises -> BatchHeader:
    """Read ONE v2 batch's header off `dec`, check its length and CRC-32C, and
    advance `dec` past the whole batch. `post_crc` receives an owned copy of the
    CRC-covered bytes (`attributes` to batch end); every field after `crc` is
    read from that checked copy, so nothing parsed was skipped by the check.

    Refuses (raises, naming `who`) a `batchLength` below the fixed header or
    beyond the buffer, a magic other than 2, a CRC mismatch and a negative
    `recordsCount`. `baseOffset` and `partitionLeaderEpoch` are outside the CRC
    by the format's design (a broker rewrites them), so they are not checked."""
    var base_offset = dec.get_int64()
    var batch_length = Int(dec.get_int32())
    if batch_length < _V2_HEADER_AFTER_LENGTH:
        raise Error(
            who
            + ": batchLength "
            + String(batch_length)
            + " is below the "
            + String(_V2_HEADER_AFTER_LENGTH)
            + "-byte v2 header that follows it (corrupt batch)"
        )
    if batch_length > dec.remaining():
        raise Error(
            who
            + ": truncated batch: batchLength "
            + String(batch_length)
            + " but only "
            + String(dec.remaining())
            + " bytes remain"
        )
    _ = dec.get_int32()  # partitionLeaderEpoch (outside the CRC; ignored)
    var magic = dec.get_int8()
    if magic != RECORD_BATCH_MAGIC_V2:
        raise Error(
            who
            + ": unsupported magic "
            + String(Int(magic))
            + " (only v2/magic=2 is supported)"
        )
    var crc = dec.get_int32().cast[DType.uint32]()
    var attr_pos = dec.pos()
    post_crc = dec._read_raw(batch_length - 9)
    var actual = crc32c_span(Span(post_crc))
    if actual != crc:
        raise Error(
            who
            + ": CRC-32C mismatch (the batch says "
            + String(Int(crc))
            + ", its bytes give "
            + String(Int(actual))
            + "): corrupt batch"
        )
    var hd = KafkaDecoder(Span(post_crc))
    var attributes = hd.get_int16()
    _ = hd.get_int32()  # lastOffsetDelta
    var first_ts = hd.get_int64()  # firstTimestamp
    _ = hd.get_int64()  # maxTimestamp
    var producer_id = hd.get_int64()  # producerId (surfaced for dedupe)
    var producer_epoch = hd.get_int16()  # producerEpoch
    var base_sequence = hd.get_int32()  # baseSequence
    var records_count = Int(hd.get_int32())
    if records_count < 0:
        raise Error(
            who + ": negative recordsCount " + String(records_count) + " (corrupt batch)"
        )
    return BatchHeader(
        base_offset,
        first_ts,
        Int(attributes & COMPRESSION_MASK),
        (attributes & CONTROL_BATCH_BIT) != Int16(0),
        records_count,
        attr_pos + _V2_POST_CRC_HEADER,
        len(post_crc) - _V2_POST_CRC_HEADER,
        producer_id,
        producer_epoch,
        base_sequence,
        (attributes & TRANSACTIONAL_BIT) != Int16(0),
    )


def split_record_batch_header[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> BatchHeader:
    """Decode the header of ONE v2 RecordBatch off `dec` and advance the cursor
    PAST the whole batch (header + records blob), returning the codec id and
    the byte span of the records blob.

    Does NOT parse the records (they may be compressed), but DOES check the
    batch's length and CRC-32C (see `_read_verified_batch`), so a corrupt or
    truncated batch is refused here rather than decompressed or stored. Rejects
    control batches (attributes bit5). The compression codec id is returned
    as-is for the caller to handle (0=none / 1=gzip / 2=snappy / 3=lz4 /
    4=zstd)."""
    var post_crc = List[UInt8]()
    var header = _read_verified_batch(
        dec, String("split_record_batch_header"), post_crc
    )
    if header.is_control:
        raise Error("split_record_batch_header: control batches not supported")
    return header^


def _parse_records[
    origin: Origin[mut=False]
](
    mut dec: KafkaDecoder[origin],
    records_count: Int,
    base_offset: Int64,
    first_timestamp: Int64,
    who: String,
) raises -> List[KafkaRecord]:
    """Parse exactly `records_count` v2 records off `dec`, which must then be
    exhausted. Refuses (raises, naming `who`) what a Kafka broker refuses as a
    corrupt record: a negative count or record length, a record whose fields do
    not span EXACTLY its declared length, a null header key, and bytes left over
    after the declared records."""
    if records_count < 0:
        raise Error(who + ": negative recordsCount " + String(records_count))
    var records = List[KafkaRecord]()
    for r in range(records_count):
        var rec_len = Int(get_varint(dec))  # length of the rest of this record
        if rec_len < 0:
            raise Error(
                who + ": record " + String(r) + " has negative length " + String(rec_len)
            )
        if rec_len > dec.remaining():
            raise Error(
                who
                + ": record "
                + String(r)
                + " length "
                + String(rec_len)
                + " exceeds the "
                + String(dec.remaining())
                + " bytes left"
            )
        var rec_start = dec.pos()
        _ = dec.get_int8()  # record attributes (unused)
        var ts_delta = get_varlong(dec)
        var off_delta = get_varint(dec)
        var key = _read_nullable_bytes(dec)
        var value = _read_nullable_bytes(dec)
        var headers_count = Int(get_varint(dec))
        var headers = List[KafkaHeader]()
        for _ in range(headers_count):
            var hk_len = Int(get_varint(dec))
            if hk_len < 0:
                raise Error(
                    who
                    + ": record "
                    + String(r)
                    + " has a header with a null key (a header key is required)"
                )
            var hk = _read_bytes(dec, hk_len)
            var hv = _read_nullable_bytes(dec)
            headers.append(KafkaHeader(hk^, hv^))
        var consumed = dec.pos() - rec_start
        if consumed != rec_len:
            raise Error(
                who
                + ": record "
                + String(r)
                + " declares "
                + String(rec_len)
                + " bytes but its fields span "
                + String(consumed)
            )
        records.append(
            KafkaRecord(
                key^,
                value^,
                headers^,
                first_timestamp + ts_delta,
                base_offset + Int64(off_delta),
            )
        )
    if dec.remaining() != 0:
        raise Error(
            who
            + ": "
            + String(dec.remaining())
            + " bytes follow the "
            + String(records_count)
            + " declared records (recordsCount disagrees with the batch)"
        )
    return records^


def parse_records_from_span[
    origin: Origin[mut=False]
](
    data: Span[UInt8, origin],
    records_count: Int,
    base_offset: Int64,
    first_timestamp: Int64,
) raises -> List[KafkaRecord]:
    """Parse `records_count` v2 records out of a PLAINTEXT records span (the
    Record* array, already decompressed if the batch was compressed). The span
    must hold exactly those records; see `_parse_records` for what is refused.

    `base_offset` / `first_timestamp` come from the batch header and resolve
    the per-record offset/timestamp deltas to absolute values."""
    var dec = KafkaDecoder(data)
    return _parse_records(
        dec,
        records_count,
        base_offset,
        first_timestamp,
        String("parse_records_from_span"),
    )


def decode_record_batch_v2[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> DecodedRecordBatch:
    """Decode ONE UNCOMPRESSED v2 RecordBatch off `dec` (positioned at the
    batch's baseOffset). Advances the cursor past the whole batch.

    Checks the batch's length and CRC-32C and every record's framing (see
    `_read_verified_batch` and `_parse_records`): a truncated, corrupt or
    inconsistent batch raises and yields no records.

    Rejects compression != none with a clear error: this zero-dep module
    cannot decompress. The SERVER path handles compression via
    `split_record_batch_header` + decompress + `parse_records_from_span`.
    Control batches are likewise rejected.
    """
    var post_crc = List[UInt8]()
    var header = _read_verified_batch(
        dec, String("decode_record_batch_v2"), post_crc
    )
    if header.compression_codec != 0:
        raise Error(
            "decode_record_batch_v2: compression codec "
            + String(header.compression_codec)
            + " not supported by the zero-dep decoder; use"
            " split_record_batch_header + decompress + parse_records_from_span"
        )
    if header.is_control:
        raise Error("decode_record_batch_v2: control batches not supported")
    var rd = KafkaDecoder(Span(post_crc))
    _ = rd._read_raw(_V2_POST_CRC_HEADER)
    var records = _parse_records(
        rd,
        header.records_count,
        header.base_offset,
        header.first_timestamp,
        String("decode_record_batch_v2"),
    )
    return DecodedRecordBatch(header.base_offset, records^)


def decode_record_batches[
    origin: Origin[mut=False]
](data: Span[UInt8, origin]) raises -> List[KafkaRecord]:
    """Decode a Kafka message-set (one or more concatenated v2 RecordBatches)
    into a flat list of records. A Produce request's per-partition records field
    can carry multiple batches.

    Every byte must belong to a whole batch: a trailing partial batch is
    REFUSED (raises), whether it is a fragment too short to hold `baseOffset` +
    `batchLength` or a batch whose `batchLength` runs past the end, rather than
    being dropped, because a dropped fragment is a truncated request reported
    as a complete one.

    That refusal is correct for a PRODUCE request only. A FETCH response may
    legitimately end in a partial batch (the broker cuts the message set at
    `max_bytes`, and the client skips the tail), so a Fetch-side caller must
    not reuse this entry point as is: it would refuse a valid response."""
    var dec = KafkaDecoder(data)
    var out = List[KafkaRecord]()
    while dec.remaining() > 0:
        if dec.remaining() < 12:  # baseOffset(8) + batchLength(4)
            raise Error(
                "decode_record_batches: a "
                + String(dec.remaining())
                + "-byte fragment follows the last whole batch (truncated"
                " message set)"
            )
        var decoded = decode_record_batch_v2(dec)
        for i in range(len(decoded.records)):
            out.append(decoded.records[i].copy())
        _ = decoded^
    return out^
