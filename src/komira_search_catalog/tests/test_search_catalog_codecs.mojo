# =============================================================================
# test_search_catalog_codecs.mojo
#   The catalog's byte codecs refuse every corrupt body they can detect, and
#   the record helpers keep their contracts. No store is involved.
# =============================================================================
#
#   1. test_split_summary_round_trips_every_slot: a merged summary with every
#      reserved slot filled decodes field for field, and an ingest summary
#      encodes without the compaction slot.
#   2. test_merge_input_at_refuses_out_of_range: -1, -3, n and n + 1 raise;
#      every index in range returns its own 16 bytes.
#   3. test_decode_refuses_a_short_header: bodies of 0 to 16 bytes raise the
#      header error; 17 bytes reach the first i64 and raise its truncation.
#   4. test_decode_refuses_truncation_at_every_offset: a merged body cut at
#      every length from 17 up raises, except the cuts that end exactly at a
#      slot boundary before the compaction slot (a body of that length is a
#      valid ingest body). A cut that leaves 1 to 7 bytes of merge_ops raises
#      the truncated-i64 error at the start of the compaction slot, so a
#      merged split never decodes as an ingest split (komira-ai/komira#1372).
#      An ingest body with 1 to 7 bytes appended raises the same error.
#   5. test_decode_refuses_bad_length_prefixes: a length prefix with its top
#      bit set is negative and raises; one with a high byte set but no sign bit
#      runs past the body and raises. A prefix near Int64.max is not tested
#      here: it wraps the bounds check (komira-ai/komira#1370).
#   6. test_decode_refuses_merge_inputs_not_a_multiple_of_16.
#   7. test_generation_record_codecs_refuse_corrupt_bodies: the floor, bumps
#      and retired-shards codecs refuse an empty body, an unknown version, a
#      truncated value and a negative entry count, and round-trip good ones.
#   8. test_retired_shards_raise_to_only_raises: a recorded generation only
#      goes up, and ids compare by exact bytes.
#   9. test_chunk_seq_of_reads_only_chunk_keys: the reaper's key parser
#      returns a sequence number only for `<lineage>/manifest/<digits>.chunk`.
#
# Strings in these tests are ASCII: a non-ASCII string does not round-trip
# (komira-ai/komira#1371), and no test here encodes that answer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_search_catalog.split_summary import (
    SplitSummary,
    decode_split_summary,
    encode_split_summary,
    make_merged_split_summary,
    make_split_summary,
)
from komira_search_catalog.generation import (
    RetiredShards,
    decode_generation_bumps,
    decode_generation_floor,
    decode_retired_shards,
    encode_generation_bumps,
    encode_generation_floor,
    encode_retired_shards,
)
from komira_search_catalog.shard_reaper import _chunk_seq_of


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _same16(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _bytes(n: Int, seed: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((seed + i * 31) & 0xFF))
    return out^


def _inputs(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(n):
        var u = _uuid(100 + k)
        for i in range(16):
            out.append(u[i])
    return out^


def _ingest() -> SplitSummary:
    return make_split_summary(
        _uuid(1),
        Int64(5),
        Int64(4096),
        Int64(10),
        Int64(14),
        String("logs"),
        String("body"),
        String("index/logs/splits/s-1.split"),
    )


def _merged(n_inputs: Int) -> SplitSummary:
    var s = make_merged_split_summary(
        _uuid(2),
        Int64(-7),
        Int64(0x0102030405060708),
        Int64(-0x7FFFFFFFFFFFFFFF),
        Int64(0x7FFFFFFFFFFFFFFF),
        String("idx"),
        String("fld"),
        String("index/idx/splits/m.split"),
        Int64(3),
        _inputs(n_inputs),
    )
    s.delete_gen_ref = String("index/idx/deletes/g-9")
    s.bloom_sketch = _bytes(5, 3)
    s.minmax_sketch = _bytes(9, 200)
    s.cardinality = Int64(-0x0100000000000000)
    return s^


def _put_le(mut b: List[UInt8], off: Int, v: UInt64):
    for i in range(8):
        b[off + i] = UInt8((v >> UInt64(8 * i)) & UInt64(0xFF))


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return out^


def _raise_message(body: List[UInt8]) -> String:
    """The decode error's message, or "" when the body decodes."""
    try:
        _ = decode_split_summary(body)
    except e:
        return String(e)
    return String("")


# The fixed prefix: version, uuid, five i64 fields.
comptime _FIXED = 1 + 16 + 5 * 8


def test_split_summary_round_trips_every_slot() raises:
    var m = _merged(2)
    var d = decode_split_summary(encode_split_summary(m))
    assert_equal(Int(d.version), Int(m.version))
    assert_true(_same16(d.split_uuid, m.split_uuid), "uuid")
    assert_equal(d.doc_count, m.doc_count)
    assert_equal(d.byte_size, m.byte_size)
    assert_equal(d.min_doc_id, m.min_doc_id)
    assert_equal(d.max_doc_id, m.max_doc_id)
    assert_equal(d.cardinality, m.cardinality)
    assert_equal(d.index_name, m.index_name)
    assert_equal(d.field_name, m.field_name)
    assert_equal(d.object_key, m.object_key)
    assert_equal(d.delete_gen_ref, m.delete_gen_ref)
    assert_true(_same_bytes(d.bloom_sketch, m.bloom_sketch), "bloom")
    assert_true(_same_bytes(d.minmax_sketch, m.minmax_sketch), "minmax")
    assert_equal(d.merge_ops, Int64(3))
    assert_true(d.is_merged(), "merged")
    assert_equal(d.num_merge_inputs(), 2)
    assert_true(
        _same_bytes(d.merge_input_uuids, m.merge_input_uuids), "inputs"
    )

    # An ingest split carries no compaction slot: its encoding is the
    # merged layout minus [merge_ops][len][inputs].
    var i = _ingest()
    var b = encode_split_summary(i)
    # Six length prefixes; "logs", "body" and the 27-byte object key.
    assert_equal(len(b), _FIXED + 6 * 8 + 4 + 4 + 27, "no compaction slot")
    var di = decode_split_summary(b)
    assert_false(di.is_merged(), "an ingest split is not merged")
    assert_equal(di.num_merge_inputs(), 0)
    assert_equal(di.object_key, i.object_key)


def test_merge_input_at_refuses_out_of_range() raises:
    var m = _merged(3)
    for k in range(3):
        assert_true(_same16(m.merge_input_at(k), _uuid(100 + k)), "input k")
    var bad = List[Int]()
    bad.append(-1)
    bad.append(-3)
    bad.append(3)
    bad.append(4)
    for j in range(len(bad)):
        var msg = String("")
        try:
            _ = m.merge_input_at(bad[j])
        except e:
            msg = String(e)
        assert_true(
            msg.find("index " + String(bad[j]) + " out of range [0, 3)") >= 0,
            "index " + String(bad[j]) + " raised: " + msg,
        )
    var none = String("")
    try:
        _ = _ingest().merge_input_at(0)
    except e:
        none = String(e)
    assert_true(none.find("out of range [0, 0)") >= 0, "no inputs: " + none)


def test_decode_refuses_a_short_header() raises:
    var b = encode_split_summary(_ingest())
    for n in range(17):
        var msg = _raise_message(_prefix(b, n))
        assert_true(
            msg.find("body too short for header (" + String(n) + " < 17") >= 0,
            "length " + String(n) + ": " + msg,
        )
    # 17 bytes: the header is whole, the first i64 is not.
    var msg = _raise_message(_prefix(b, 17))
    assert_true(
        msg.find("truncated i64 at offset 17") >= 0, "length 17: " + msg
    )


def test_decode_refuses_truncation_at_every_offset() raises:
    var m = _merged(2)
    var b = encode_split_summary(m)
    # Where each slot ends, so the valid ingest prefixes are known.
    var ends = List[Int]()
    var off = _FIXED
    var slots = List[Int]()
    slots.append(m.index_name.byte_length())
    slots.append(m.field_name.byte_length())
    slots.append(m.object_key.byte_length())
    slots.append(m.delete_gen_ref.byte_length())
    slots.append(len(m.bloom_sketch))
    slots.append(len(m.minmax_sketch))
    for k in range(len(slots)):
        off += 8 + slots[k]
        ends.append(off)
    var ingest_end = ends[len(ends) - 1]
    var refused = 0
    var cut_in_merge_ops = 0
    for n in range(17, len(b)):
        var msg = _raise_message(_prefix(b, n))
        if n > ingest_end and n < ingest_end + 8:
            # komira-ai/komira#1372: 1 to 7 bytes of merge_ops must not
            # decode as an ingest split that lost its merge inputs.
            assert_true(
                msg.find("truncated i64 at offset " + String(ingest_end))
                >= 0,
                "cut at " + String(n) + " inside merge_ops: " + msg,
            )
            cut_in_merge_ops += 1
        if n == ingest_end:
            assert_equal(msg, String(""), "the ingest prefix decodes")
            continue
        assert_true(
            msg.find("corrupt)") >= 0,
            "cut at " + String(n) + " of " + String(len(b)) + ": " + msg,
        )
        refused += 1
    # Every cut from 17 to len - 1 refused but the ingest prefix, and the
    # seven cuts inside merge_ops among them.
    assert_equal(refused, len(b) - 17 - 1)
    assert_equal(cut_in_merge_ops, 7)
    # An ingest body followed by 1 to 7 stray bytes is refused, not decoded
    # with the bytes ignored.
    var ib = encode_split_summary(_ingest())
    var ingest_len = len(ib)
    for extra in range(1, 8):
        ib.append(UInt8(9))
        var m_extra = _raise_message(ib)
        assert_true(
            m_extra.find("truncated i64 at offset " + String(ingest_len))
            >= 0,
            "ingest body + " + String(extra) + " bytes: " + m_extra,
        )
    # The cut that leaves the merge_ops field but not its inputs' length.
    var msg = _raise_message(_prefix(b, ingest_end + 8))
    assert_true(
        msg.find("truncated i64 at offset " + String(ingest_end + 8)) >= 0,
        msg,
    )
    # One byte short of the inputs.
    msg = _raise_message(_prefix(b, len(b) - 1))
    assert_true(
        msg.find(
            "truncated length-prefixed field ("
            + String(len(b))
            + " > "
            + String(len(b) - 1)
        )
        >= 0,
        msg,
    )


def test_decode_refuses_bad_length_prefixes() raises:
    var base = encode_split_summary(_ingest())
    # The length field of each string and sketch slot, in order.
    var fields = List[Int]()
    var i = _ingest()
    var off = _FIXED
    var sizes = List[Int]()
    sizes.append(i.index_name.byte_length())
    sizes.append(i.field_name.byte_length())
    sizes.append(i.object_key.byte_length())
    sizes.append(i.delete_gen_ref.byte_length())
    sizes.append(len(i.bloom_sketch))
    sizes.append(len(i.minmax_sketch))
    for k in range(len(sizes)):
        fields.append(off)
        off += 8 + sizes[k]
    var negatives = List[UInt64]()
    negatives.append(UInt64(0xFFFFFFFFFFFFFFFF))  # -1
    negatives.append(UInt64(0x8000000000000000))  # Int64.min
    negatives.append(UInt64(0x80000000000000FF))
    var too_long = List[UInt64]()
    too_long.append(UInt64(0x0100000000000000))  # high byte, no sign bit
    too_long.append(UInt64(0x0000000100000000))
    too_long.append(UInt64(0x00000000000000FF))
    for f in range(len(fields)):
        for k in range(len(negatives)):
            var b = base.copy()
            _put_le(b, fields[f], negatives[k])
            var msg = _raise_message(b)
            assert_true(
                msg.find("negative length-prefix (corrupt)") >= 0,
                "field " + String(f) + " value " + String(k) + ": " + msg,
            )
        for k in range(len(too_long)):
            var b = base.copy()
            _put_le(b, fields[f], too_long[k])
            var msg = _raise_message(b)
            assert_true(
                msg.find("truncated length-prefixed field") >= 0,
                "field " + String(f) + " value " + String(k) + ": " + msg,
            )


def test_decode_refuses_merge_inputs_not_a_multiple_of_16() raises:
    var bad = List[Int]()
    bad.append(1)
    bad.append(8)
    bad.append(15)
    bad.append(17)
    bad.append(24)
    for k in range(len(bad)):
        var m = _merged(0)
        m.merge_input_uuids = _bytes(bad[k], k)
        var msg = _raise_message(encode_split_summary(m))
        assert_true(
            msg.find(
                "merge_input_uuids length "
                + String(bad[k])
                + " is not a multiple of 16"
            )
            >= 0,
            String(bad[k]) + ": " + msg,
        )
    for n in range(3):
        var d = decode_split_summary(encode_split_summary(_merged(n)))
        assert_equal(d.num_merge_inputs(), n)


def test_generation_record_codecs_refuse_corrupt_bodies() raises:
    var values = List[Int64]()
    values.append(Int64(0))
    values.append(Int64(1))
    values.append(Int64(0x7FFFFFFFFFFFFFFF))
    values.append(Int64(-0x0100000000000000))
    for k in range(len(values)):
        assert_equal(
            decode_generation_floor(encode_generation_floor(values[k])),
            values[k],
        )
        assert_equal(
            decode_generation_bumps(encode_generation_bumps(values[k])),
            values[k],
        )
    # Empty, unknown version (0 and 2), and a truncated value.
    var bodies = List[List[UInt8]]()
    bodies.append(List[UInt8]())
    var v0 = encode_generation_floor(Int64(5))
    v0[0] = UInt8(0)
    bodies.append(v0^)
    var v2 = encode_generation_floor(Int64(5))
    v2[0] = UInt8(2)
    bodies.append(v2^)
    for k in range(len(bodies)):
        var floor_msg = String("")
        try:
            _ = decode_generation_floor(bodies[k])
        except e:
            floor_msg = String(e)
        assert_true(
            floor_msg.find("unknown _GENERATION_FLOOR version") >= 0,
            "floor body " + String(k) + ": " + floor_msg,
        )
        var bumps_msg = String("")
        try:
            _ = decode_generation_bumps(bodies[k])
        except e:
            bumps_msg = String(e)
        assert_true(
            bumps_msg.find("unknown _GENERATION_BUMPS version") >= 0,
            "bumps body " + String(k) + ": " + bumps_msg,
        )
        var shards_msg = String("")
        try:
            _ = decode_retired_shards(bodies[k])
        except e:
            shards_msg = String(e)
        assert_true(
            shards_msg.find("unknown _RETIRED_SHARDS version") >= 0,
            "shards body " + String(k) + ": " + shards_msg,
        )
    for n in range(1, 9):
        var short = _prefix(encode_generation_bumps(Int64(9)), n)
        var msg = String("")
        try:
            _ = decode_generation_bumps(short)
        except e:
            msg = String(e)
        assert_true(msg.find("truncated i64 at offset 1") >= 0, msg)

    # Retired shards: round trip, a negative count, a count past the body.
    var r = RetiredShards()
    _ = r.raise_to(String("w-1"), Int64(4))
    _ = r.raise_to(String(""), Int64(0x7FFFFFFFFFFFFFFF))
    _ = r.raise_to(String("w-10"), Int64(-2))
    var enc = encode_retired_shards(r)
    var d = decode_retired_shards(enc)
    assert_equal(len(d), 3)
    assert_equal(d.generation_of(String("w-1")), Int64(4))
    assert_equal(d.generation_of(String("")), Int64(0x7FFFFFFFFFFFFFFF))
    assert_equal(d.generation_of(String("w-10")), Int64(-2))
    var neg = enc.copy()
    _put_le(neg, 1, UInt64(0x8000000000000001))
    var msg = String("")
    try:
        _ = decode_retired_shards(neg)
    except e:
        msg = String(e)
    assert_true(msg.find("negative _RETIRED_SHARDS count") >= 0, msg)
    var many = enc.copy()
    _put_le(many, 1, UInt64(0x0100000000000003))
    msg = String("")
    try:
        _ = decode_retired_shards(many)
    except e:
        msg = String(e)
    assert_true(msg.find("corrupt") >= 0, "count past the body: " + msg)
    var empty = RetiredShards()
    assert_equal(len(decode_retired_shards(encode_retired_shards(empty))), 0)


def test_retired_shards_raise_to_only_raises() raises:
    var r = RetiredShards()
    assert_equal(r.find(String("w-1")), -1)
    assert_equal(r.generation_of(String("w-1")), Int64(0))
    assert_true(r.raise_to(String("w-1"), Int64(5)), "a new id is recorded")
    assert_true(r.raise_to(String("w-10"), Int64(2)), "a longer id is new")
    assert_equal(r.find(String("w-10")), 1, "ids compare by exact bytes")
    assert_equal(r.find(String("w-")), -1, "a prefix is not a match")
    assert_false(r.raise_to(String("w-1"), Int64(4)), "lower: no write")
    assert_equal(r.generation_of(String("w-1")), Int64(5), "lower kept 5")
    assert_false(r.raise_to(String("w-1"), Int64(5)), "equal: no write")
    assert_true(r.raise_to(String("w-1"), Int64(6)), "higher: a write")
    assert_equal(r.generation_of(String("w-1")), Int64(6), "raised to 6")
    assert_equal(r.generation_of(String("w-10")), Int64(2), "other id kept")
    assert_equal(len(r), 2, "no duplicate entry")


def test_chunk_seq_of_reads_only_chunk_keys() raises:
    var l = String("index/logs/meta/_lineage/w-1")
    assert_equal(
        _chunk_seq_of(l, l + "/manifest/00000000000000000042.chunk"),
        Int64(42),
    )
    assert_equal(
        _chunk_seq_of(l, l + "/manifest/09223372036854775807.chunk"),
        Int64(0x7FFFFFFFFFFFFFFF),
    )
    var not_chunks = List[String]()
    not_chunks.append(l + "/manifest/.chunk")
    not_chunks.append(l + "/manifest/0000000000000000004a.chunk")
    not_chunks.append(l + "/manifest/00000000000000000/42.chunk")
    not_chunks.append(l + "/manifest/-0000000000000000042.chunk")
    not_chunks.append(l + "/manifest/00000000000000000042.chunkx")
    not_chunks.append(l + "/tombstones/00000000000000000042.tomb")
    not_chunks.append(l + "/_LOG_START")
    not_chunks.append(l + "x/manifest/00000000000000000042.chunk")
    not_chunks.append(String("index/logs/meta/manifest/00000000000000000042.chunk"))
    for k in range(len(not_chunks)):
        assert_equal(
            _chunk_seq_of(l, not_chunks[k]), Int64(-1), not_chunks[k]
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
