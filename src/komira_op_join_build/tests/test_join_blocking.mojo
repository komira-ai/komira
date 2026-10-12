# =============================================================================
# test_join_blocking -- the blocking functions of non-equi joins: rows that
# can match must share a bucket id.
# =============================================================================
#
# What each test catches:
#   * `test_bin_point_keys`: `floor(v / width)` per row, negative values to
#     their own (wrapped) bins; an off-by-one floor (truncation toward zero)
#     merges bin -1 into bin 0.
#   * `test_bin_range_keys_cover_every_overlapping_bin`: a range row maps to
#     EVERY bin from floor(lo/w) to floor(hi/w) inclusive; dropping the last
#     bin loses candidate pairs (a silently smaller join).
#   * `test_spans_of_unequal_length_raise`: the two-column forms refuse spans
#     of different lengths instead of reading past the shorter one.
#   * `test_geohash_neighbors_and_border_points`: two points on opposite sides
#     of a cell border share a bucket through the neighbour cells, and the
#     poles do not wrap while longitude does.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_op_join_build.join_blocking import (
    BinBlocking,
    GeohashBlocking,
    geohash_encode,
    geohash_neighbors,
)


def test_bin_point_keys() raises:
    var b = BinBlocking.for_point(0, 10.0)
    var vals: List[Float64] = [0.0, 9.99, 10.0, -0.5, -10.0, 25.0]
    var keys = b.block_keys_point(Span(vals))
    assert_equal(len(keys), 6)
    for i in range(6):
        assert_equal(len(keys[i]), 1, "a point maps to one bin")
    assert_equal(Int(keys[0][0]), 0)
    assert_equal(Int(keys[1][0]), 0)
    assert_equal(Int(keys[2][0]), 1)
    # floor(-0.05) = -1 and floor(-1.0) = -1: both in bin -1, not bin 0.
    assert_equal(keys[3][0], UInt64(Int64(-1)))
    assert_equal(keys[4][0], UInt64(Int64(-1)))
    assert_equal(Int(keys[5][0]), 2)
    assert_equal(b.name(), "bin_blocking")


def test_bin_range_keys_cover_every_overlapping_bin() raises:
    var b = BinBlocking.for_range(0, 1, 10.0)
    var lo: List[Float64] = [5.0, 0.0, -15.0]
    var hi: List[Float64] = [35.0, 0.0, -5.0]
    var keys = b.block_keys_range(Span(lo), Span(hi))
    assert_equal(len(keys), 3)
    # [5, 35] overlaps bins 0, 1, 2, 3.
    assert_equal(len(keys[0]), 4)
    for j in range(4):
        assert_equal(Int(keys[0][j]), j)
    # A degenerate range is one bin.
    assert_equal(len(keys[1]), 1)
    assert_equal(Int(keys[1][0]), 0)
    # [-15, -5] overlaps bins -2 and -1.
    assert_equal(len(keys[2]), 2)
    assert_equal(keys[2][0], UInt64(Int64(-2)))
    assert_equal(keys[2][1], UInt64(Int64(-1)))
    # A point with value 12 (bin 1) shares a bin with range row 0.
    var p = BinBlocking.for_point(0, 10.0)
    assert_equal(p.value_to_bin(12.0), keys[0][1])


def test_spans_of_unequal_length_raise() raises:
    var b = BinBlocking.for_range(0, 1, 1.0)
    var lo: List[Float64] = [1.0, 2.0]
    var hi: List[Float64] = [3.0]
    var raised = False
    try:
        _ = b.block_keys_range(Span(lo), Span(hi))
    except:
        raised = True
    assert_true(raised, "block_keys_range must refuse unequal spans")
    var g = GeohashBlocking(0, 1, UInt8(5))
    var lat: List[Float64] = [10.0]
    var lon: List[Float64] = [10.0, 20.0]
    raised = False
    try:
        _ = g.block_keys(Span(lat), Span(lon))
    except:
        raised = True
    assert_true(raised, "GeohashBlocking.block_keys must refuse unequal spans")


def test_geohash_neighbors_and_border_points() raises:
    comptime SENTINEL: UInt64 = ~UInt64(0)
    # Precision 2: 10 bits, 5 per axis. Quantisation maps [-180, 180] onto
    # 0..31, so the longitude code is floor((lon + 180) / 360 * 31) and the
    # border between codes 19 and 20 is at 360 * 20 / 31 - 180 = 52.258...:
    # 52.2 and 52.3 sit in adjacent cells at the same latitude.
    var a = geohash_encode(10.0, 52.2, UInt8(2))
    var b = geohash_encode(10.0, 52.3, UInt8(2))
    assert_true(a != b, "the two points sit in different cells")
    var na = geohash_neighbors(a, UInt8(2))
    var found = False
    for i in range(8):
        if na[i] == b:
            found = True
    assert_true(found, "the east neighbour of a's cell is b's cell")

    # Through `block_keys`, the two rows share at least one bucket.
    var g = GeohashBlocking(0, 1, UInt8(2))
    var lat: List[Float64] = [10.0, 10.0]
    var lon: List[Float64] = [52.2, 52.3]
    var keys = g.block_keys(Span(lat), Span(lon))
    assert_equal(len(keys[0]), 9, "a mid-latitude cell has 8 neighbours")
    var shared = False
    for i in range(len(keys[0])):
        for j in range(len(keys[1])):
            if keys[0][i] == keys[1][j]:
                shared = True
    assert_true(shared, "border points must share a bucket")

    # At the north pole there is no northern neighbour (no wrap in latitude),
    # while longitude wraps: the west neighbour of a cell at -180 exists.
    var pole = geohash_encode(90.0, -180.0, UInt8(2))
    var np = geohash_neighbors(pole, UInt8(2))
    assert_equal(np[0], SENTINEL, "no N neighbour at the pole")
    assert_true(np[6] != SENTINEL, "W neighbour wraps around longitude")
    var plat: List[Float64] = [90.0]
    var plon: List[Float64] = [-180.0]
    var pole_keys = g.block_keys(Span(plat), Span(plon))
    assert_equal(len(pole_keys[0]), 6, "self + 5 neighbours at the pole")
    assert_false(len(pole_keys[0]) == 9)
    assert_equal(g.name(), "geohash_blocking")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
