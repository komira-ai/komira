# =============================================================================
# test_search_scan_positions.mojo -- the `komira.search.index` split-position
# encoding: 9 bytes, a tag then the rank little-endian.
#
# Pins:
#   * a rank with a byte set in every position round-trips, and is written
#     low byte first;
#   * a done position is tag 1 and rank 0 whatever rank it was given;
#   * the largest rank an Int64 holds decodes; one past it, and a rank with
#     every byte 0xFF, are refused by name (`SEARCH_SPLIT_POSITION_INVALID`);
#   * a tag other than 0 or 1 is refused by name, naming the tag;
#   * a length of 8 or 10 is refused by name, naming the length; a position
#     both too short and badly tagged is refused for its length (the first
#     check).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_scan_resolver.scan_split import SplitPosition

from komira_search_scan.search_split_reader import (
    SEARCH_SPLIT_POSITION_INVALID,
    SEARCH_SPLIT_POSITION_VERSION,
    decode_search_split_position,
    search_split_position,
)
from komira_search_scan.search_scan_kind import search_scan_kind_id


def _pos(var bytes: List[UInt8]) -> SplitPosition:
    return SplitPosition(
        search_scan_kind_id(), SEARCH_SPLIT_POSITION_VERSION, bytes^
    )


def _at_rank(rank_le: List[UInt8]) -> List[UInt8]:
    """Tag 0 then the eight given rank bytes."""
    var b = List[UInt8]()
    b.append(0)
    for i in range(len(rank_le)):
        b.append(rank_le[i])
    return b^


def _expect_refused(var bytes: List[UInt8], want: String, what: String) raises:
    var raised = False
    try:
        _ = decode_search_split_position(_pos(bytes^), String("start of 'x'"))
    except err:
        raised = True
        var msg = String(err)
        assert_true(String(SEARCH_SPLIT_POSITION_INVALID) in msg, what + ": " + msg)
        assert_true(want in msg, what + ": " + msg)
        assert_true("start of 'x'" in msg, what + " names the position: " + msg)
    assert_true(raised, what + " is refused")


def test_a_rank_round_trips_low_byte_first() raises:
    var id = search_scan_kind_id()
    var p = search_split_position(id, False, 0x0102030405060708)
    assert_equal(len(p.bytes), 9)
    assert_equal(Int(p.bytes[0]), 0, "tag: at rank")
    for i in range(8):
        assert_equal(Int(p.bytes[1 + i]), 8 - i, "rank byte " + String(i))
    var at = decode_search_split_position(p, String("p"))
    assert_false(at.done)
    assert_equal(at.rank, 0x0102030405060708)


def test_a_done_position_is_tag_one_and_rank_zero() raises:
    var p = search_split_position(search_scan_kind_id(), True, 77)
    assert_equal(Int(p.bytes[0]), 1, "tag: done")
    for i in range(1, 9):
        assert_equal(Int(p.bytes[i]), 0, "byte " + String(i))
    var at = decode_search_split_position(p, String("p"))
    assert_true(at.done)
    assert_equal(at.rank, 0)


def test_the_largest_int64_rank_decodes() raises:
    var at = decode_search_split_position(
        _pos(_at_rank([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])),
        String("p"),
    )
    assert_false(at.done)
    assert_equal(Int64(at.rank), Int64.MAX)


def test_a_rank_past_int64_is_refused_by_name() raises:
    _expect_refused(
        _at_rank([0, 0, 0, 0, 0, 0, 0, 0x80]),
        String("does not fit an Int64"),
        "rank 2^63",
    )
    _expect_refused(
        _at_rank([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        String("does not fit an Int64"),
        "rank 2^64 - 1",
    )


def test_an_unknown_tag_is_refused_by_name() raises:
    var tags: List[UInt8] = [2, 0xFF]
    for i in range(len(tags)):
        var b = List[UInt8]()
        b.append(tags[i])
        for _ in range(8):
            b.append(0)
        _expect_refused(
            b^,
            String("tag ") + String(Int(tags[i])),
            String("tag ") + String(Int(tags[i])),
        )


def test_a_wrong_length_is_refused_by_name() raises:
    var lens: List[Int] = [8, 10]
    for i in range(len(lens)):
        var b = List[UInt8]()
        for _ in range(lens[i]):
            b.append(0)
        _expect_refused(
            b^,
            String("has ") + String(lens[i]) + String(" bytes"),
            String("length ") + String(lens[i]),
        )


def test_the_length_is_checked_before_the_tag() raises:
    # Too short AND tag 7: the length is the reason reported.
    var b: List[UInt8] = [7]
    _expect_refused(b^, String("has 1 bytes"), "short and badly tagged")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
