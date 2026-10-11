# The v2 RecordBatch paths the round-trip and hostile tests leave out: the
# compressed-batch encoder the Fetch path uses, the plaintext Record* array
# encoder, the first/max timestamp helpers, the 10-byte varlong limit, and the
# refusals of a control batch, a compressed batch handed to the zero-dep
# decoder, an empty record list, a negative count and a record longer than the
# bytes left, each with its exact message.
#
# Byte layout (record_batch_v2.mojo's header): 0..7 baseOffset, 8..11
# batchLength, 12..15 partitionLeaderEpoch, 16 magic, 17..20 crc, 21..22
# attributes, 23..26 lastOffsetDelta, 27..34 firstTimestamp, 35..42
# maxTimestamp, 43..50 producerId, 51..52 producerEpoch, 53..56 baseSequence,
# 57..60 recordsCount, 61.. records.

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_server.wire.crc32c import crc32c_list
from komira_kafka_server.wire.record_batch_v2 import (
    KafkaHeader,
    KafkaRecord,
    decode_record_batch_v2,
    encode_record_array_plaintext,
    encode_record_batch_v2,
    encode_record_batch_v2_compressed,
    get_varlong,
    parse_records_from_span,
    put_varlong,
    record_batch_first_timestamp,
    record_batch_max_timestamp,
    split_record_batch_header,
)
from komira_kafka_server.wire.wire import KafkaDecoder


comptime CRC_POS = 17
comptime ATTR_POS = 21
comptime RECORDS_POS = 61


