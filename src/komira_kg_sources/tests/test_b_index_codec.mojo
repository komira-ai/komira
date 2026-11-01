# =============================================================================
# test_b_index_codec.mojo -- the stored form of an indexed raw record.
# =============================================================================
#
#   round trip  rows decode to the uuid, time and vector they were encoded from
#               (a vector comes back at f32 precision), and the encoded bytes are
#               the documented layout; a record with no row round trips.
#   encode      a tag or a uuid over the size limit is refused.
#   decode      every strict prefix of a valid body is refused; an unknown
#               version, trailing bytes, a row count the remaining bytes cannot
#               hold (4294967295, and one more than fits), a length past the end,
#               a uuid or tag that is not UTF-8 or over the limit, and an
#               embedding that is empty, not whole f32 components, or not the
#               index's dimension are refused with an error naming the defect.
#               A dimension below one is refused.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg_sources import (
    IndexRecord,
    IndexRow,
    decode_index_record,
    encode_index_record,
)
from komira_kg_sources.framing import put_bytes, put_i64, put_text, put_u32, put_u8


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    return out^


def _bytes(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def _record() -> IndexRecord:
    var rows = List[IndexRow]()
    rows.append(IndexRow("r#0", Int64(10), _vec(1, 0, 0, 0)))
    rows.append(IndexRow("r#1", Int64(-20), _vec(0.5, -2, 0.25, 8)))
    return IndexRecord("kind-a", rows^)


def _refuses(body: List[UInt8], dim: Int) -> Bool:
    try:
        _ = decode_index_record(body, dim)
    except e:
        _ = e
        return True
    return False


def _body(count: Int, uuid: String, emb: List[UInt8]) raises -> List[UInt8]:
    """A version-1 body for tag "t" with `count` as the row count and one row."""
    var out = List[UInt8]()
    put_u8(out, 1)
    put_text(out, "t", "tag")
    put_u32(out, count)
    put_text(out, uuid, "uuid")
    put_i64(out, Int64(5))
    put_bytes(out, emb, "embedding")
    return out^


def _four() -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(16):
        out.append(UInt8(0))
    return out^


def test_rows_round_trip() raises:
    var back = decode_index_record(encode_index_record(_record()), 4)
    assert_equal(back.surface_tag, "kind-a")
    assert_equal(len(back.rows), 2)
    assert_equal(back.rows[0].episode_uuid, "r#0")
    assert_equal(back.rows[0].valid_at, Int64(10))
    assert_equal(back.rows[1].episode_uuid, "r#1")
    assert_equal(back.rows[1].valid_at, Int64(-20))
    var want = _vec(0.5, -2, 0.25, 8)
    for i in range(4):
        assert_equal(back.rows[1].embedding[i], want[i])
    var none = decode_index_record(encode_index_record(IndexRecord("k", List[IndexRow]())), 4)
    assert_equal(len(none.rows), 0)
    assert_equal(none.surface_tag, "k")


def test_the_encoded_bytes_are_the_documented_layout() raises:
    var rows = List[IndexRow]()
    rows.append(IndexRow("u", Int64(3), _vec(1, 0, 0, -2)))
    var body = encode_index_record(IndexRecord("t", rows^))
    var want = _bytes(
        [1, 1, 0, 0, 0, 116, 1, 0, 0, 0, 1, 0, 0, 0, 117, 3, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 128, 63, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192]
    )
    assert_equal(len(body), len(want))
    for i in range(len(want)):
        assert_equal(body[i], want[i])


def test_a_tag_or_uuid_over_the_limit_is_not_written() raises:
    var big = String("")
    for _ in range(65537):
        big += "x"
    with assert_raises(contains="surface tag is 65537 bytes"):
        _ = encode_index_record(IndexRecord(big, List[IndexRow]()))
    var rows = List[IndexRow]()
    rows.append(IndexRow(big, Int64(1), _vec(1, 0, 0, 0)))
    with assert_raises(contains="episode uuid is 65537 bytes"):
        _ = encode_index_record(IndexRecord("t", rows^))


def test_every_strict_prefix_of_a_body_is_refused() raises:
    var body = encode_index_record(_record())
    assert_false(_refuses(body, 4))
    for n in range(len(body)):
        var cut = List[UInt8]()
        for i in range(n):
            cut.append(body[i])
        assert_true(_refuses(cut, 4))


def test_an_unknown_version_and_trailing_bytes_are_refused() raises:
    var body = encode_index_record(_record())
    var versioned = body.copy()
    versioned[0] = UInt8(2)
    with assert_raises(contains="format version 2 is not the supported 1"):
        _ = decode_index_record(versioned, 4)
    var long = body.copy()
    long.append(UInt8(0))
    with assert_raises(contains="1 trailing bytes after the last field"):
        _ = decode_index_record(long, 4)


def _short_for_count() raises -> List[UInt8]:
    """Claims one row, in the 16 bytes that are the least a row can take, but the
    row's uuid length is 100."""
    var out = List[UInt8]()
    put_u8(out, 1)
    put_text(out, "t", "tag")
    put_u32(out, 1)
    put_u32(out, 100)
    for _ in range(12):
        out.append(UInt8(0))
    return out^


def test_a_row_count_the_remaining_bytes_cannot_hold_is_refused() raises:
    with assert_raises(contains="the row count claims 4294967295 rows, more than the 32 remaining bytes can hold"):
        _ = decode_index_record(_body(4294967295, "", _four()), 4)
    # One row after the count takes 32 bytes here; three claimed do not fit in 32.
    with assert_raises(contains="the row count claims 3 rows, more than the 32 remaining bytes can hold"):
        _ = decode_index_record(_body(3, "", _four()), 4)
    # A count that passes the gate but not the data runs out of bytes.
    with assert_raises(contains="truncated episode uuid at offset"):
        _ = decode_index_record(_short_for_count(), 4)


def test_an_embedding_that_is_not_the_index_dimension_is_refused() raises:
    var three = List[UInt8]()
    for _ in range(12):
        three.append(UInt8(0))
    with assert_raises(contains="embedding cell is 12 bytes, which is not a dimension of 4"):
        _ = decode_index_record(_body(1, "u", three), 4)
    var ragged = List[UInt8]()
    for _ in range(15):
        ragged.append(UInt8(0))
    with assert_raises(contains="embedding cell is 15 bytes"):
        _ = decode_index_record(_body(1, "u", ragged), 4)
    with assert_raises(contains="embedding cell is 0 bytes"):
        _ = decode_index_record(_body(1, "u", List[UInt8]()), 4)
    # A cell that is whole for dimension 4 is refused by an index of dimension 2.
    with assert_raises(contains="not a dimension of 2"):
        _ = decode_index_record(_body(1, "u", _four()), 2)
    assert_equal(len(decode_index_record(_body(1, "u", _four()), 4).rows), 1)


def test_a_dimension_below_one_is_refused() raises:
    with assert_raises(contains="dimension must be positive, got 0"):
        _ = decode_index_record(_body(1, "u", _four()), 0)
    with assert_raises(contains="dimension must be positive, got -1"):
        _ = decode_index_record(_body(1, "u", _four()), -1)


def test_an_embedding_length_past_the_end_is_refused() raises:
    var out = List[UInt8]()
    put_u8(out, 1)
    put_text(out, "t", "tag")
    put_u32(out, 1)
    put_text(out, "u", "uuid")
    put_i64(out, Int64(5))
    put_u32(out, 4294967295)
    for _ in range(8):
        out.append(UInt8(0))
    with assert_raises(contains="truncated embedding at offset"):
        _ = decode_index_record(out, 4)


def test_text_that_is_not_utf8_or_too_long_is_refused() raises:
    var tag = _bytes([1, 1, 0, 0, 0, 0xFF])
    with assert_raises(contains="the surface tag is not valid UTF-8"):
        _ = decode_index_record(tag, 4)
    var uuid = List[UInt8]()
    put_u8(uuid, 1)
    put_text(uuid, "t", "tag")
    put_u32(uuid, 1)
    put_u32(uuid, 2)
    uuid.append(UInt8(0xC3))
    uuid.append(UInt8(0x28))
    for _ in range(12):
        uuid.append(UInt8(0))
    with assert_raises(contains="the episode uuid is not valid UTF-8"):
        _ = decode_index_record(uuid, 4)
    var long = List[UInt8]()
    put_u8(long, 1)
    put_u32(long, 65537)
    with assert_raises(contains="the surface tag claims 65537 bytes, over the limit of 65536"):
        _ = decode_index_record(long, 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
