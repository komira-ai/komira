# =============================================================================
# tests/test_coalesce.mojo — coalescing planner unit suite
# =============================================================================
#
# Asserts the coalescing algorithm against
# hand-derived input/output pairs, AND the wasted-byte ceiling
# (round-trip count alone misleads — a too-large max_gap_bytes improves
# round-trip count while wasting bandwidth).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_objectstore import (
    CoalescePolicy,
    CoalescePlan,
    GetRange,
    RangeSet,
    plan_coalesce,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _policy(max_gap: Int, max_req: Int = 8 * 1024 * 1024) -> CoalescePolicy:
    return CoalescePolicy(Int64(max_gap), Int64(max_req), 8)


def _build_ranges(
    pairs: List[Int]
) raises -> RangeSet:
    """`pairs` is a flat [start0, end0, start1, end1, ...] list.
    dst_offsets are assigned sequentially starting at 0 with cumulative-
    length spacing."""
    var rs = RangeSet.empty()
    var dst = 0
    for i in range(0, len(pairs), 2):
        var s = pairs[i]
        var e = pairs[i + 1]
        rs.append(GetRange.bounded(Int64(s), Int64(e)), dst)
        dst += (e - s)
    return rs^


# -----------------------------------------------------------------------------
# Empty / single-range
# -----------------------------------------------------------------------------


def test_empty_input_returns_empty_plan() raises:
    var rs = RangeSet.empty()
    var plan = plan_coalesce(rs, _policy(1024))
    assert_equal(plan.num_requests(), 0)
    assert_equal(Int(plan.total_requested_bytes), 0)
    assert_equal(Int(plan.total_fetched_bytes), 0)
    assert_equal(Int(plan.wasted_bytes()), 0)


def test_single_range_no_merge() raises:
    var pairs = List[Int]()
    pairs.append(0)
    pairs.append(100)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(1024))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 100)
    assert_equal(Int(plan.total_requested_bytes), 100)
    assert_equal(Int(plan.total_fetched_bytes), 100)
    assert_equal(Int(plan.wasted_bytes()), 0)


# -----------------------------------------------------------------------------
# Merge across small gaps
# -----------------------------------------------------------------------------


def test_two_adjacent_no_gap_merged() raises:
    """[0,100) and [100,200) — gap=0; ALWAYS merge."""
    var pairs = List[Int]()
    pairs.append(0); pairs.append(100)
    pairs.append(100); pairs.append(200)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(0))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 200)
    assert_equal(len(plan.coalesced[0].slices), 2)
    # Verify slice metadata.
    var s0 = plan.coalesced[0].slices[0]
    var s1 = plan.coalesced[0].slices[1]
    assert_equal(s0.coalesced_offset, 0)
    assert_equal(s0.length, 100)
    assert_equal(s1.coalesced_offset, 100)
    assert_equal(s1.length, 100)
    assert_equal(Int(plan.wasted_bytes()), 0)


def test_two_within_gap_merged() raises:
    """[0,100) and [200,300) — gap=100; merge with max_gap=200."""
    var pairs = List[Int]()
    pairs.append(0); pairs.append(100)
    pairs.append(200); pairs.append(300)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(200))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 300)
    # Wasted: 100 bytes of gap.
    assert_equal(Int(plan.wasted_bytes()), 100)


def test_two_beyond_gap_not_merged() raises:
    """[0,100) and [200,300) — gap=100; do NOT merge with max_gap=50."""
    var pairs = List[Int]()
    pairs.append(0); pairs.append(100)
    pairs.append(200); pairs.append(300)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(50))
    assert_equal(plan.num_requests(), 2)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 100)
    assert_equal(Int(plan.coalesced[1].start), 200)
    assert_equal(Int(plan.coalesced[1].end), 300)
    assert_equal(Int(plan.wasted_bytes()), 0)


def test_three_ranges_chain_merge() raises:
    """[0,10) [15,25) [27,30) with max_gap=5 — all three merge into one."""
    var pairs = List[Int]()
    pairs.append(0);  pairs.append(10)
    pairs.append(15); pairs.append(25)
    pairs.append(27); pairs.append(30)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(5))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 30)
    # Wasted: gap1=5 + gap2=2 = 7 bytes.
    assert_equal(Int(plan.wasted_bytes()), 7)


