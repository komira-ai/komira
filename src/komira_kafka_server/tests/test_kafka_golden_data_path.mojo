# The data-path codecs: Produce request (v3..v7 shape), Fetch request v4 and
# v5/v6, Fetch response v6 and ListOffsets request v1 and v2, against
# reference bytes written by hand from the Apache Kafka message schemas
# (ProduceRequest.json, FetchRequest.json, FetchResponse.json,
# ListOffsetsRequest.json at tag 3.9.0; provenance in GOLDENS.md). Also the
# `copy` of every data-path value type.
#
# Requests follow GOLDENS.md: decode, assert every field, check the decoder
# consumed the message exactly, and check every strict prefix is refused.
# Record bytes carry values of 0x80 and above, so a signed/unsigned slip in
# the byte copy shows.

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_server.wire.produce_fetch import (
    FetchPartitionRequest,
    FetchPartitionResult,
    FetchTopicRequest,
    FetchTopicResult,
    ListOffsetsPartitionRequest,
    ListOffsetsPartitionResult,
    ListOffsetsTopicRequest,
    ListOffsetsTopicResult,
    ProducePartitionData,
    ProducePartitionResult,
    ProduceTopicData,
    ProduceTopicResult,
    decode_fetch_request,
    decode_list_offsets_request,
    decode_produce_request,
    encode_fetch_response_v6,
)
from komira_kafka_server.wire.wire import KafkaDecoder


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


def _assert_bytes_eq(got: List[UInt8], want: List[UInt8], ctx: String) raises:
    assert_equal(len(got), len(want), ctx + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), ctx + ": byte " + String(i))


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return out^


# -----------------------------------------------------------------------------
# Produce request.
# -----------------------------------------------------------------------------
comptime PRODUCE = (
    "ff ff"  # transactional_id null
    " ff ff"  # acks -1
    " 00 00 75 30"  # timeout_ms 30000
    " 00 00 00 02"  # topic_data: 2
    " 00 01 61"  # "a"
    " 00 00 00 05"  # partition_data: 5
    " 00 00 00 00 | 00 00 00 03 01 80 ff"  # 0: three bytes
    " 00 00 00 01 | ff ff ff ff"  # 1: null records
    " 00 00 00 02 | 00 00 00 00"  # 2: empty records
    " 00 00 00 03 | 00 00 00 01 fe"  # 3: one byte
    " 00 00 00 04 | ff ff ff fb"  # 4: length -5, read as null
    " 00 02 62 62"  # "bb"
    " 00 00 00 00"  # partition_data: 0
)


def test_produce_request() raises:
    var b = _hex(PRODUCE)
    var dec = KafkaDecoder(Span(b))
    var req = decode_produce_request(dec)
    assert_equal(dec.remaining(), 0, "consumed")
    assert_false(Bool(req.transactional_id), "txn id null")
    assert_equal(Int(req.acks), -1, "acks")
    assert_equal(Int(req.timeout_ms), 30000, "timeout")
    assert_equal(len(req.topics), 2, "topics")
    ref t = req.topics[0]
    assert_equal(t.name, String("a"), "topic 0")
    assert_equal(len(t.partitions), 5, "partitions")
    for i in range(5):
        assert_equal(Int(t.partitions[i].index), i, "index")
    _assert_bytes_eq(t.partitions[0].records, _hex("01 80 ff"), "records 0")
    assert_equal(len(t.partitions[1].records), 0, "null records read empty")
    assert_equal(len(t.partitions[2].records), 0, "empty records")
    _assert_bytes_eq(t.partitions[3].records, _hex("fe"), "records 3")
    # Any negative length is null, as in Kafka's generated reader
    # (`if (length < 0)` reads null for a nullable field), not only -1.
    assert_equal(len(t.partitions[4].records), 0, "length -5 reads null")
    assert_equal(req.topics[1].name, String("bb"), "topic 1")
    assert_equal(len(req.topics[1].partitions), 0, "no partitions")
    for cut in range(len(b)):
        var short = _prefix(b, cut)
        var d = KafkaDecoder(Span(short))
        var refused = False
        try:
            _ = decode_produce_request(d)
        except:
            refused = True
        assert_true(refused, "prefix " + String(cut) + " accepted")


def test_produce_request_transactional() raises:
    var b = _hex("00 03 74 78 6e | 00 01 | 00 00 00 05 | 00 00 00 00")
    var dec = KafkaDecoder(Span(b))
    var req = decode_produce_request(dec)
    assert_equal(dec.remaining(), 0, "consumed")
    assert_equal(req.transactional_id.value(), String("txn"), "txn id")
    assert_equal(Int(req.acks), 1, "acks")
    assert_equal(Int(req.timeout_ms), 5, "timeout")
    assert_equal(len(req.topics), 0, "no topics")


