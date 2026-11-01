# =============================================================================
# kafka_compression.mojo: decompression of a Kafka v2 RecordBatch records blob.
# =============================================================================
#
# A v2 RecordBatch carries its compression codec in bits 0-2 of the batch
# `attributes`: 0 none, 1 gzip, 2 snappy, 3 lz4, 4 zstd. When the codec is not
# `none`, everything after the batch header (the `recordsCount` records) is
# one compressed blob; the header through `recordsCount` stays plain. Stock
# clients compress by default, so a Produce path that accepts only `none`
# refuses the common case. This module decompresses the blob before the
# per-record parse, so `parse_records_from_span` always runs over plaintext.
#
# The codecs come from komira_compression. Kafka's framing differs from the
# one each codec uses elsewhere in some cases:
#
#   gzip (1)   standard gzip framing; inflated with zlib's gzip/zlib
#              auto-detect, one member after another (concatenated members
#              decode as one stream).
#   snappy (2) the xerial (java-snappy) framing: a 16-byte header (the magic
#              0x82 "SNAPPY" 0x00, then the version and compatible-version
#              int32s) followed by repeated `[int32 block-len][raw block]`.
#              Each raw block is decoded and the results concatenated. A bare
#              raw snappy block with no xerial magic is accepted too.
#   lz4 (3)    the LZ4 frame format (magic 0x184D2204); one or more frames.
#   zstd (4)   a standard zstd frame.
#
# Output sizing: a batch does not carry the uncompressed size where a decoder
# can trust it, so gzip, lz4 and zstd decode into a buffer that doubles each
# time the codec reports the destination too small, up to a fixed ceiling
# (`_MAX_OUT_CAP`), so a hostile blob cannot drive an unbounded allocation.
# Snappy declares each block's length in the block preamble; that declared
# length is checked against the ceiling before any allocation, and the
# concatenation of the blocks is checked against it too.
#
# Every public signature takes and returns bytes (`Span[UInt8]` in,
# `List[UInt8]` out).
# =============================================================================


from komira_compression.lz4 import lz4_frames_decompress_into
from komira_compression.snappy_block import (
    snappy_uncompress_into,
    snappy_uncompressed_length,
)
from komira_compression.zlib import (
    Z_BUF_ERROR,
    Z_OK,
    Z_STREAM_END,
    ZLIB_WINDOW_BITS_AUTO,
    zlib_inflate_once,
)
from komira_compression.zstd_frame import (
    ZSTD_ERROR_DST_SIZE_TOO_SMALL,
    zstd_decompress_once,
)

from komira_kafka_server.wire import KafkaDecoder
from komira_kafka_server.wire.record_batch_v2 import (
    KafkaRecord,
    BatchHeader,
    split_record_batch_header,
    parse_records_from_span,
)


# Kafka attributes compression-codec ids (bits 0-2 of the batch attributes).
comptime KAFKA_COMPRESSION_NONE: Int = 0
comptime KAFKA_COMPRESSION_GZIP: Int = 1
comptime KAFKA_COMPRESSION_SNAPPY: Int = 2
comptime KAFKA_COMPRESSION_LZ4: Int = 3
comptime KAFKA_COMPRESSION_ZSTD: Int = 4

# The xerial header: 8 magic bytes, then version and compatible-version int32s.
comptime _XERIAL_HEADER_LEN: Int = 16

# Output sizing for the grow-and-retry codecs: start at max(64 KiB, 4x input),
# double on "too small", stop at the ceiling.
comptime _MIN_OUT_CAP: Int = 65536
comptime _MAX_OUT_CAP: Int = 256 * 1024 * 1024


def _output_buffer(n: Int) -> List[UInt8]:
    return List[UInt8](length=n, fill=UInt8(0))


def _initial_cap(input_len: Int) -> Int:
    var cap = input_len * 4
    if cap < _MIN_OUT_CAP:
        cap = _MIN_OUT_CAP
    if cap > _MAX_OUT_CAP:
        cap = _MAX_OUT_CAP
    return cap