def test_three_ranges_chain_breaks_at_middle_gap() raises:
    """[0,10) [15,25) [50,60) — first two merge, third stands alone (gap 25 > max_gap 5)."""
    var pairs = List[Int]()
    pairs.append(0);  pairs.append(10)
    pairs.append(15); pairs.append(25)
    pairs.append(50); pairs.append(60)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(5))
    assert_equal(plan.num_requests(), 2)
    assert_equal(Int(plan.coalesced[0].end), 25)
    assert_equal(Int(plan.coalesced[1].start), 50)
    assert_equal(Int(plan.coalesced[1].end), 60)
    # Wasted: only the 5-byte gap in the merged block.
    assert_equal(Int(plan.wasted_bytes()), 5)


# -----------------------------------------------------------------------------
# Out-of-order input — sort applied
# -----------------------------------------------------------------------------


def test_input_sorted_by_start() raises:
    """Input in scrambled order: planner must sort by start before merging."""
    var pairs = List[Int]()
    pairs.append(200); pairs.append(300)
    pairs.append(0);   pairs.append(100)
    pairs.append(100); pairs.append(200)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(0))  # gap=0; all touch -> 1 req
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 300)
    assert_equal(len(plan.coalesced[0].slices), 3)
    # The slices' orig_index preserve the ORIGINAL input position
    # (so the HTTP scatter-write puts each into the right dst slot).
    # Pre-sort positions: 0=[200,300), 1=[0,100), 2=[100,200).
    # After sort by start: 1, 2, 0. So the slices' orig_index sequence
    # should be [1, 2, 0].
    assert_equal(plan.coalesced[0].slices[0].orig_index, 1)
    assert_equal(plan.coalesced[0].slices[1].orig_index, 2)
    assert_equal(plan.coalesced[0].slices[2].orig_index, 0)


# -----------------------------------------------------------------------------
# Overlapping ranges
# -----------------------------------------------------------------------------


def test_overlapping_ranges_merged() raises:
    """[0,100) and [50,150) — overlap; merge into [0,150)."""
    var pairs = List[Int]()
    pairs.append(0);  pairs.append(100)
    pairs.append(50); pairs.append(150)
    var rs = _build_ranges(pairs)
    var plan = plan_coalesce(rs, _policy(0))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 0)
    assert_equal(Int(plan.coalesced[0].end), 150)
    # Wasted: 0 — every byte fetched is requested (overlap means redundancy
    # in the input, not bandwidth waste — fetched=150, requested=100+100=200).
    # NOTE: total_requested_bytes is the sum of input range lengths, so an
    # OVERLAP makes requested > fetched (a "negative waste" — we serve 2
    # requests with 1 fetch covering both). The wasted_bytes accessor is
    # `fetched - requested`, so it goes negative here.
    var w = Int(plan.wasted_bytes())
    assert_true(w <= 0, "overlap produces non-positive waste")


# -----------------------------------------------------------------------------
# max_request_bytes splits a giant coalesced span
# -----------------------------------------------------------------------------


def test_max_request_bytes_prevents_oversized_merge() raises:
    """[0,1000) and [500,1500) — would merge to [0,1500)=1500 bytes,
    but max_req=1000 forces them to stay separate."""
    var pairs = List[Int]()
    pairs.append(0);   pairs.append(1000)
    pairs.append(500); pairs.append(1500)
    var rs = _build_ranges(pairs)
    var pol = _policy(0, 1000)
    var plan = plan_coalesce(rs, pol)
    assert_equal(plan.num_requests(), 2)


# -----------------------------------------------------------------------------
# Too-large max_gap_bytes wastes bandwidth
# -----------------------------------------------------------------------------


