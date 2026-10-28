# =============================================================================
# tests/test_kafka_compression.mojo
#
# Produce-path decompression (kafka_compression.mojo), offline. The producer
# side of every test is built here from komira_compression directly, never
# from kafka_fetch_compress, so a fault in the decompressor cannot be hidden by
# a matching fault in the compressor.
#
# What each test proves, and the defect it catches:
#   * the five codec ids decode: none returns the input; gzip, snappy (xerial),
#     lz4 and zstd return the payload byte for byte. A decoder wired to the
#     wrong codec for an id fails here.
#   * a payload far larger than the first output buffer decodes in every
#     growing codec. A decoder that does not grow its buffer (or grows it
#     wrongly) truncates or raises here.
#   * xerial framing: several blocks concatenate in order, a bare raw block is
#     accepted, a block length past the end is refused, an oversized preamble
#     is refused before it is allocated.
#   * corrupt and truncated blobs of each codec are refused, naming the codec.
#   * a cut gzip stream is refused as truncated; gzip members concatenate, and
#     garbage after a member is refused; xerial trailing bytes are refused.
#   * output one byte over the ceiling is refused for gzip, lz4 and zstd.
#   * an unknown codec id is refused, naming the id.
#   * whole batches (with a correct CRC) decode to the records of the same
#     batch encoded uncompressed, in a message set that mixes compressed and
#     plain batches; a batch with no records is skipped; a flipped bit in a
#     compressed batch is refused.
#   * decode_producer_batches_decompressing keeps each batch's producer
#     identity, the last sequence and the transactional bit.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_compression.compression_codecs import (
    Gzip,
    Lz4Frame,
    Snappy,
    Zstd,
)

from komira_kafka_broker.kafka_compression import (
    DecodedProducerBatch,
    KAFKA_COMPRESSION_GZIP,
    KAFKA_COMPRESSION_LZ4,
    KAFKA_COMPRESSION_NONE,
    KAFKA_COMPRESSION_SNAPPY,
    KAFKA_COMPRESSION_ZSTD,
    decode_producer_batches_decompressing,
    decode_record_batches_decompressing,
    decompress_kafka_records,
)
from komira_kafka_server.wire import crc32c_span
from komira_kafka_server.wire.record_batch_v2 import (
    KafkaHeader,
    KafkaRecord,
    decode_record_batches,
    encode_record_array_plaintext,
    encode_record_batch_v2,
    encode_record_batch_v2_compressed,
)


# =============================================================================
# Byte helpers.
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _assert_bytes_eq(a: List[UInt8], b: List[UInt8], label: String) raises:
    assert_equal(len(a), len(b), label + ": length")
    for i in range(len(a)):
        if a[i] != b[i]:
            raise Error(label + ": byte " + String(i) + " differs")


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


def _put_int64_be(mut out: List[UInt8], v: Int64):
    var u = v.cast[DType.uint64]()
    for shift in range(7, -1, -1):
        out.append(UInt8((u >> UInt64(shift * 8)) & UInt64(0xFF)))