def _grow(
    cap: Int, label: String, ceiling: Int = _MAX_OUT_CAP
) raises -> Int:
    """The next output capacity after `cap` was too small, or a refusal once
    `cap` is already the ceiling."""
    if cap >= ceiling:
        raise Error(
            "kafka_compression("
            + label
            + "): decompressed output exceeded the "
            + String(_MAX_OUT_CAP)
            + "-byte ceiling (corrupt or hostile batch?)"
        )
    var next = cap * 2
    if next > ceiling:
        next = ceiling
    return next


def _read_int32_be(data: Span[UInt8, _], pos: Int) -> Int:
    """Read a big-endian int32 from `data` at `pos` (the caller bounds-checks)."""
    var b0 = UInt32(Int(data[pos]))
    var b1 = UInt32(Int(data[pos + 1]))
    var b2 = UInt32(Int(data[pos + 2]))
    var b3 = UInt32(Int(data[pos + 3]))
    return Int(((b0 << 24) | (b1 << 16) | (b2 << 8) | b3).cast[DType.int32]())


# =============================================================================
# gzip, lz4 and zstd: grow-and-retry decode.
# =============================================================================


def _inflate_member(
    src: Span[UInt8, _], ceiling: Int
) raises -> Tuple[List[UInt8], Int]:
    """Inflate the one gzip (or zlib) stream at the start of `src` into at most
    `ceiling` bytes. Returns the output and the number of input bytes the
    stream occupied."""
    var cap = _initial_cap(len(src))
    if cap > ceiling:
        cap = ceiling
    while True:
        var out = _output_buffer(cap)
        var res = zlib_inflate_once(Span(out), src, ZLIB_WINDOW_BITS_AUTO)
        if res.rc == Z_STREAM_END:
            out.resize(res.written, UInt8(0))
            return (out^, len(src) - res.unread)
        if res.rc != Z_OK and res.rc != Z_BUF_ERROR:
            raise Error(
                "kafka_compression(gzip): inflate failed with rc "
                + String(Int(res.rc))
            )
        if res.unwritten > 0:
            # libz stopped with output space left: it ran out of input, and a
            # larger buffer would not change that.
            raise Error(
                "kafka_compression(gzip): the stream ends before its final"
                " block does (truncated batch)"
            )
        cap = _grow(cap, "gzip", ceiling)


def _decompress_gzip(src: Span[UInt8, _]) raises -> List[UInt8]:
    """Inflate every member of a gzip blob (concatenated members decode as one
    stream, as GZIPInputStream reads them), within the output ceiling for the
    whole blob."""
    var result = List[UInt8]()
    var pos = 0
    while True:
        var member = _inflate_member(src[pos:], _MAX_OUT_CAP - len(result))
        result.extend(Span(member[0]))
        pos += member[1]
        if pos >= len(src):
            return result^


def _decompress_zstd(src: Span[UInt8, _]) raises -> List[UInt8]:
    # libzstd decodes zero frames from zero bytes without an error, but a
    # compressed blob is never empty (even an empty payload compresses to a
    # frame), so an empty one is a corrupt batch.
    if len(src) == 0:
        raise Error("kafka_compression(zstd): empty blob (corrupt batch)")
    var cap = _initial_cap(len(src))
    while True:
        var out = _output_buffer(cap)
        var res = zstd_decompress_once(Span(out), src)
        if res.error_code == 0:
            out.resize(res.written, UInt8(0))
            return out^
        if res.error_code != ZSTD_ERROR_DST_SIZE_TOO_SMALL:
            raise Error(
                "kafka_compression(zstd): libzstd error code "
                + String(res.error_code)
                + " (corrupt or truncated batch)"
            )
        cap = _grow(cap, "zstd")


def _decompress_lz4(src: Span[UInt8, _]) raises -> List[UInt8]:
    var cap = _initial_cap(len(src))
    while True:
        var out = _output_buffer(cap)
        try:
            var written = lz4_frames_decompress_into(Span(out), src)
            out.resize(written, UInt8(0))
            return out^
        except e:
            var msg = String(e)
            if msg.find("dst buffer too small") < 0:
                raise Error("kafka_compression(lz4): " + msg)
        cap = _grow(cap, "lz4")


# =============================================================================
# snappy: the xerial framing over raw snappy blocks.
# =============================================================================