def test_wasted_bytes_assertion_demonstrates_gap_waste() raises:
    """Round-trip-count alone misleads. With a too-large
    max_gap, fewer requests but more wasted bytes. This test demonstrates
    the trade-off explicitly."""
    var pairs = List[Int]()
    pairs.append(0);    pairs.append(10)
    pairs.append(1000); pairs.append(1010)
    var rs = _build_ranges(pairs)

    # Small gap: 2 separate requests, 0 wasted.
    var plan_small = plan_coalesce(rs, _policy(100))
    assert_equal(plan_small.num_requests(), 2)
    assert_equal(Int(plan_small.wasted_bytes()), 0)

    # Large gap: 1 request, ~990 bytes wasted.
    var plan_large = plan_coalesce(rs, _policy(1024))
    assert_equal(plan_large.num_requests(), 1)
    assert_equal(Int(plan_large.wasted_bytes()), 990)


# -----------------------------------------------------------------------------
# Negative-edge / error cases
# -----------------------------------------------------------------------------


def test_offset_without_object_size_raises() raises:
    """Offset(start) requires a known object_size; raise if not provided."""
    var rs = RangeSet.empty()
    rs.append(GetRange.offset(Int64(100)), 0)
    with assert_raises():
        var _p = plan_coalesce(rs, _policy(1024))


def test_suffix_without_object_size_raises() raises:
    var rs = RangeSet.empty()
    rs.append(GetRange.suffix(Int64(8)), 0)
    with assert_raises():
        var _p = plan_coalesce(rs, _policy(1024))


def test_suffix_with_object_size_resolves() raises:
    """Suffix(8) against a 100-byte object => [92, 100)."""
    var rs = RangeSet.empty()
    rs.append(GetRange.suffix(Int64(8)), 0)
    var plan = plan_coalesce(rs, _policy(1024), Int64(100))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 92)
    assert_equal(Int(plan.coalesced[0].end), 100)


def test_offset_with_object_size_resolves() raises:
    """Offset(100) against a 500-byte object => [100, 500)."""
    var rs = RangeSet.empty()
    rs.append(GetRange.offset(Int64(100)), 0)
    var plan = plan_coalesce(rs, _policy(1024), Int64(500))
    assert_equal(plan.num_requests(), 1)
    assert_equal(Int(plan.coalesced[0].start), 100)
    assert_equal(Int(plan.coalesced[0].end), 500)


# -----------------------------------------------------------------------------
# Slice metadata sanity — every slice maps correctly
# -----------------------------------------------------------------------------


def test_dst_offsets_preserved_after_sort_and_merge() raises:
    """Input out of order, after merge dst_offsets must remain pointing at
    the right positions in the caller's dst buffer."""
    var rs = RangeSet.empty()
    rs.append(GetRange.bounded(Int64(200), Int64(300)), 1000)  # orig 0
    rs.append(GetRange.bounded(Int64(0),   Int64(100)), 2000)  # orig 1
    rs.append(GetRange.bounded(Int64(100), Int64(200)), 3000)  # orig 2
    var plan = plan_coalesce(rs, _policy(0))
    assert_equal(plan.num_requests(), 1)
    var slices = plan.coalesced[0].slices.copy()
    # After sort: orig_indices [1, 2, 0]; dst_offsets must follow:
    # slice[0] -> orig 1 -> dst 2000; slice[1] -> orig 2 -> dst 3000;
    # slice[2] -> orig 0 -> dst 1000.
    assert_equal(slices[0].orig_index, 1)
    assert_equal(slices[0].dst_offset, 2000)
    assert_equal(slices[1].orig_index, 2)
    assert_equal(slices[1].dst_offset, 3000)
    assert_equal(slices[2].orig_index, 0)
    assert_equal(slices[2].dst_offset, 1000)


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


def main() raises:
    test_empty_input_returns_empty_plan()
    test_single_range_no_merge()
    test_two_adjacent_no_gap_merged()
    test_two_within_gap_merged()
    test_two_beyond_gap_not_merged()
    test_three_ranges_chain_merge()
    test_three_ranges_chain_breaks_at_middle_gap()
    test_input_sorted_by_start()
    test_overlapping_ranges_merged()
    test_max_request_bytes_prevents_oversized_merge()
    test_wasted_bytes_assertion_demonstrates_gap_waste()
    test_offset_without_object_size_raises()
    test_suffix_without_object_size_raises()
    test_suffix_with_object_size_resolves()
    test_offset_with_object_size_resolves()
    test_dst_offsets_preserved_after_sort_and_merge()
    print("OK")