# -----------------------------------------------------------------------------
# Fetch request: log_start_offset is in the partition from v5.
# -----------------------------------------------------------------------------
def _fetch_golden(version: Int) -> String:
    var log_start = String(" 00 00 00 00 00 00 00 07") if version >= 5 else String("")
    var s = String("ff ff ff ff")  # replica_id -1
    s += " 00 00 01 f4"  # max_wait_ms 500
    s += " 00 00 00 01"  # min_bytes 1
    s += " 00 10 00 00"  # max_bytes
    s += " 01"  # isolation_level read_committed
    s += " 00 00 00 01"  # topics: 1
    s += " 00 01 61 | 00 00 00 02"  # "a", 2 partitions
    s += " 00 00 00 00 | 00 00 00 00 00 00 00 2a" + log_start + " | 00 10 00 00"
    s += " 00 00 00 05 | 81 02 03 04 05 06 07 08" + log_start + " | 00 00 00 10"
    return s


def test_fetch_request_v4_to_v6() raises:
    for v in range(4, 7):
        var b = _hex(_fetch_golden(v))
        var dec = KafkaDecoder(Span(b))
        var req = decode_fetch_request(dec, Int16(v))
        var ctx = "v" + String(v)
        assert_equal(dec.remaining(), 0, ctx + " consumed")
        assert_equal(Int(req.max_wait_ms), 500, ctx)
        assert_equal(Int(req.min_bytes), 1, ctx)
        assert_equal(Int(req.isolation_level), 1, ctx)
        assert_equal(len(req.topics), 1, ctx)
        ref t = req.topics[0]
        assert_equal(t.name, String("a"), ctx)
        assert_equal(len(t.partitions), 2, ctx)
        assert_equal(Int(t.partitions[0].index), 0, ctx)
        assert_equal(Int(t.partitions[0].fetch_offset), 42, ctx)
        assert_equal(Int(t.partitions[0].max_bytes), 0x100000, ctx)
        assert_equal(Int(t.partitions[1].index), 5, ctx)
        assert_equal(
            Int(t.partitions[1].fetch_offset), -9150748177064392952, ctx
        )
        assert_equal(Int(t.partitions[1].max_bytes), 16, ctx)
        for cut in range(len(b)):
            var short = _prefix(b, cut)
            var d = KafkaDecoder(Span(short))
            var refused = False
            try:
                _ = decode_fetch_request(d, Int16(v))
            except:
                refused = True
            assert_true(refused, ctx + " prefix " + String(cut) + " accepted")


# -----------------------------------------------------------------------------
# Fetch response v6.
# -----------------------------------------------------------------------------
def test_fetch_response_v6() raises:
    var parts = List[FetchPartitionResult]()
    parts.append(FetchPartitionResult(Int32(0), Int16(0), Int64(10), _hex("80 ff 01")))
    parts.append(FetchPartitionResult(Int32(3), Int16(1), Int64(0), List[UInt8]()))
    var topics = List[FetchTopicResult]()
    topics.append(FetchTopicResult(String("a"), parts^))
    var got = encode_fetch_response_v6(Int32(9), topics)
    var want = _hex(
        "00 00 00 09"  # correlation_id
        " 00 00 00 00"  # throttle_time_ms
        " 00 00 00 01 | 00 01 61 | 00 00 00 02"  # "a", 2 partitions
        " 00 00 00 00 | 00 00"  # p0, no error
        " 00 00 00 00 00 00 00 0a"  # high_watermark 10
        " 00 00 00 00 00 00 00 0a"  # last_stable_offset
        " 00 00 00 00 00 00 00 00"  # log_start_offset
        " 00 00 00 00"  # aborted_transactions: 0
        " 00 00 00 03 80 ff 01"  # records
        " 00 00 00 03 | 00 01"  # p3, OFFSET_OUT_OF_RANGE
        " 00 00 00 00 00 00 00 00 | 00 00 00 00 00 00 00 00"
        " 00 00 00 00 00 00 00 00 | 00 00 00 00"
        " 00 00 00 00"  # records: empty
    )
    _assert_bytes_eq(got, want, "fetch v6")


# -----------------------------------------------------------------------------
# ListOffsets request: isolation_level from v2.
# -----------------------------------------------------------------------------
def test_list_offsets_request_v1_v2() raises:
    for v in range(1, 3):
        var s = String("ff ff ff ff")  # replica_id
        if v >= 2:
            s += " 00"  # isolation_level
        s += " 00 00 00 01 | 00 01 61 | 00 00 00 02"
        s += " 00 00 00 00 | ff ff ff ff ff ff ff fe"  # p0 earliest
        s += " 00 00 00 01 | ff ff ff ff ff ff ff ff"  # p1 latest
        var b = _hex(s)
        var dec = KafkaDecoder(Span(b))
        var req = decode_list_offsets_request(dec, Int16(v))
        var ctx = "v" + String(v)
        assert_equal(dec.remaining(), 0, ctx + " consumed")
        assert_equal(len(req.topics), 1, ctx)
        ref t = req.topics[0]
        assert_equal(t.name, String("a"), ctx)
        assert_equal(len(t.partitions), 2, ctx)
        assert_equal(Int(t.partitions[0].index), 0, ctx)
        assert_equal(Int(t.partitions[0].timestamp), -2, ctx)
        assert_equal(Int(t.partitions[1].index), 1, ctx)
        assert_equal(Int(t.partitions[1].timestamp), -1, ctx)
        for cut in range(len(b)):
            var short = _prefix(b, cut)
            var d = KafkaDecoder(Span(short))
            var refused = False
            try:
                _ = decode_list_offsets_request(d, Int16(v))
            except:
                refused = True
            assert_true(refused, ctx + " prefix " + String(cut) + " accepted")


