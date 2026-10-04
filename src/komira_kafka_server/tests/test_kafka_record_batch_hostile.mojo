# Hostile and corrupt input to the v2 RecordBatch decoders: every decoder must
# refuse a batch that is truncated, corrupted, or internally inconsistent, and
# must never return records from one.
#
# The three entry points are swept together: `decode_record_batch_v2` (one batch
# off a decoder), `decode_record_batches` (a message set) and the server path
# `split_record_batch_header` + `parse_records_from_span`.
#
# What a broker must refuse (Kafka returns CORRUPT_MESSAGE for each):
#   * a batch shorter than its `batchLength`, or a message set ending in a
#     fragment too short to be a batch;
#   * any change to the bytes the CRC-32C covers (`attributes` to batch end),
#     and a wrong `batchLength`, `magic` or `crc`;
#   * a `batchLength` below the fixed 49-byte header that follows it;
#   * a record whose fields do not span exactly its declared length, a negative
#     record length, a null header key;
#   * a `recordsCount` that is negative or disagrees with the records present.
# What it must NOT refuse: `baseOffset` and `partitionLeaderEpoch` sit outside
# the CRC and are rewritten by the broker, so changing them is legal.
#
# Byte layout of the sample batch (see record_batch_v2.mojo's header):
#   0..7 baseOffset, 8..11 batchLength, 12..15 partitionLeaderEpoch, 16 magic,
#   17..20 crc, 21..22 attributes, 57..60 recordsCount, 61.. records.

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_server.wire.crc32c import crc32c_list
from komira_kafka_server.wire.record_batch_v2 import (
    KafkaHeader,
    KafkaRecord,
    decode_record_batch_v2,
    decode_record_batches,
    encode_record_batch_v2,
    get_varint,
    parse_records_from_span,
    split_record_batch_header,
)
from komira_kafka_server.wire.wire import KafkaDecoder


comptime CRC_POS = 17
comptime ATTR_POS = 21
comptime COUNT_POS = 57
comptime RECORDS_POS = 61


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _sample() raises -> List[UInt8]:
    """Three records: a key + value + one header; a null key; a null value
    with two headers, one with a null value."""
    var records = List[KafkaRecord]()
    var h0 = List[KafkaHeader]()
    h0.append(KafkaHeader(_bytes("hk"), Optional(_bytes("hv"))))
    records.append(
        KafkaRecord(
            Optional(_bytes("k1")), Optional(_bytes("hello")), h0^, Int64(1000), Int64(0)
        )
    )
    records.append(
        KafkaRecord(
            Optional[List[UInt8]](),
            Optional(_bytes("world")),
            List[KafkaHeader](),
            Int64(1003),
            Int64(1),
        )
    )
    var h2 = List[KafkaHeader]()
    h2.append(KafkaHeader(_bytes("a"), Optional(_bytes("b"))))
    h2.append(KafkaHeader(_bytes("c"), Optional[List[UInt8]]()))
    records.append(
        KafkaRecord(
            Optional(_bytes("k3")), Optional[List[UInt8]](), h2^, Int64(999), Int64(2)
        )
    )
    return encode_record_batch_v2(records, Int64(40))


def _empty_header_key_batch() raises -> List[UInt8]:
    var h = List[KafkaHeader]()
    h.append(KafkaHeader(List[UInt8](), Optional(_bytes("v"))))
    var records = List[KafkaRecord]()
    records.append(
        KafkaRecord(Optional(_bytes("k")), Optional(_bytes("v")), h^, Int64(5), Int64(0))
    )
    return encode_record_batch_v2(records, Int64(0))


def _reseal(mut b: List[UInt8]):
    """Recompute the CRC-32C over `attributes` to batch end, so a planted
    inconsistency is tested on its own rather than caught by the checksum."""
    var post = List[UInt8]()
    for i in range(ATTR_POS, len(b)):
        post.append(b[i])
    var crc = crc32c_list(post)
    for i in range(4):
        b[CRC_POS + i] = UInt8(Int((crc >> UInt32(24 - 8 * i)) & UInt32(0xFF)))


def _put_i32_be(mut b: List[UInt8], pos: Int, v: Int32):
    var u = v.cast[DType.uint32]()
    for i in range(4):
        b[pos + i] = UInt8(Int((u >> UInt32(24 - 8 * i)) & UInt32(0xFF)))


