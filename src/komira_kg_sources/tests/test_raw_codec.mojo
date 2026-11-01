# =============================================================================
# test_raw_codec.mojo -- the stored form of a raw record.
# =============================================================================
#
#   round trip  a record decodes to the tag, time and payload it was encoded from,
#               for a payload with NUL and non-UTF-8 bytes and for an empty one,
#               and the encoded bytes are the documented layout.
#   encode      an empty tag, a tag with a control byte and a tag over the size
#               limit are refused.
#   decode      every strict prefix of a valid body is refused; an empty body, an
#               unknown version, trailing bytes, a tag or payload length past the
#               end (including 4294967295), a tag over the limit and a tag that is
#               not UTF-8 are refused with an error naming the defect.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg_sources import (
    RAW_FORMAT_VERSION,
    RawRecord,
    decode_raw_record,
    encode_raw_record,
    raw_content_hash,
)


def _bytes(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def _refuses(body: List[UInt8]) -> Bool:
    try:
        _ = decode_raw_record(body)
    except e:
        _ = e
        return True
    return False


def _valid() raises -> List[UInt8]:
    return encode_raw_record(RawRecord("kind-a", Int64(77), _bytes([1, 2, 3])))


def test_a_record_round_trips() raises:
    var payload = _bytes([0, 255, 0, 200, 10, 0xC3])
    var back = decode_raw_record(
        encode_raw_record(RawRecord("kind-a", Int64(-5), payload.copy()))
    )
    assert_equal(back.surface_tag, "kind-a")
    assert_equal(back.received_at, Int64(-5))
    assert_equal(len(back.payload), 6)
    for i in range(6):
        assert_equal(back.payload[i], payload[i])
    var empty = decode_raw_record(
        encode_raw_record(RawRecord("k", Int64(0), List[UInt8]()))
    )
    assert_equal(len(empty.payload), 0)


def test_the_encoded_bytes_are_the_documented_layout() raises:
    var body = _valid()
    var want = _bytes(
        [1, 6, 0, 0, 0, 107, 105, 110, 100, 45, 97, 77, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3]
    )
    assert_equal(len(body), len(want))
    for i in range(len(want)):
        assert_equal(body[i], want[i])
    assert_equal(RAW_FORMAT_VERSION, 1)


def test_the_content_hash_is_fnv1a_64_of_the_payload() raises:
    assert_equal(raw_content_hash(List[UInt8]()), "cbf29ce484222325")
    assert_equal(raw_content_hash(_bytes([97])), "af63dc4c8601ec8c")
    var r = RawRecord("t", Int64(1), _bytes([97]))
    assert_equal(r.content_hash(), "af63dc4c8601ec8c")


def test_a_tag_that_cannot_be_stored_is_refused() raises:
    with assert_raises(contains="surface tag must not be empty"):
        _ = encode_raw_record(RawRecord("", Int64(1), _bytes([1])))
    with assert_raises(contains="surface tag must not hold a control byte"):
        _ = encode_raw_record(RawRecord("a\nb", Int64(1), _bytes([1])))
    var big = String("")
    for _ in range(65537):
        big += "x"
    with assert_raises(contains="surface tag is 65537 bytes"):
        _ = encode_raw_record(RawRecord(big, Int64(1), _bytes([1])))


def test_every_strict_prefix_of_a_body_is_refused() raises:
    var body = _valid()
    assert_false(_refuses(body))
    for n in range(len(body)):
        var cut = List[UInt8]()
        for i in range(n):
            cut.append(body[i])
        assert_true(_refuses(cut))


def test_an_empty_body_is_refused() raises:
    with assert_raises(contains="RawStore: truncated format version at offset 0"):
        _ = decode_raw_record(List[UInt8]())


def test_an_unknown_version_is_refused() raises:
    var body = _valid()
    body[0] = UInt8(2)
    with assert_raises(contains="format version 2 is not the supported 1"):
        _ = decode_raw_record(body)


def test_trailing_bytes_are_refused() raises:
    var body = _valid()
    body.append(UInt8(0))
    with assert_raises(contains="1 trailing bytes after the last field"):
        _ = decode_raw_record(body)


def test_a_tag_length_past_the_end_is_refused() raises:
    var body = _bytes([1, 255, 255, 255, 255, 65, 66])
    with assert_raises(contains="the surface tag claims 4294967295 bytes"):
        _ = decode_raw_record(body)
    var short = _bytes([1, 9, 0, 0, 0, 65, 66])
    with assert_raises(contains="truncated surface tag at offset 5 (2 bytes remain)"):
        _ = decode_raw_record(short)


def test_a_payload_length_past_the_end_is_refused() raises:
    var body = _bytes(
        [1, 1, 0, 0, 0, 65, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 1]
    )
    with assert_raises(contains="truncated payload at offset 18 (1 bytes remain)"):
        _ = decode_raw_record(body)


def test_a_tag_that_is_not_utf8_is_refused() raises:
    var body = _bytes([1, 2, 0, 0, 0, 0xC3, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    with assert_raises(contains="the surface tag is not valid UTF-8"):
        _ = decode_raw_record(body)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
