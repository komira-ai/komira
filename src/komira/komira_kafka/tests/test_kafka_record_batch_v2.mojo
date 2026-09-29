# =============================================================================
# test_kafka_record_batch_v2.mojo
#   CRC32C + RecordBatch-v2 + Produce/Fetch/ListOffsets
#   codec unit tests (byte-exact + round-trip; no network).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_kafka.crc32c import crc32c_span, crc32c_list
from komira_kafka.record_batch_v2 import (
    KafkaRecord,
    KafkaHeader,
    encode_record_batch_v2,
    decode_record_batches,
    put_varint,
    put_varlong,
    get_varint,
    get_varlong,
)
from komira_kafka.produce_fetch import (
    encode_produce_response_v7,
    ProduceTopicResult,
    ProducePartitionResult,
    encode_list_offsets_response_v2,
    ListOffsetsTopicResult,
    ListOffsetsPartitionResult,
)
from komira_kafka.wire import KafkaDecoder


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_crc32c_known_vectors() raises:
    # CRC-32C (Castagnoli) standard test vectors.
    # "123456789" -> 0xE3069283
    assert_equal(Int(crc32c_list(_bytes("123456789"))), 0xE3069283)
    # empty -> 0
    var empty = List[UInt8]()
    assert_equal(Int(crc32c_list(empty)), 0)
    # single 0x00 -> 0x527D5351
    var z = List[UInt8]()
    z.append(UInt8(0))
    assert_equal(Int(crc32c_list(z)), 0x527D5351)


def test_zigzag_varint_roundtrip() raises:
    var values = List[Int32]()
    values.append(0)
    values.append(-1)
    values.append(1)
    values.append(-2)
    values.append(2)
    values.append(2147483647)
    values.append(-2147483648)
    values.append(300)
    for i in range(len(values)):
        var buf = List[UInt8]()
        put_varint(buf, values[i])
        var dec = KafkaDecoder(Span(buf))
        assert_equal(Int(get_varint(dec)), Int(values[i]))


def test_zigzag_varlong_roundtrip() raises:
    var values = List[Int64]()
    values.append(0)
    values.append(-1)
    values.append(1)
    values.append(1234567890123)
    values.append(-9876543210)
    for i in range(len(values)):
        var buf = List[UInt8]()
        put_varlong(buf, values[i])
        var dec = KafkaDecoder(Span(buf))
        assert_equal(Int(get_varlong(dec)), Int(values[i]))


def test_record_batch_v2_roundtrip() raises:
    # Build 2 records: (k1, hello) and (null-key, world) + a header.
    var records = List[KafkaRecord]()

    var h = List[KafkaHeader]()
    records.append(
        KafkaRecord(
            Optional(_bytes("k1")),
            Optional(_bytes("hello")),
            h^,
            Int64(1000),
            Int64(0),
        )
    )
    var h2 = List[KafkaHeader]()
    h2.append(KafkaHeader(_bytes("hk"), Optional(_bytes("hv"))))
    records.append(
        KafkaRecord(
            Optional[List[UInt8]](),  # null key
            Optional(_bytes("world")),
            h2^,
            Int64(1005),
            Int64(1),
        )
    )

    var wire = encode_record_batch_v2(records, Int64(0))
    var decoded = decode_record_batches(Span(wire))

    assert_equal(len(decoded), 2)

    # record 0
    assert_true(Bool(decoded[0].key))
    assert_equal(Int(decoded[0].key.value()[0]), Int(ord("k")))
    assert_equal(len(decoded[0].value.value()), 5)
    assert_equal(Int(decoded[0].value.value()[0]), Int(ord("h")))
    assert_equal(Int(decoded[0].timestamp), 1000)
    assert_equal(Int(decoded[0].offset), 0)

    # record 1 — null key, value "world", offset 1, one header
    assert_true(not decoded[1].key)
    assert_equal(len(decoded[1].value.value()), 5)
    assert_equal(Int(decoded[1].value.value()[0]), Int(ord("w")))
    assert_equal(Int(decoded[1].timestamp), 1005)
    assert_equal(Int(decoded[1].offset), 1)
    assert_equal(len(decoded[1].headers), 1)
    assert_equal(Int(decoded[1].headers[0].key[0]), Int(ord("h")))


def test_record_batch_v2_base_offset_renumber() raises:
    # When encoded with base_offset=42, the decoded records should carry
    # absolute offsets 42, 43.
    var records = List[KafkaRecord]()
    var h0 = List[KafkaHeader]()
    records.append(
        KafkaRecord(
            Optional(_bytes("a")), Optional(_bytes("x")), h0^, Int64(7), Int64(42)
        )
    )
    var h1 = List[KafkaHeader]()
    records.append(
        KafkaRecord(
            Optional(_bytes("b")), Optional(_bytes("y")), h1^, Int64(8), Int64(43)
        )
    )
    var wire = encode_record_batch_v2(records, Int64(42))
    var decoded = decode_record_batches(Span(wire))
    assert_equal(Int(decoded[0].offset), 42)
    assert_equal(Int(decoded[1].offset), 43)


def test_produce_response_v7_encodes() raises:
    var parts = List[ProducePartitionResult]()
    parts.append(ProducePartitionResult(Int32(0), Int16(0), Int64(100)))
    var topics = List[ProduceTopicResult]()
    topics.append(ProduceTopicResult(String("t"), parts^))
    var bytes = encode_produce_response_v7(Int32(7), topics^)
    # header(4) + array_len(4) + name(2+1) + parts_len(4) + index(4) +
    # err(2) + base(8) + log_append(8) + log_start(8) + throttle(4) = 49
    assert_equal(len(bytes), 49)
    # correlation_id is the first 4 bytes BE.
    assert_equal(Int(bytes[3]), 7)


def test_list_offsets_response_v2_encodes() raises:
    var parts = List[ListOffsetsPartitionResult]()
    parts.append(
        ListOffsetsPartitionResult(Int32(0), Int16(0), Int64(-1), Int64(50))
    )
    var topics = List[ListOffsetsTopicResult]()
    topics.append(ListOffsetsTopicResult(String("t"), parts^))
    var bytes = encode_list_offsets_response_v2(Int32(3), topics^)
    assert_true(len(bytes) > 0)
    assert_equal(Int(bytes[3]), 3)  # correlation_id


def main() raises:
    test_crc32c_known_vectors()
    test_zigzag_varint_roundtrip()
    test_zigzag_varlong_roundtrip()
    test_record_batch_v2_roundtrip()
    test_record_batch_v2_base_offset_renumber()
    test_produce_response_v7_encodes()
    test_list_offsets_response_v2_encodes()
    print("OK test_kafka_record_batch_v2")