# -----------------------------------------------------------------------------
# copy() of each data-path value type: equal fields, its own lists.
# -----------------------------------------------------------------------------
def test_copies() raises:
    var pp = ProducePartitionData(Int32(4), _hex("01 02"))
    var ppc = pp.copy()
    pp.records[0] = UInt8(9)
    assert_equal(Int(ppc.index), 4, "produce partition index")
    _assert_bytes_eq(ppc.records, _hex("01 02"), "produce partition records")

    var pps = List[ProducePartitionData]()
    pps.append(ProducePartitionData(Int32(1), _hex("aa")))
    var pt = ProduceTopicData(String("p"), pps^)
    var ptc = pt.copy()
    assert_equal(ptc.name, String("p"), "produce topic name")
    assert_equal(len(ptc.partitions), 1, "produce topic partitions")
    assert_equal(Int(ptc.partitions[0].index), 1, "produce topic partition")

    var prs = List[ProducePartitionResult]()
    prs.append(ProducePartitionResult(Int32(2), Int16(6), Int64(77)))
    var pr = ProduceTopicResult(String("r"), prs^)
    var prc = pr.copy()
    assert_equal(prc.name, String("r"), "produce result name")
    assert_equal(len(prc.partitions), 1, "produce result partitions")
    assert_equal(Int(prc.partitions[0].base_offset), 77, "base_offset")

    var fps = List[FetchPartitionRequest]()
    fps.append(FetchPartitionRequest(Int32(3), Int64(8), Int32(9)))
    var ft = FetchTopicRequest(String("f"), fps^)
    var ftc = ft.copy()
    assert_equal(ftc.name, String("f"), "fetch topic name")
    assert_equal(len(ftc.partitions), 1, "fetch topic partitions")
    assert_equal(Int(ftc.partitions[0].fetch_offset), 8, "fetch offset")

    var fr = FetchPartitionResult(Int32(5), Int16(1), Int64(12), _hex("80"))
    var frc = fr.copy()
    fr.records[0] = UInt8(0)
    assert_equal(Int(frc.index), 5, "fetch result index")
    assert_equal(Int(frc.error_code), 1, "fetch result error")
    assert_equal(Int(frc.high_watermark), 12, "fetch result hw")
    _assert_bytes_eq(frc.records, _hex("80"), "fetch result records")

    var frs = List[FetchPartitionResult]()
    frs.append(FetchPartitionResult(Int32(6), Int16(0), Int64(1), _hex("01")))
    var ftr = FetchTopicResult(String("g"), frs^)
    var ftrc = ftr.copy()
    assert_equal(ftrc.name, String("g"), "fetch topic result name")
    assert_equal(len(ftrc.partitions), 1, "fetch topic result partitions")
    assert_equal(Int(ftrc.partitions[0].index), 6, "fetch topic result part")

    var lps = List[ListOffsetsPartitionRequest]()
    lps.append(ListOffsetsPartitionRequest(Int32(7), Int64(-2)))
    var lt = ListOffsetsTopicRequest(String("l"), lps^)
    var ltc = lt.copy()
    assert_equal(ltc.name, String("l"), "list offsets name")
    assert_equal(len(ltc.partitions), 1, "list offsets partitions")
    assert_equal(Int(ltc.partitions[0].timestamp), -2, "list offsets ts")

    var lrs = List[ListOffsetsPartitionResult]()
    lrs.append(ListOffsetsPartitionResult(Int32(8), Int16(0), Int64(-1), Int64(42)))
    var lr = ListOffsetsTopicResult(String("m"), lrs^)
    var lrc = lr.copy()
    assert_equal(lrc.name, String("m"), "list offsets result name")
    assert_equal(len(lrc.partitions), 1, "list offsets result partitions")
    assert_equal(Int(lrc.partitions[0].offset), 42, "list offsets result offset")


def main() raises:
    test_produce_request()
    test_produce_request_transactional()
    test_fetch_request_v4_to_v6()
    test_fetch_response_v6()
    test_list_offsets_request_v1_v2()
    test_copies()
    print("test_kafka_golden_data_path: OK")