def _patterned(n: Int) -> List[UInt8]:
    """`n` bytes that repeat every 251: they compress well and are not all
    one byte."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i % 251))
    return out^


# =============================================================================
# Producer-side framing, built from komira_compression.
# =============================================================================


def _xerial_header() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0x82))
    for c in String("SNAPPY").as_bytes():
        out.append(c)
    out.append(UInt8(0))
    _put_int32_be(out, Int32(1))  # version
    _put_int32_be(out, Int32(1))  # compatible version
    return out^


def _xerial_blocks(chunks: List[List[UInt8]]) raises -> List[UInt8]:
    """The xerial framing with one raw snappy block per chunk."""
    var out = _xerial_header()
    for i in range(len(chunks)):
        var block = Snappy.compress(Span(chunks[i]))
        _put_int32_be(out, Int32(len(block)))
        out.extend(Span(block))
    return out^


def _compress(codec_id: Int, plain: List[UInt8]) raises -> List[UInt8]:
    if codec_id == KAFKA_COMPRESSION_GZIP:
        return Gzip.compress_gzip_file(Span(plain))
    elif codec_id == KAFKA_COMPRESSION_ZSTD:
        return Zstd.compress(Span(plain))
    elif codec_id == KAFKA_COMPRESSION_LZ4:
        return Lz4Frame.compress(Span(plain))
    elif codec_id == KAFKA_COMPRESSION_SNAPPY:
        var chunks = List[List[UInt8]]()
        chunks.append(plain.copy())
        return _xerial_blocks(chunks)
    return plain.copy()


def _codec_ids() -> List[Int]:
    var ids = List[Int]()
    ids.append(KAFKA_COMPRESSION_GZIP)
    ids.append(KAFKA_COMPRESSION_SNAPPY)
    ids.append(KAFKA_COMPRESSION_LZ4)
    ids.append(KAFKA_COMPRESSION_ZSTD)
    return ids^


def _name(codec_id: Int) -> String:
    if codec_id == KAFKA_COMPRESSION_GZIP:
        return "gzip"
    if codec_id == KAFKA_COMPRESSION_SNAPPY:
        return "snappy"
    if codec_id == KAFKA_COMPRESSION_LZ4:
        return "lz4"
    if codec_id == KAFKA_COMPRESSION_ZSTD:
        return "zstd"
    return "none"


def _assert_refused(codec_id: Int, blob: List[UInt8], reason: String) raises:
    """`decompress_kafka_records` raises, and the message holds `reason`."""
    var message = String("")
    var raised = False
    try:
        var out = decompress_kafka_records(codec_id, Span(blob))
        _ = out^
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error(_name(codec_id) + ": a bad blob was accepted")
    if message.find(reason) < 0:
        raise Error(
            _name(codec_id) + ": refused for another reason: " + message
        )


# =============================================================================
# Fixtures: records and batches.
# =============================================================================


def _sample_records() -> List[KafkaRecord]:
    var recs = List[KafkaRecord]()
    var h = List[KafkaHeader]()
    h.append(KafkaHeader(_bytes("trace"), Optional(_bytes("abc123"))))
    recs.append(
        KafkaRecord(
            Optional(_bytes("k0")),
            Optional(_bytes("the-quick-brown-fox-the-quick-brown-fox")),
            h^,
            Int64(1000),
            Int64(0),
        )
    )
    recs.append(
        KafkaRecord(
            Optional(_bytes("k1")),
            Optional(_bytes("payload-one-payload-one-payload-one")),
            List[KafkaHeader](),
            Int64(1005),
            Int64(1),
        )
    )
    recs.append(
        KafkaRecord(
            Optional[List[UInt8]](),
            Optional(_bytes("value-with-null-key-value-with-null-key")),
            List[KafkaHeader](),
            Int64(1010),
            Int64(2),
        )
    )
    return recs^


def _assert_records_match(
    got: List[KafkaRecord], expected: List[KafkaRecord]
) raises:
    assert_equal(len(got), len(expected), "record count")
    for i in range(len(expected)):
        ref g = got[i]
        ref e = expected[i]
        assert_equal(Bool(g.key), Bool(e.key), "key presence")
        if e.key:
            _assert_bytes_eq(g.key.value(), e.key.value(), "key")
        assert_equal(Bool(g.value), Bool(e.value), "value presence")
        if e.value:
            _assert_bytes_eq(g.value.value(), e.value.value(), "value")
        assert_equal(len(g.headers), len(e.headers), "header count")
        for hi in range(len(e.headers)):
            _assert_bytes_eq(g.headers[hi].key, e.headers[hi].key, "header key")
            assert_equal(
                Bool(g.headers[hi].value), Bool(e.headers[hi].value), "hv"
            )
            if e.headers[hi].value:
                _assert_bytes_eq(
                    g.headers[hi].value.value(),
                    e.headers[hi].value.value(),
                    "header value",
                )
        assert_equal(g.timestamp, e.timestamp, "timestamp")
        assert_equal(g.offset, e.offset, "offset")


def _compressed_batch(
    codec_id: Int, records: List[KafkaRecord], base_offset: Int64
) raises -> List[UInt8]:
    """A v2 batch of `records` whose Record* array is compressed with
    `codec_id`, with a correct CRC."""
    var n = len(records)
    var plain = encode_record_array_plaintext(records, base_offset)
    var blob = _compress(codec_id, plain)
    var max_ts = records[0].timestamp
    for i in range(1, n):
        if records[i].timestamp > max_ts:
            max_ts = records[i].timestamp
    return encode_record_batch_v2_compressed(
        Span(blob),
        n,
        records[0].timestamp,
        max_ts,
        base_offset,
        Int32(n - 1),
        codec_id,
    )


def _batch_with_producer(
    attributes: Int16,
    producer_id: Int64,
    producer_epoch: Int16,
    base_sequence: Int32,
    records_count: Int,
    records_blob: List[UInt8],
    base_offset: Int64,
) -> List[UInt8]:
    """A v2 batch with the given attributes and producer identity (the wire
    encoder always writes -1 there), with a correct CRC."""
    var post_crc = List[UInt8]()
    _put_int16_be(post_crc, attributes)
    _put_int32_be(post_crc, Int32(records_count - 1 if records_count > 0 else 0))
    _put_int64_be(post_crc, Int64(1000))  # firstTimestamp
    _put_int64_be(post_crc, Int64(1010))  # maxTimestamp
    _put_int64_be(post_crc, producer_id)
    _put_int16_be(post_crc, producer_epoch)
    _put_int32_be(post_crc, base_sequence)
    _put_int32_be(post_crc, Int32(records_count))
    post_crc.extend(Span(records_blob))
    var crc = crc32c_span(Span(post_crc))
    var out = List[UInt8]()
    _put_int64_be(out, base_offset)
    _put_int32_be(out, Int32(4 + 1 + 4 + len(post_crc)))
    _put_int32_be(out, Int32(-1))  # partitionLeaderEpoch
    out.append(UInt8(2))  # magic
    _put_int32_be(out, crc.cast[DType.int32]())
    out.extend(Span(post_crc))
    return out^


# =============================================================================
# decompress_kafka_records.
# =============================================================================


def test_none_returns_a_copy() raises:
    var plain = _bytes("hello-kafka-records-blob")
    var out = decompress_kafka_records(KAFKA_COMPRESSION_NONE, Span(plain))
    _assert_bytes_eq(out, plain, "none")


def test_every_codec_roundtrips() raises:
    var plain = _bytes(
        "records-blob-records-blob-records-blob-records-blob-records-blob"
    )
    var ids = _codec_ids()
    for i in range(len(ids)):
        var blob = _compress(ids[i], plain)
        var out = decompress_kafka_records(ids[i], Span(blob))
        _assert_bytes_eq(out, plain, _name(ids[i]))


def test_payload_larger_than_first_output_buffer() raises:
    # 1 MiB decoded from a few KiB: well past the 64 KiB first buffer, so the
    # doubling loop runs several times in gzip, lz4 and zstd.
    var plain = _patterned(1024 * 1024)
    var ids = _codec_ids()
    for i in range(len(ids)):
        var blob = _compress(ids[i], plain)
        assert_true(len(blob) < len(plain) // 4, _name(ids[i]) + ": fixture")
        var out = decompress_kafka_records(ids[i], Span(blob))
        _assert_bytes_eq(out, plain, "large " + _name(ids[i]))


def test_empty_payload_roundtrips() raises:
    var plain = List[UInt8]()
    var ids = _codec_ids()
    for i in range(len(ids)):
        var blob = _compress(ids[i], plain)
        var out = decompress_kafka_records(ids[i], Span(blob))
        assert_equal(len(out), 0, "empty " + _name(ids[i]))


# =============================================================================
# snappy framing.
# =============================================================================


def test_snappy_xerial_blocks_concatenate_in_order() raises:
    var chunks = List[List[UInt8]]()
    chunks.append(_bytes("first-block-first-block-"))
    chunks.append(_bytes("second-block-second-block-"))
    chunks.append(_bytes("third"))
    var blob = _xerial_blocks(chunks)
    var out = decompress_kafka_records(KAFKA_COMPRESSION_SNAPPY, Span(blob))
    _assert_bytes_eq(
        out,
        _bytes("first-block-first-block-second-block-second-block-third"),
        "three blocks",
    )


def test_snappy_bare_raw_block_is_accepted() raises:
    var plain = _bytes("a raw snappy block with no xerial header, a-raw-block")
    var raw = Snappy.compress(Span(plain))
    var out = decompress_kafka_records(KAFKA_COMPRESSION_SNAPPY, Span(raw))
    _assert_bytes_eq(out, plain, "raw block")


def test_snappy_header_only_is_empty() raises:
    var blob = _xerial_header()
    var out = decompress_kafka_records(KAFKA_COMPRESSION_SNAPPY, Span(blob))
    assert_equal(len(out), 0)


def test_snappy_block_length_past_the_end_is_refused() raises:
    var blob = _xerial_header()
    _put_int32_be(blob, Int32(1000))  # a block of 1000 bytes ...
    blob.append(UInt8(1))  # ... with one byte behind it
    _assert_refused(KAFKA_COMPRESSION_SNAPPY, blob, "runs past end of input")


def test_snappy_negative_block_length_is_refused() raises:
    var blob = _xerial_header()
    _put_int32_be(blob, Int32(-5))
    blob.append(UInt8(0))
    _assert_refused(KAFKA_COMPRESSION_SNAPPY, blob, "runs past end of input")


def test_snappy_oversized_preamble_is_refused_before_allocation() raises:
    # A preamble varint of 2^32 - 1 followed by one byte: the declared length
    # is far over the ceiling, so it is refused without allocating it.
    var raw = List[UInt8]()
    raw.append(UInt8(0xFF))
    raw.append(UInt8(0xFF))
    raw.append(UInt8(0xFF))
    raw.append(UInt8(0xFF))
    raw.append(UInt8(0x0F))
    raw.append(UInt8(0))
    _assert_refused(KAFKA_COMPRESSION_SNAPPY, raw, "exceeds the")
    # The same block inside an xerial frame.
    var framed = _xerial_header()
    _put_int32_be(framed, Int32(len(raw)))
    framed.extend(Span(raw))
    _assert_refused(KAFKA_COMPRESSION_SNAPPY, framed, "exceeds the")


# =============================================================================
# Refusals.
# =============================================================================


def test_garbage_is_refused_by_every_codec() raises:
    var garbage = _bytes("this is not a compressed stream at all, not at all")
    _assert_refused(KAFKA_COMPRESSION_GZIP, garbage, "kafka_compression(gzip)")
    _assert_refused(KAFKA_COMPRESSION_ZSTD, garbage, "kafka_compression(zstd)")
    _assert_refused(KAFKA_COMPRESSION_LZ4, garbage, "kafka_compression(lz4)")
    _assert_refused(KAFKA_COMPRESSION_SNAPPY, garbage, "snappy")


def test_truncated_blob_is_refused() raises:
    var plain = _patterned(20000)
    var ids = List[Int]()
    ids.append(KAFKA_COMPRESSION_GZIP)
    ids.append(KAFKA_COMPRESSION_LZ4)
    ids.append(KAFKA_COMPRESSION_ZSTD)
    for i in range(len(ids)):
        var blob = _compress(ids[i], plain)
        var cut = List[UInt8](Span(blob)[0 : len(blob) // 2])
        _assert_refused(ids[i], cut, "kafka_compression(" + _name(ids[i]) + ")")


def test_truncated_gzip_is_refused_as_truncated_not_as_too_large() raises:
    # A cut stream must stop at once with the truncation reason, not grow the
    # buffer to the ceiling and report that instead.
    var blob = _compress(KAFKA_COMPRESSION_GZIP, _patterned(20000))
    var cut = List[UInt8](Span(blob)[0 : len(blob) // 2])
    _assert_refused(KAFKA_COMPRESSION_GZIP, cut, "truncated batch")


def test_gzip_members_concatenate() raises:
    var first = _patterned(1000)
    var second = _patterned(777)
    var third = _bytes("tail")
    var blob = _compress(KAFKA_COMPRESSION_GZIP, first)
    blob.extend(Span(_compress(KAFKA_COMPRESSION_GZIP, second)))
    blob.extend(Span(_compress(KAFKA_COMPRESSION_GZIP, third)))
    var want = first.copy()
    want.extend(Span(second))
    want.extend(Span(third))
    var got = decompress_kafka_records(KAFKA_COMPRESSION_GZIP, Span(blob))
    _assert_bytes_eq(got, want, "three gzip members")


def test_gzip_ceiling_is_shared_across_members() raises:
    # Two members of 200 MiB each: each is under the 256 MiB ceiling, the sum
    # is over it. The ceiling bounds the whole blob, not each member.
    var member = _compress(
        KAFKA_COMPRESSION_GZIP,
        List[UInt8](length=200 * 1024 * 1024, fill=UInt8(0)),
    )
    var blob = member.copy()
    blob.extend(Span(member))
    _assert_refused(KAFKA_COMPRESSION_GZIP, blob, "-byte ceiling")


def test_gzip_member_followed_by_garbage_is_refused() raises:
    var blob = _compress(KAFKA_COMPRESSION_GZIP, _patterned(500))
    blob.extend(Span(_bytes("not a gzip member")))
    _assert_refused(KAFKA_COMPRESSION_GZIP, blob, "kafka_compression(gzip)")


def test_snappy_trailing_bytes_after_the_last_block_are_refused() raises:
    var chunks = List[List[UInt8]]()
    chunks.append(_patterned(100))
    var blob = _xerial_blocks(chunks)
    blob.append(UInt8(1))
    blob.append(UInt8(2))
    _assert_refused(KAFKA_COMPRESSION_SNAPPY, blob, "trailing bytes")


def test_output_ceiling_refuses_a_decompression_bomb() raises:
    # 256 MiB + 1 zero bytes: one byte over the ceiling, for each growing codec.
    var plain = List[UInt8](length=256 * 1024 * 1024 + 1, fill=UInt8(0))
    var ids = List[Int]()
    ids.append(KAFKA_COMPRESSION_GZIP)
    ids.append(KAFKA_COMPRESSION_LZ4)
    ids.append(KAFKA_COMPRESSION_ZSTD)
    for i in range(len(ids)):
        var blob = _compress(ids[i], plain)
        _assert_refused(ids[i], blob, "-byte ceiling")


def test_empty_blob_is_refused_by_the_stream_codecs() raises:
    var empty = List[UInt8]()
    _assert_refused(KAFKA_COMPRESSION_GZIP, empty, "kafka_compression(gzip)")
    _assert_refused(KAFKA_COMPRESSION_ZSTD, empty, "kafka_compression(zstd)")
    _assert_refused(KAFKA_COMPRESSION_LZ4, empty, "kafka_compression(lz4)")


def test_unknown_codec_id_is_refused() raises:
    var plain = _bytes("payload")
    var ids = List[Int]()
    ids.append(5)
    ids.append(7)
    ids.append(-1)
    ids.append(255)
    for i in range(len(ids)):
        _assert_refused(
            ids[i],
            plain,
            "unsupported codec id " + String(ids[i]),
        )


# =============================================================================
# Whole batches.
# =============================================================================


def _reference() raises -> List[KafkaRecord]:
    """The records an uncompressed batch of the sample records decodes to."""
    var batch = encode_record_batch_v2(_sample_records(), Int64(0))
    return decode_record_batches(Span(batch))


def test_compressed_batch_decodes_like_the_plain_batch() raises:
    var ids = _codec_ids()
    for i in range(len(ids)):
        var batch = _compressed_batch(ids[i], _sample_records(), Int64(0))
        var got = decode_record_batches_decompressing(Span(batch))
        _assert_records_match(got, _reference())


def test_plain_batch_still_decodes() raises:
    var batch = encode_record_batch_v2(_sample_records(), Int64(0))
    var got = decode_record_batches_decompressing(Span(batch))
    _assert_records_match(got, _reference())


def test_message_set_of_mixed_batches_keeps_order() raises:
    var first = _compressed_batch(KAFKA_COMPRESSION_GZIP, _sample_records(), Int64(0))
    var second = encode_record_batch_v2(_sample_records(), Int64(3))
    var third = _compressed_batch(KAFKA_COMPRESSION_ZSTD, _sample_records(), Int64(6))
    var set = List[UInt8]()
    set.extend(Span(first))
    set.extend(Span(second))
    set.extend(Span(third))
    var got = decode_record_batches_decompressing(Span(set))
    assert_equal(len(got), 9)
    for i in range(9):
        assert_equal(got[i].offset, Int64(i), "offset " + String(i))
    var ref_records = _sample_records()
    for i in range(9):
        _assert_bytes_eq(
            got[i].value.value(), ref_records[i % 3].value.value(), "value"
        )


def test_batch_with_no_records_is_skipped() raises:
    var empty = _batch_with_producer(
        Int16(0), Int64(-1), Int16(-1), Int32(-1), 0, List[UInt8](), Int64(0)
    )
    var real = _compressed_batch(KAFKA_COMPRESSION_LZ4, _sample_records(), Int64(0))
    var set = List[UInt8]()
    set.extend(Span(empty))
    set.extend(Span(real))
    var flat = decode_record_batches_decompressing(Span(set))
    _assert_records_match(flat, _reference())
    var grouped = decode_producer_batches_decompressing(Span(set))
    assert_equal(len(grouped), 1)


def test_flipped_bit_in_a_compressed_batch_is_refused() raises:
    var batch = _compressed_batch(KAFKA_COMPRESSION_GZIP, _sample_records(), Int64(0))
    batch[len(batch) - 3] = batch[len(batch) - 3] ^ UInt8(0x01)
    var message = String("")
    var raised = False
    try:
        var got = decode_record_batches_decompressing(Span(batch))
        _ = got^
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a corrupt batch was accepted")
    assert_true(message.find("CRC-32C mismatch") >= 0, message)


def test_corrupt_compressed_records_are_refused_with_the_codec_named() raises:
    # A batch whose CRC is right but whose gzip blob is not a gzip stream.
    var blob = _bytes("not gzip bytes, but the batch around them is well formed")
    var batch = encode_record_batch_v2_compressed(
        Span(blob), 3, Int64(1000), Int64(1010), Int64(0), Int32(2),
        KAFKA_COMPRESSION_GZIP,
    )
    var message = String("")
    var raised = False
    try:
        var got = decode_record_batches_decompressing(Span(batch))
        _ = got^
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a bad gzip blob was accepted")
    assert_true(message.find("kafka_compression(gzip)") >= 0, message)


# =============================================================================
# Per-batch producer identity.
# =============================================================================


def test_producer_identity_is_kept_per_batch() raises:
    var recs = _sample_records()
    var plain = encode_record_array_plaintext(recs, Int64(0))

    # An idempotent, uncompressed batch: pid 7, epoch 3, base sequence 10.
    var idem = _batch_with_producer(
        Int16(0), Int64(7), Int16(3), Int32(10), 3, plain, Int64(0)
    )
    # A transactional, zstd-compressed batch of another producer.
    var txn = _batch_with_producer(
        Int16(KAFKA_COMPRESSION_ZSTD | 0x10),
        Int64(9000000000),
        Int16(1),
        Int32(0),
        3,
        _compress(KAFKA_COMPRESSION_ZSTD, plain),
        Int64(3),
    )
    # A batch from a producer without idempotence.
    var plain_batch = encode_record_batch_v2(recs, Int64(6))

    var set = List[UInt8]()
    set.extend(Span(idem))
    set.extend(Span(txn))
    set.extend(Span(plain_batch))
    var got = decode_producer_batches_decompressing(Span(set))
    assert_equal(len(got), 3)

    assert_equal(got[0].producer_id, Int64(7))
    assert_equal(Int(got[0].producer_epoch), 3)
    assert_equal(Int(got[0].base_sequence), 10)
    assert_equal(got[0].last_sequence, Int64(12))
    assert_false(got[0].is_transactional)
    assert_equal(len(got[0].records), 3)

    assert_equal(got[1].producer_id, Int64(9000000000))
    assert_equal(Int(got[1].producer_epoch), 1)
    assert_equal(Int(got[1].base_sequence), 0)
    assert_equal(got[1].last_sequence, Int64(2))
    assert_true(got[1].is_transactional)
    assert_equal(len(got[1].records), 3)
    assert_equal(got[1].records[0].offset, Int64(3))
    _assert_bytes_eq(
        got[1].records[2].value.value(), recs[2].value.value(), "txn value"
    )

    assert_equal(got[2].producer_id, Int64(-1))
    assert_equal(Int(got[2].producer_epoch), -1)
    assert_equal(Int(got[2].base_sequence), -1)
    assert_equal(got[2].last_sequence, Int64(-1))
    assert_false(got[2].is_transactional)
    assert_equal(got[2].records[0].offset, Int64(6))


def test_decoded_producer_batch_copy_is_deep() raises:
    var recs = _sample_records()
    var original = DecodedProducerBatch(
        Int64(4), Int16(2), Int32(5), Int64(7), recs.copy(), True
    )
    var copied = original.copy()
    original.records[0].offset = Int64(999)
    assert_equal(copied.records[0].offset, Int64(0))
    assert_equal(copied.producer_id, Int64(4))
    assert_equal(Int(copied.producer_epoch), 2)
    assert_equal(Int(copied.base_sequence), 5)
    assert_equal(copied.last_sequence, Int64(7))
    assert_true(copied.is_transactional)


def main() raises:
    test_none_returns_a_copy()
    test_every_codec_roundtrips()
    test_payload_larger_than_first_output_buffer()
    test_empty_payload_roundtrips()
    test_snappy_xerial_blocks_concatenate_in_order()
    test_snappy_bare_raw_block_is_accepted()
    test_snappy_header_only_is_empty()
    test_snappy_block_length_past_the_end_is_refused()
    test_snappy_negative_block_length_is_refused()
    test_snappy_oversized_preamble_is_refused_before_allocation()
    test_garbage_is_refused_by_every_codec()
    test_truncated_blob_is_refused()
    test_truncated_gzip_is_refused_as_truncated_not_as_too_large()
    test_gzip_members_concatenate()
    test_gzip_ceiling_is_shared_across_members()
    test_gzip_member_followed_by_garbage_is_refused()
    test_snappy_trailing_bytes_after_the_last_block_are_refused()
    test_output_ceiling_refuses_a_decompression_bomb()
    test_empty_blob_is_refused_by_the_stream_codecs()
    test_unknown_codec_id_is_refused()
    test_compressed_batch_decodes_like_the_plain_batch()
    test_plain_batch_still_decodes()
    test_message_set_of_mixed_batches_keeps_order()
    test_batch_with_no_records_is_skipped()
    test_flipped_bit_in_a_compressed_batch_is_refused()
    test_corrupt_compressed_records_are_refused_with_the_codec_named()
    test_producer_identity_is_kept_per_batch()
    test_decoded_producer_batch_copy_is_deep()
    print("test_kafka_compression: ALL PASS")