def _has_xerial_magic(data: Span[UInt8, _]) -> Bool:
    if len(data) < _XERIAL_HEADER_LEN:
        return False
    if data[0] != UInt8(0x82):
        return False
    return (
        data[1] == UInt8(ord("S"))
        and data[2] == UInt8(ord("N"))
        and data[3] == UInt8(ord("A"))
        and data[4] == UInt8(ord("P"))
        and data[5] == UInt8(ord("P"))
        and data[6] == UInt8(ord("Y"))
        and data[7] == UInt8(0)
    )


def _decompress_snappy_raw_block(block: Span[UInt8, _]) raises -> List[UInt8]:
    """Decode one raw snappy block, sized exactly by its preamble."""
    var input_len = len(block)
    # An empty raw block decodes to nothing (zstd, by contrast, refuses an
    # empty blob). A batch that claims records over an empty result is refused
    # later, by the record parser.
    if input_len == 0:
        return List[UInt8]()
    var out_len = snappy_uncompressed_length(block)
    # UNTRUSTED INPUT: `out_len` is the block's preamble varint, bytes from a
    # Produce request. It can declare up to 2^32-1, so a block of a few bytes
    # would commit the broker to a multi-GiB allocation. It is checked here,
    # where it is parsed and before anything is allocated.
    if out_len < 0 or out_len > _MAX_OUT_CAP:
        raise Error(
            "kafka_compression(snappy): block preamble declares an"
            " uncompressed length of "
            + String(out_len)
            + " bytes from a "
            + String(input_len)
            + "-byte compressed block, which exceeds the "
            + String(_MAX_OUT_CAP)
            + "-byte ceiling (corrupt or hostile batch?)"
        )
    var out = _output_buffer(out_len)
    var written = snappy_uncompress_into(Span(out), block)
    out.resize(written, UInt8(0))
    return out^