def _hex(s: String) -> List[UInt8]:
    """Bytes from hex digits; anything else (spaces, `|`) separates them."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var hi = -1
    for i in range(len(b)):
        var c = Int(b[i])
        var v = -1
        if c >= 48 and c <= 57:
            v = c - 48
        elif c >= 97 and c <= 102:
            v = c - 87
        if v < 0:
            continue
        if hi < 0:
            hi = v
        else:
            out.append(UInt8(hi * 16 + v))
            hi = -1
    return out^


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _assert_bytes_eq(got: List[UInt8], want: List[UInt8], ctx: String) raises:
    assert_equal(len(got), len(want), ctx + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), ctx + ": byte " + String(i))


def _slice(b: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(b[i])
    return out^


def _rec(key: String, value: String, ts: Int64, offset: Int64) -> KafkaRecord:
    var h = List[KafkaHeader]()
    h.append(KafkaHeader(_bytes("h"), Optional(_bytes("v"))))
    return KafkaRecord(
        Optional(_bytes(key)), Optional(_bytes(value)), h^, ts, offset
    )


def _three(t0: Int64, t1: Int64, t2: Int64) -> List[KafkaRecord]:
    var out = List[KafkaRecord]()
    out.append(_rec("a", "one", t0, 500))
    out.append(_rec("b", "two", t1, 501))
    out.append(_rec("c", "three", t2, 502))
    return out^


def _reseal(mut b: List[UInt8]):
    var crc = crc32c_list(_slice(b, ATTR_POS, len(b)))
    for i in range(4):
        b[CRC_POS + i] = UInt8(Int((crc >> UInt32(24 - 8 * i)) & UInt32(0xFF)))


# -----------------------------------------------------------------------------
# Timestamps of a batch.
# -----------------------------------------------------------------------------
def test_first_and_max_timestamp() raises:
    var empty = List[KafkaRecord]()
    assert_equal(Int(record_batch_first_timestamp(empty)), 0, "empty first")
    assert_equal(Int(record_batch_max_timestamp(empty)), 0, "empty max")
    var last_max = _three(1000, 900, 1200)
    assert_equal(Int(record_batch_first_timestamp(last_max)), 1000, "first")
    assert_equal(Int(record_batch_max_timestamp(last_max)), 1200, "max last")
    var mid_max = _three(1000, 1300, 1200)
    assert_equal(Int(record_batch_max_timestamp(mid_max)), 1300, "max middle")
    var first_max = _three(1500, 1300, 1200)
    assert_equal(Int(record_batch_max_timestamp(first_max)), 1500, "max first")
    var one = List[KafkaRecord]()
    one.append(_rec("k", "v", -7, 0))
    assert_equal(Int(record_batch_max_timestamp(one)), -7, "one negative")


# -----------------------------------------------------------------------------
# The plaintext Record* array is exactly the bytes after recordsCount.
# -----------------------------------------------------------------------------
def test_plaintext_array_is_the_batch_records_section() raises:
    var recs = _three(1000, 900, 1200)
    var arr = encode_record_array_plaintext(recs, Int64(40))
    var batch = encode_record_batch_v2(recs, Int64(40))
    _assert_bytes_eq(
        arr, _slice(batch, RECORDS_POS, len(batch)), "array == batch records"
    )
    # Parsed back, the offsets are renumbered by position and the timestamps
    # resolved against the first record's.
    var back = parse_records_from_span(Span(arr), 3, Int64(40), Int64(1000))
    assert_equal(len(back), 3, "three records")
    for i in range(3):
        assert_equal(Int(back[i].offset), 40 + i, "offset by position")
        assert_equal(Int(back[i].timestamp), Int(recs[i].timestamp), "ts")
    _assert_bytes_eq(back[2].value.value(), _bytes("three"), "value 2")


def test_empty_record_lists_are_refused() raises:
    var empty = List[KafkaRecord]()
    var m1 = String("<accepted>")
    try:
        _ = encode_record_array_plaintext(empty, Int64(0))
    except e:
        m1 = String(e)
    assert_equal(m1, "encode_record_array_plaintext: empty record list")
    var m2 = String("<accepted>")
    try:
        _ = encode_record_batch_v2(empty, Int64(0))
    except e:
        m2 = String(e)
    assert_equal(m2, "encode_record_batch_v2: empty record list")


# -----------------------------------------------------------------------------
# The compressed-batch encoder.
# -----------------------------------------------------------------------------
def test_compressed_batch_golden() raises:
    var blob = _hex("01 80 ff")
    var got = encode_record_batch_v2_compressed(
        Span(blob), 3, Int64(1000), Int64(1200), Int64(40), Int32(2), 1
    )
    # Every field but the crc, by hand; batchLength = 4 + 1 + 4 + 40 + 3.
    var want = _hex(
        "00 00 00 00 00 00 00 28"  # baseOffset 40
        " 00 00 00 34"  # batchLength 52
        " ff ff ff ff"  # partitionLeaderEpoch -1
        " 02"  # magic
        " 00 00 00 00"  # crc, filled below
        " 00 01"  # attributes: gzip
        " 00 00 00 02"  # lastOffsetDelta
        " 00 00 00 00 00 00 03 e8"  # firstTimestamp 1000
        " 00 00 00 00 00 00 04 b0"  # maxTimestamp 1200
        " ff ff ff ff ff ff ff ff"  # producerId -1
        " ff ff"  # producerEpoch -1
        " ff ff ff ff"  # baseSequence -1
        " 00 00 00 03"  # recordsCount (logical)
        " 01 80 ff"  # the compressed Record* array
    )
    _reseal(want)
    _assert_bytes_eq(got, want, "compressed batch")

    # The server path accepts it (length and CRC check) and finds the blob.
    var dec = KafkaDecoder(Span(got))
    var h = split_record_batch_header(dec)
    assert_equal(h.compression_codec, 1, "codec")
    assert_equal(h.records_count, 3, "count")
    assert_equal(h.records_pos, RECORDS_POS, "records_pos")
    assert_equal(h.records_len, 3, "records_len")
    assert_equal(dec.remaining(), 0, "whole batch consumed")


def test_compressed_codec_range() raises:
    var blob = _hex("aa")
    for codec in range(1, 5):
        var b = encode_record_batch_v2_compressed(
            Span(blob), 1, Int64(5), Int64(5), Int64(0), Int32(0), codec
        )
        assert_equal(Int(b[ATTR_POS]), 0, "attributes hi")
        assert_equal(Int(b[ATTR_POS + 1]), codec, "attributes lo")
    for codec in [-1, 0, 5, 8]:
        var msg = String("<accepted>")
        try:
            _ = encode_record_batch_v2_compressed(
                Span(blob), 1, Int64(5), Int64(5), Int64(0), Int32(0), codec
            )
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "encode_record_batch_v2_compressed: invalid compression codec "
            + String(codec)
            + " (expected 1=gzip/2=snappy/3=lz4/4=zstd)",
        )
    for count in [0, -1]:
        var msg = String("<accepted>")
        try:
            _ = encode_record_batch_v2_compressed(
                Span(blob), count, Int64(5), Int64(5), Int64(0), Int32(0), 1
            )
        except e:
            msg = String(e)
        assert_equal(msg, "encode_record_batch_v2_compressed: empty record list")


def test_zero_dep_decoder_refuses_compressed() raises:
    var blob = _hex("01 80 ff")
    for codec in range(1, 5):
        var b = encode_record_batch_v2_compressed(
            Span(blob), 3, Int64(1000), Int64(1200), Int64(40), Int32(2), codec
        )
        var dec = KafkaDecoder(Span(b))
        var msg = String("<accepted>")
        try:
            _ = decode_record_batch_v2(dec)
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "decode_record_batch_v2: compression codec "
            + String(codec)
            + " not supported by the zero-dep decoder; use"
            " split_record_batch_header + decompress + parse_records_from_span",
        )


# -----------------------------------------------------------------------------
# Control batches (attributes bit 5) are refused by both entry points.
# -----------------------------------------------------------------------------
def test_control_batch_refused() raises:
    var b = encode_record_batch_v2(_three(1000, 900, 1200), Int64(0))
    b[ATTR_POS + 1] = UInt8(0x20)
    _reseal(b)
    var d1 = KafkaDecoder(Span(b))
    var m1 = String("<accepted>")
    try:
        _ = decode_record_batch_v2(d1)
    except e:
        m1 = String(e)
    assert_equal(m1, "decode_record_batch_v2: control batches not supported")
    var d2 = KafkaDecoder(Span(b))
    var m2 = String("<accepted>")
    try:
        _ = split_record_batch_header(d2)
    except e:
        m2 = String(e)
    assert_equal(m2, "split_record_batch_header: control batches not supported")
    # The transactional bit alone (bit 4) is no control batch.
    var t = encode_record_batch_v2(_three(1000, 900, 1200), Int64(0))
    t[ATTR_POS + 1] = UInt8(0x10)
    _reseal(t)
    var d3 = KafkaDecoder(Span(t))
    assert_equal(len(decode_record_batch_v2(d3).records), 3, "txn batch")


# -----------------------------------------------------------------------------
# parse_records_from_span refusals.
# -----------------------------------------------------------------------------
def test_parse_negative_count() raises:
    var arr = encode_record_array_plaintext(_three(1, 2, 3), Int64(0))
    var msg = String("<accepted>")
    try:
        _ = parse_records_from_span(Span(arr), -1, Int64(0), Int64(1))
    except e:
        msg = String(e)
    assert_equal(msg, "parse_records_from_span: negative recordsCount -1")


def test_parse_record_longer_than_bytes_left() raises:
    var one = List[KafkaRecord]()
    one.append(_rec("k", "v", 9, 0))
    var arr = encode_record_array_plaintext(one, Int64(0))
    # A second record whose length (zigzag 0x78 = 60) runs past the 3 bytes
    # that follow its length varint.
    var bad = arr.copy()
    var tail = _hex("78 00 00 00")
    for i in range(len(tail)):
        bad.append(tail[i])
    var msg = String("<accepted>")
    try:
        _ = parse_records_from_span(Span(bad), 2, Int64(0), Int64(9))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "parse_records_from_span: record 1 length 60 exceeds the 3 bytes left",
    )


# -----------------------------------------------------------------------------
# The zigzag varlong: 10 bytes is the longest a 64-bit value takes.
# -----------------------------------------------------------------------------
def test_varlong_ten_byte_limit() raises:
    var lo = Int64(-9223372036854775807) - Int64(1)
    var buf = List[UInt8]()
    put_varlong(buf, lo)
    assert_equal(len(buf), 10, "INT64_MIN takes 10 bytes")
    var dec = KafkaDecoder(Span(buf))
    assert_equal(Int(get_varlong(dec)), Int(lo), "INT64_MIN round-trips")
    var eleven = List[UInt8]()
    for _ in range(10):
        eleven.append(UInt8(0x80))
    eleven.append(UInt8(0x01))
    var dec11 = KafkaDecoder(Span(eleven))
    var msg = String("<accepted>")
    try:
        _ = get_varlong(dec11)
    except e:
        msg = String(e)
    assert_equal(
        msg, "komira_kafka_server.wire.record_v2: varlong exceeds 10 bytes"
    )


def main() raises:
    test_first_and_max_timestamp()
    test_plaintext_array_is_the_batch_records_section()
    test_empty_record_lists_are_refused()
    test_compressed_batch_golden()
    test_compressed_codec_range()
    test_zero_dep_decoder_refuses_compressed()
    test_control_batch_refused()
    test_parse_negative_count()
    test_parse_record_longer_than_bytes_left()
    test_varlong_ten_byte_limit()
    print("test_kafka_record_batch_edges: OK")