def _slice(b: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(b[i])
    return out^


def _decode_one(b: List[UInt8]) raises -> Tuple[Int, Int]:
    """(records, decoder position after the batch)."""
    var dec = KafkaDecoder(Span(b))
    var batch = decode_record_batch_v2(dec)
    return (len(batch.records), dec.pos())


def _split_and_parse(b: List[UInt8]) raises -> Tuple[Int, Int]:
    """(records, decoder position after the batch) via the server path."""
    var dec = KafkaDecoder(Span(b))
    var h = split_record_batch_header(dec)
    var blob = _slice(b, h.records_pos, h.records_pos + h.records_len)
    var recs = parse_records_from_span(
        Span(blob), h.records_count, h.base_offset, h.first_timestamp
    )
    return (len(recs), dec.pos())


def _refused_by_all(b: List[UInt8], what: String) raises:
    var r1 = False
    try:
        _ = _decode_one(b)
    except:
        r1 = True
    assert_true(r1, what + ": decode_record_batch_v2 accepted it")
    var r2 = False
    try:
        _ = decode_record_batches(Span(b))
    except:
        r2 = True
    assert_true(r2, what + ": decode_record_batches accepted it")
    var r3 = False
    try:
        _ = _split_and_parse(b)
    except:
        r3 = True
    assert_true(r3, what + ": split_record_batch_header + parse accepted it")


# -----------------------------------------------------------------------------
# The baseline: the sample decodes identically through every entry point.
# -----------------------------------------------------------------------------
def test_sample_decodes_through_every_entry_point() raises:
    var b = _sample()
    var one = _decode_one(b)
    assert_equal(one[0], 3)
    assert_equal(one[1], len(b), "decoder left mid-batch")
    var split = _split_and_parse(b)
    assert_equal(split[0], 3)
    assert_equal(split[1], len(b), "split left mid-batch")
    var recs = decode_record_batches(Span(b))
    assert_equal(len(recs), 3)
    assert_equal(Int(recs[0].offset), 40)
    assert_equal(Int(recs[2].offset), 42)
    assert_equal(Int(recs[2].timestamp), 999)
    assert_false(Bool(recs[2].value))
    assert_equal(len(recs[2].headers), 2)
    assert_false(Bool(recs[2].headers[1].value))
    var dec = KafkaDecoder(Span(b))
    var h = split_record_batch_header(dec)
    assert_equal(h.records_pos, RECORDS_POS)
    assert_equal(h.records_len, len(b) - RECORDS_POS)
    assert_equal(h.records_count, 3)
    # Two batches back to back are one message set.
    var two = b.copy()
    two.extend(Span(b))
    assert_equal(len(decode_record_batches(Span(two))), 6)
    # An empty message set is empty, not an error.
    var empty = List[UInt8]()
    assert_equal(len(decode_record_batches(Span(empty))), 0)


# -----------------------------------------------------------------------------
# Truncation.
# -----------------------------------------------------------------------------
def test_every_truncation_is_refused() raises:
    var b = _sample()
    for cut in range(1, len(b)):
        _refused_by_all(_slice(b, 0, cut), String("cut at ") + String(cut))


def test_trailing_fragment_after_a_batch_is_refused() raises:
    var b = _sample()
    for extra in range(1, 12):
        var tail = b.copy()
        for i in range(extra):
            tail.append(b[i])
        var refused = False
        try:
            _ = decode_record_batches(Span(tail))
        except:
            refused = True
        assert_true(refused, String(extra) + "-byte fragment accepted")


# -----------------------------------------------------------------------------
# Corruption: the CRC covers attributes..end; batchLength, magic and crc are
# checked; baseOffset and partitionLeaderEpoch are free.
# -----------------------------------------------------------------------------
def test_every_checked_byte_flip_is_refused() raises:
    var b = _sample()
    for pos in range(8, len(b)):
        if pos >= 12 and pos < 16:
            continue  # partitionLeaderEpoch: outside the CRC, see below
        for bit in [0, 3, 7]:
            var c = b.copy()
            c[pos] = c[pos] ^ (UInt8(1) << UInt8(bit))
            _refused_by_all(
                c, String("flip byte ") + String(pos) + " bit " + String(bit)
            )


def test_uncovered_header_fields_are_free() raises:
    var b = _sample()
    var c = b.copy()
    c[7] = c[7] ^ UInt8(1)  # baseOffset 40 -> 41
    c[13] = c[13] ^ UInt8(0x55)  # partitionLeaderEpoch
    var recs = decode_record_batches(Span(c))
    assert_equal(len(recs), 3)
    assert_equal(Int(recs[0].offset), 41)


def test_batch_length_below_header_is_refused() raises:
    var b = _sample()
    for length in [0, 9, 48]:
        var c = b.copy()
        _put_i32_be(c, 8, Int32(length))
        _refused_by_all(c, String("batchLength ") + String(length))
    var neg = b.copy()
    _put_i32_be(neg, 8, Int32(-1))
    _refused_by_all(neg, String("batchLength -1"))


# -----------------------------------------------------------------------------
# Internally inconsistent batches with a VALID CRC (resealed), so each check is
# exercised on its own.
# -----------------------------------------------------------------------------
def test_record_length_must_match_its_fields() raises:
    var b = _sample()
    var zz = Int(b[RECORDS_POS])  # one-byte zigzag varint: 2 * length
    assert_true(zz < 128 and zz % 2 == 0)
    for delta in [-2, 2]:
        var c = b.copy()
        c[RECORDS_POS] = UInt8(zz + delta)
        _reseal(c)
        _refused_by_all(c, String("record length off by ") + String(delta // 2))
    var neg = b.copy()
    neg[RECORDS_POS] = UInt8(1)  # zigzag(-1)
    _reseal(neg)
    _refused_by_all(neg, String("record length -1"))


def test_records_count_must_match_the_records() raises:
    var b = _sample()
    for count in [-1, 0, 2, 4, 1000000]:
        var c = b.copy()
        _put_i32_be(c, COUNT_POS, Int32(count))
        _reseal(c)
        _refused_by_all(c, String("recordsCount ") + String(count))


def test_null_header_key_is_refused() raises:
    var b = _empty_header_key_batch()
    assert_equal(_decode_one(b)[0], 1)
    # The header key length is the only 0x00 varint after the header count:
    # record = len attr tsDelta offDelta keyLen 'k' valLen 'v' hCount hkLen ...
    var hk = RECORDS_POS + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1
    assert_equal(Int(b[hk - 1]), 2, "header count")
    assert_equal(Int(b[hk]), 0, "header key length")
    var c = b.copy()
    c[hk] = UInt8(1)  # zigzag(-1): a null header key
    _reseal(c)
    _refused_by_all(c, String("null header key"))


def test_overlong_varint_is_refused() raises:
    var five = List[UInt8]()
    for _ in range(5):
        five.append(UInt8(0x80))
    five.append(UInt8(0x01))
    var dec = KafkaDecoder(Span(five))
    var refused = False
    try:
        _ = get_varint(dec)
    except:
        refused = True
    assert_true(refused, "a 6-byte varint was accepted")


# -----------------------------------------------------------------------------
# The exact refusal messages. Each of these four checks is backed up by a later
# one (a decoder underflow, or `_parse_records`' own negative-count check), so a
# test asserting only "refused" stays green with the check deleted. The message
# names the failure; these pin which check fired.
# -----------------------------------------------------------------------------
def _refusal_one(b: List[UInt8]) -> String:
    try:
        _ = _decode_one(b)
    except e:
        return String(e)
    return String("<accepted>")


def _refusal_set(b: List[UInt8]) -> String:
    try:
        _ = decode_record_batches(Span(b))
    except e:
        return String(e)
    return String("<accepted>")


def _refusal_split(b: List[UInt8]) -> String:
    try:
        _ = _split_and_parse(b)
    except e:
        return String(e)
    return String("<accepted>")


def test_fragment_tail_message() raises:
    var b = _sample()
    var tail = b.copy()
    for i in range(5):
        tail.append(b[i])
    assert_equal(
        _refusal_set(tail),
        "decode_record_batches: a 5-byte fragment follows the last whole batch"
        " (truncated message set)",
    )


def test_batch_length_past_the_end_message() raises:
    var b = _sample()
    var c = _slice(b, 0, len(b) - 1)
    var declared = String(len(b) - 12)
    var left = String(len(b) - 13)
    assert_equal(
        _refusal_one(c),
        "decode_record_batch_v2: truncated batch: batchLength "
        + declared
        + " but only "
        + left
        + " bytes remain",
    )
    assert_equal(
        _refusal_set(c),
        "decode_record_batch_v2: truncated batch: batchLength "
        + declared
        + " but only "
        + left
        + " bytes remain",
    )
    assert_equal(
        _refusal_split(c),
        "split_record_batch_header: truncated batch: batchLength "
        + declared
        + " but only "
        + left
        + " bytes remain",
    )


def test_batch_length_below_header_message() raises:
    var c = _sample()
    _put_i32_be(c, 8, Int32(48))
    assert_equal(
        _refusal_one(c),
        "decode_record_batch_v2: batchLength 48 is below the 49-byte v2 header"
        " that follows it (corrupt batch)",
    )
    assert_equal(
        _refusal_split(c),
        "split_record_batch_header: batchLength 48 is below the 49-byte v2"
        " header that follows it (corrupt batch)",
    )


def test_negative_records_count_message() raises:
    var c = _sample()
    _put_i32_be(c, COUNT_POS, Int32(-1))
    _reseal(c)
    # "(corrupt batch)" is the header check's spelling; `_parse_records`' own
    # check omits it, so this pins that the header check fired.
    assert_equal(
        _refusal_one(c),
        "decode_record_batch_v2: negative recordsCount -1 (corrupt batch)",
    )
    assert_equal(
        _refusal_split(c),
        "split_record_batch_header: negative recordsCount -1 (corrupt batch)",
    )


def main() raises:
    test_sample_decodes_through_every_entry_point()
    test_every_truncation_is_refused()
    test_trailing_fragment_after_a_batch_is_refused()
    test_every_checked_byte_flip_is_refused()
    test_uncovered_header_fields_are_free()
    test_batch_length_below_header_is_refused()
    test_record_length_must_match_its_fields()
    test_records_count_must_match_the_records()
    test_null_header_key_is_refused()
    test_overlong_varint_is_refused()
    test_fragment_tail_message()
    test_batch_length_past_the_end_message()
    test_batch_length_below_header_message()
    test_negative_records_count_message()
    print("test_kafka_record_batch_hostile: OK")