def _decompress_snappy(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decode a Kafka snappy records blob: the xerial framing, or a bare raw
    block when the xerial magic is absent."""
    if not _has_xerial_magic(data):
        return _decompress_snappy_raw_block(data)

    var out = List[UInt8]()
    var pos = _XERIAL_HEADER_LEN
    var n = len(data)
    while pos + 4 <= n:
        var block_len = _read_int32_be(data, pos)
        pos += 4
        if block_len < 0 or pos + block_len > n:
            raise Error(
                "kafka_compression(snappy): xerial block length "
                + String(block_len)
                + " runs past end of input (pos="
                + String(pos)
                + ", remaining="
                + String(n - pos)
                + ")"
            )
        var decoded = _decompress_snappy_raw_block(data[pos : pos + block_len])
        # The per-block check bounds one block; this bounds the concatenation,
        # which is what the sender controls (any number of blocks, each legal).
        if len(out) + len(decoded) > _MAX_OUT_CAP:
            raise Error(
                "kafka_compression(snappy): concatenated xerial blocks exceed"
                " the "
                + String(_MAX_OUT_CAP)
                + "-byte ceiling at "
                + String(len(out) + len(decoded))
                + " bytes (corrupt or hostile batch?)"
            )
        out.extend(Span(decoded))
        pos += block_len
    if pos != n:
        raise Error(
            "kafka_compression(snappy): "
            + String(n - pos)
            + " trailing bytes after the last xerial block"
        )
    return out^


# =============================================================================
# Decompress a records blob by codec id.
# =============================================================================


def decompress_kafka_records(
    codec_id: Int, data: Span[UInt8, _]
) raises -> List[UInt8]:
    """Decompress the records blob of a Kafka v2 RecordBatch.

    `codec_id` is attributes bits 0-2 (0 none, 1 gzip, 2 snappy, 3 lz4,
    4 zstd). For `none` the result is a copy of the input. Raises on an
    unsupported id, and on a blob its codec refuses."""
    if codec_id == KAFKA_COMPRESSION_NONE:
        return List[UInt8](Span(data))
    elif codec_id == KAFKA_COMPRESSION_GZIP:
        return _decompress_gzip(data)
    elif codec_id == KAFKA_COMPRESSION_SNAPPY:
        return _decompress_snappy(data)
    elif codec_id == KAFKA_COMPRESSION_LZ4:
        return _decompress_lz4(data)
    elif codec_id == KAFKA_COMPRESSION_ZSTD:
        return _decompress_zstd(data)
    else:
        raise Error(
            "kafka_compression: unsupported codec id "
            + String(codec_id)
            + " (expected 0=none/1=gzip/2=snappy/3=lz4/4=zstd)"
        )


# =============================================================================
# Compression-aware message-set decode (the Produce-path entry points).
# =============================================================================


struct DecodedProducerBatch(Copyable, Movable, Deinitable):
    """One decoded RecordBatch with its producer-sequence identity kept.

    `producer_id`, `producer_epoch` and `base_sequence` are -1 for a batch
    from a non-idempotent producer. `last_sequence` is
    `base_sequence + records - 1`, or -1 when non-idempotent. `records` are
    the decompressed, parsed records of this batch. `is_transactional` is
    attributes bit 4."""

    var producer_id: Int64
    var producer_epoch: Int16
    var base_sequence: Int32
    var last_sequence: Int64
    var records: List[KafkaRecord]
    var is_transactional: Bool

    def __init__(
        out self,
        producer_id: Int64,
        producer_epoch: Int16,
        base_sequence: Int32,
        last_sequence: Int64,
        var records: List[KafkaRecord],
        is_transactional: Bool = False,
    ):
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.base_sequence = base_sequence
        self.last_sequence = last_sequence
        self.records = records^
        self.is_transactional = is_transactional

    def copy(self) -> Self:
        return Self(
            self.producer_id,
            self.producer_epoch,
            self.base_sequence,
            self.last_sequence,
            self.records.copy(),
            self.is_transactional,
        )


def _batch_records(
    data: Span[UInt8, _], hdr: BatchHeader
) raises -> List[KafkaRecord]:
    """The parsed records of one split batch, decompressed when the batch's
    codec is not `none`."""
    var blob = data[hdr.records_pos : hdr.records_pos + hdr.records_len]
    if hdr.compression_codec == KAFKA_COMPRESSION_NONE:
        return parse_records_from_span(
            blob, hdr.records_count, hdr.base_offset, hdr.first_timestamp
        )
    var plain = decompress_kafka_records(hdr.compression_codec, blob)
    return parse_records_from_span(
        Span(plain), hdr.records_count, hdr.base_offset, hdr.first_timestamp
    )


def decode_producer_batches_decompressing(
    data: Span[UInt8, _]
) raises -> List[DecodedProducerBatch]:
    """Decode a message set (concatenated v2 RecordBatches) into one group per
    batch, each carrying its producer identity and its decompressed records.
    The idempotent Produce path gates each batch on that identity, so the
    grouping must survive the decode. A batch with no records is skipped."""
    var dec = KafkaDecoder(data)
    var out = List[DecodedProducerBatch]()
    while dec.remaining() >= 12:  # baseOffset(8) + batchLength(4)
        var hdr = split_record_batch_header(dec)
        if hdr.records_count == 0:
            continue
        var recs = _batch_records(data, hdr)
        var last_seq = Int64(-1)
        if hdr.base_sequence >= Int32(0):
            last_seq = (
                Int64(hdr.base_sequence) + Int64(hdr.records_count) - Int64(1)
            )
        out.append(
            DecodedProducerBatch(
                hdr.producer_id,
                hdr.producer_epoch,
                hdr.base_sequence,
                last_seq,
                recs^,
                hdr.is_transactional,
            )
        )
    return out^


def decode_record_batches_decompressing(
    data: Span[UInt8, _]
) raises -> List[KafkaRecord]:
    """Decode a message set (concatenated v2 RecordBatches), decompressing any
    compressed batch's records blob, into one flat list of records. A batch
    with no records is skipped."""
    var dec = KafkaDecoder(data)
    var out = List[KafkaRecord]()
    while dec.remaining() >= 12:  # baseOffset(8) + batchLength(4)
        var hdr = split_record_batch_header(dec)
        if hdr.records_count == 0:
            continue
        var recs = _batch_records(data, hdr)
        for i in range(len(recs)):
            out.append(recs[i].copy())
    return out^
