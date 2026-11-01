# =============================================================================
# tests/test_kafka_fetch_compress.mojo
#
# Fetch-path compression (kafka_fetch_compress.mojo), offline.
#
# What each test proves, and the defect it catches:
#   * compress then decompress returns the payload for every codec, for an
#     empty payload and for a 1 MiB payload. A codec wired to the wrong framing
#     fails to decode here.
#   * the bytes on the wire are what a Kafka client expects, checked with
#     komira_compression's own decoders and by reading the header bytes:
#     gzip starts 1f 8b (RFC 1952, not zlib's 78 ..), snappy is the xerial
#     header plus one block whose length field matches, lz4 starts with the
#     frame magic, zstd with the zstd magic. A compressor that wrote zlib
#     framing for gzip, or a bare snappy block, fails here even though our own
#     decoder accepts it.
#   * none returns a copy, an unknown id is refused naming the id, the codec
#     names are right.
#   * a batch built around the compressed records carries the codec in the
#     attributes bits and decodes back to the records.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_compression.compression_codecs import (
    Gzip,
    Lz4Frame,
    Snappy,
    Zstd,
)

from komira_kafka_broker.kafka_compression import (
    decode_record_batches_decompressing,
    decompress_kafka_records,
)
from komira_kafka_broker.kafka_fetch_compress import (
    FETCH_COMPRESSION_GZIP,
    FETCH_COMPRESSION_LZ4,
    FETCH_COMPRESSION_NONE,
    FETCH_COMPRESSION_SNAPPY,
    FETCH_COMPRESSION_ZSTD,
    compress_kafka_records,
    fetch_compression_codec_name,
)
from komira_kafka_server.wire.record_batch_v2 import (
    KafkaHeader,
    KafkaRecord,
    encode_record_array_plaintext,
    encode_record_batch_v2_compressed,
    record_batch_first_timestamp,
    record_batch_max_timestamp,
)


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _assert_bytes_eq(a: List[UInt8], b: List[UInt8], label: String) raises:
    assert_equal(len(a), len(b), label + ": length")
    for i in range(len(a)):
        if a[i] != b[i]:
            raise Error(label + ": byte " + String(i) + " differs")


def _patterned(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i % 251))
    return out^


def _codec_ids() -> List[Int]:
    var ids = List[Int]()
    ids.append(FETCH_COMPRESSION_GZIP)
    ids.append(FETCH_COMPRESSION_SNAPPY)
    ids.append(FETCH_COMPRESSION_LZ4)
    ids.append(FETCH_COMPRESSION_ZSTD)
    return ids^


def _make_records() -> List[KafkaRecord]:
    var recs = List[KafkaRecord]()
    var h0 = List[KafkaHeader]()
    h0.append(KafkaHeader(_bytes("src"), Optional(_bytes("unit"))))
    recs.append(
        KafkaRecord(
            Optional(_bytes("k0")),
            Optional(_bytes("the-quick-brown-fox-value-0")),
            h0^,
            Int64(1000),
            Int64(0),
        )
    )
    recs.append(
        KafkaRecord(
            Optional(_bytes("k1")),
            Optional(_bytes("the-quick-brown-fox-value-1")),
            List[KafkaHeader](),
            Int64(1005),
            Int64(1),
        )
    )
    recs.append(
        KafkaRecord(
            Optional[List[UInt8]](),
            Optional(_bytes("value-2-with-null-key")),
            List[KafkaHeader](),
            Int64(1010),
            Int64(2),
        )
    )
    return recs^


def test_roundtrip_each_codec() raises:
    var payload = _bytes(
        "a payload of plaintext records bytes that should compress and"
        " round-trip exactly through every codec's Kafka framing 0123456789"
        " 0123456789 0123456789 0123456789 repeated for some redundancy"
    )
    var ids = _codec_ids()
    for i in range(len(ids)):
        var compressed = compress_kafka_records(ids[i], Span(payload))
        var back = decompress_kafka_records(ids[i], Span(compressed))
        _assert_bytes_eq(
            back,
            payload,
            "round trip " + String(fetch_compression_codec_name(ids[i])),
        )


def test_roundtrip_empty_and_large_payloads() raises:
    var empty = List[UInt8]()
    var large = _patterned(1024 * 1024)
    var ids = _codec_ids()
    for i in range(len(ids)):
        var name = String(fetch_compression_codec_name(ids[i]))
        var c0 = compress_kafka_records(ids[i], Span(empty))
        var b0 = decompress_kafka_records(ids[i], Span(c0))
        assert_equal(len(b0), 0, "empty " + name)
        var c1 = compress_kafka_records(ids[i], Span(large))
        assert_true(len(c1) < len(large) // 4, "large payload compressed")
        var b1 = decompress_kafka_records(ids[i], Span(c1))
        _assert_bytes_eq(b1, large, "large " + name)


def test_gzip_is_rfc1952_framing() raises:
    var payload = _patterned(5000)
    var out = compress_kafka_records(FETCH_COMPRESSION_GZIP, Span(payload))
    assert_equal(Int(out[0]), 0x1F)
    assert_equal(Int(out[1]), 0x8B)
    # komira_compression's own gzip decoder reads it back.
    var back = Gzip.decompress(Span(out), len(payload))
    _assert_bytes_eq(back, payload, "gzip via Gzip.decompress")


def test_zstd_is_a_zstd_frame() raises:
    var payload = _patterned(5000)
    var out = compress_kafka_records(FETCH_COMPRESSION_ZSTD, Span(payload))
    assert_equal(Int(out[0]), 0x28)
    assert_equal(Int(out[1]), 0xB5)
    assert_equal(Int(out[2]), 0x2F)
    assert_equal(Int(out[3]), 0xFD)
    var back = Zstd.decompress(Span(out), len(payload))
    _assert_bytes_eq(back, payload, "zstd via Zstd.decompress")


def test_lz4_is_one_lz4_frame() raises:
    var payload = _patterned(5000)
    var out = compress_kafka_records(FETCH_COMPRESSION_LZ4, Span(payload))
    # The frame magic 0x184D2204, little-endian.
    assert_equal(Int(out[0]), 0x04)
    assert_equal(Int(out[1]), 0x22)
    assert_equal(Int(out[2]), 0x4D)
    assert_equal(Int(out[3]), 0x18)
    var back = Lz4Frame.decompress(Span(out), len(payload))
    _assert_bytes_eq(back, payload, "lz4 via Lz4Frame.decompress")


def test_snappy_is_xerial_with_one_block() raises:
    var payload = _patterned(5000)
    var out = compress_kafka_records(FETCH_COMPRESSION_SNAPPY, Span(payload))
    var magic = List[UInt8]()
    magic.append(UInt8(0x82))
    for c in String("SNAPPY").as_bytes():
        magic.append(c)
    magic.append(UInt8(0))
    for i in range(8):
        assert_equal(Int(out[i]), Int(magic[i]), "xerial magic byte")
    # version 1, compatible version 1 (big-endian int32 each).
    for i in range(8, 16):
        var want = 1 if (i == 11 or i == 15) else 0
        assert_equal(Int(out[i]), want, "xerial version byte " + String(i))
    # One block: its length field covers every remaining byte.
    var block_len = (
        (Int(out[16]) << 24)
        | (Int(out[17]) << 16)
        | (Int(out[18]) << 8)
        | Int(out[19])
    )
    assert_equal(block_len, len(out) - 20, "block length field")
    var back = Snappy.decompress(Span(out)[20:], len(payload))
    _assert_bytes_eq(back, payload, "snappy block via Snappy.decompress")


def test_none_is_a_copy() raises:
    var payload = _bytes("passthrough")
    var out = compress_kafka_records(FETCH_COMPRESSION_NONE, Span(payload))
    _assert_bytes_eq(out, payload, "none")


def test_unknown_codec_id_is_refused() raises:
    var payload = _bytes("payload")
    var ids = List[Int]()
    ids.append(5)
    ids.append(-1)
    ids.append(99)
    for i in range(len(ids)):
        var message = String("")
        var raised = False
        try:
            var out = compress_kafka_records(ids[i], Span(payload))
            _ = out^
        except e:
            raised = True
            message = String(e)
        assert_true(raised, "unknown codec accepted")
        assert_true(
            message.find("unsupported codec id " + String(ids[i])) >= 0, message
        )


def test_codec_names() raises:
    assert_equal(String(fetch_compression_codec_name(FETCH_COMPRESSION_NONE)), "none")
    assert_equal(String(fetch_compression_codec_name(FETCH_COMPRESSION_GZIP)), "gzip")
    assert_equal(String(fetch_compression_codec_name(FETCH_COMPRESSION_SNAPPY)), "snappy")
    assert_equal(String(fetch_compression_codec_name(FETCH_COMPRESSION_LZ4)), "lz4")
    assert_equal(String(fetch_compression_codec_name(FETCH_COMPRESSION_ZSTD)), "zstd")
    assert_equal(String(fetch_compression_codec_name(5)), "unknown")
    assert_equal(String(fetch_compression_codec_name(-1)), "unknown")


def test_compressed_batch_attributes_and_decode() raises:
    """The attributes field sits after baseOffset(8), batchLength(4),
    partitionLeaderEpoch(4), magic(1) and crc(4): bytes 21 and 22."""
    var ids = _codec_ids()
    for ci in range(len(ids)):
        var codec = ids[ci]
        var name = String(fetch_compression_codec_name(codec))
        var recs = _make_records()
        var n = len(recs)
        var base = recs[0].offset
        var plain = encode_record_array_plaintext(recs, base)
        var blob = compress_kafka_records(codec, Span(plain))
        var batch = encode_record_batch_v2_compressed(
            Span(blob),
            n,
            record_batch_first_timestamp(recs),
            record_batch_max_timestamp(recs),
            base,
            Int32(n - 1),
            codec,
        )
        var attributes = (Int(batch[21]) << 8) | Int(batch[22])
        assert_equal(attributes & 0x07, codec, "attributes bits " + name)

        var decoded = decode_record_batches_decompressing(Span(batch))
        assert_equal(len(decoded), n, "decoded count " + name)
        for i in range(n):
            _assert_bytes_eq(
                decoded[i].value.value(), recs[i].value.value(), "value " + name
            )
            assert_equal(decoded[i].timestamp, recs[i].timestamp, "ts " + name)
            assert_equal(decoded[i].offset, Int64(i), "offset " + name)
        assert_equal(len(decoded[0].headers), 1, "header kept " + name)
        _assert_bytes_eq(decoded[0].headers[0].key, _bytes("src"), "hk")
        assert_false(Bool(decoded[2].key), "record 2 key stays null " + name)


def main() raises:
    test_roundtrip_each_codec()
    test_roundtrip_empty_and_large_payloads()
    test_gzip_is_rfc1952_framing()
    test_zstd_is_a_zstd_frame()
    test_lz4_is_one_lz4_frame()
    test_snappy_is_xerial_with_one_block()
    test_none_is_a_copy()
    test_unknown_codec_id_is_refused()
    test_codec_names()
    test_compressed_batch_attributes_and_decode()
    print("test_kafka_fetch_compress: ALL PASS")
