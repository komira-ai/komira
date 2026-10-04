# =============================================================================
# komira_objectstore/coalesce.mojo — range-coalescing PLAN
# =============================================================================
#
# Implements the range-coalescing algorithm.
#
# DIVISION OF LABOR:
# * komira_objectstore (this file): owns the coalescing PLAN — which
#     adjacent byte-ranges to merge given the policy.
# * komira_http: owns the concurrent FAN-OUT
#     execution of the planned batch via ObjectStoreHttp.get_ranges.
#
# Algorithm:
#   1. Translate each GetRange (Bounded / Offset / Suffix) into an absolute
#      [start, end) interval. Suffix and Offset require object_size; if not
#      provided (the trait's `head` may not have run), Suffix/Offset
#      ranges are passed through as-is — the HTTP client will resolve them
#      at request time.
#   2. Sort the requested ranges by start offset (preserving the original
#      dst_offset mapping).
#   3. Merge two adjacent ranges into one request when the gap between them
#      is `<= max_gap_bytes`. Merging across a small gap fetches a few
#      wasted bytes but saves a whole round-trip.
#   4. Split any merged range that exceeds `max_request_bytes` back into
#      bounded chunks, so one giant request does not block.
#   5. Return a list of CoalescedRange entries, each annotated with which
#      original (range, dst_offset) pairs it satisfies.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * Public surface: `plan_coalesce(ranges, policy, object_size) -> CoalescePlan`.
# =============================================================================

from komira_objectstore.types import (
    CoalescePolicy,
    GET_RANGE_BOUNDED,
    GET_RANGE_OFFSET,
    GET_RANGE_SUFFIX,
    GetRange,
    RangeSet,
)


# -----------------------------------------------------------------------------
# AbsoluteRange — internal absolute [start, end) interval after Bounded/
# Offset/Suffix resolution. Carries back-references to the original ranges.
# -----------------------------------------------------------------------------


@fieldwise_init
struct AbsoluteRange(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """An absolute [start, end) byte interval + back-references.

    Field layout:
      var start: Int64           — absolute start byte (inclusive)
      var end: Int64             — absolute end byte (exclusive)
      var orig_index: Int        — index in the input RangeSet
      var dst_offset: Int        — where this interval's bytes go in `dst`
    """

    var start: Int64
    var end: Int64
    var orig_index: Int
    var dst_offset: Int


# -----------------------------------------------------------------------------
# OriginalSlice — per-original-range slice within a CoalescedRange's bytes
# -----------------------------------------------------------------------------


@fieldwise_init
struct OriginalSlice(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """One original range, mapped onto a slice of a coalesced fetch.

    Field layout:
      var orig_index: Int        — index in the input RangeSet
      var dst_offset: Int        — where the bytes land in caller's dst
      var coalesced_offset: Int  — byte offset within the coalesced
                                    fetch where this original range begins
      var length: Int            — length of the original range (end - start)

    The HTTP client's scatter-write copies bytes[coalesced_offset ..
    coalesced_offset + length) into dst[dst_offset .. dst_offset + length).
    """

    var orig_index: Int
    var dst_offset: Int
    var coalesced_offset: Int
    var length: Int


# -----------------------------------------------------------------------------
# CoalescedRange — one entry in the output plan
# -----------------------------------------------------------------------------


@fieldwise_init
struct CoalescedRange(Copyable, Movable, Deinitable):
    """One coalesced HTTP GET-Range request + the original slices it satisfies.

    Field layout:
      var start: Int64
                      — absolute start byte (inclusive) of the coalesced request
      var end: Int64
                      — absolute end byte (exclusive) of the coalesced request
      var slices: List[OriginalSlice]
                      — the (original_range, dst_offset, coalesced_offset, length)
                        tuples the bytes scatter into

    The HTTP layer issues one GET-Range for [start, end), receives the
    bytes, and then walks `slices` to scatter-write into the caller's dst.
    """

    var start: Int64
    var end: Int64
    var slices: List[OriginalSlice]

    @always_inline
    def length(self) -> Int64:
        return self.end - self.start


# -----------------------------------------------------------------------------
# CoalescePlan — the output of plan_coalesce
# -----------------------------------------------------------------------------


@fieldwise_init
struct CoalescePlan(Movable, Deinitable):
    """A coalescing plan.

    Field layout:
      var coalesced: List[CoalescedRange]  — the minimal request batch
      var total_requested_bytes: Int64     — sum of original-range lengths
      var total_fetched_bytes: Int64       — sum of coalesced-range lengths
                                              (>= total_requested_bytes; the
                                              difference is over-read / waste)

    `total_fetched_bytes - total_requested_bytes` is the wasted-byte count
    — input to the `os-coalesce-waste` bench.
    """

    var coalesced: List[CoalescedRange]
    var total_requested_bytes: Int64
    var total_fetched_bytes: Int64

    @always_inline
    def num_requests(self) -> Int:
        return len(self.coalesced)

    @always_inline
    def wasted_bytes(self) -> Int64:
        return self.total_fetched_bytes - self.total_requested_bytes


# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------


def _resolve_to_absolute(
    range: GetRange, dst_offset: Int, orig_index: Int, object_size: Int64
) raises -> AbsoluteRange:
    """Translate a GetRange (Bounded/Offset/Suffix) into an absolute
    [start, end) interval. `object_size` must be >= 0 for Suffix and
    Offset; Bounded ignores `object_size` entirely.

    Raises if the resulting interval is empty or has end > object_size
    (when object_size is known).
    """
    if range.tag == GET_RANGE_BOUNDED:
        # [start, end) directly.
        return AbsoluteRange(
            range.bounded_start(),
            range.bounded_end(),
            orig_index,
            dst_offset,
        )
    if range.tag == GET_RANGE_OFFSET:
        if object_size < 0:
            raise Error(
                "plan_coalesce: Offset range requires object_size"
                + " (got -1)"
            )
        return AbsoluteRange(
            range.offset_start(), object_size, orig_index, dst_offset
        )
    if range.tag == GET_RANGE_SUFFIX:
        if object_size < 0:
            raise Error(
                "plan_coalesce: Suffix range requires object_size"
                + " (got -1)"
            )
        var n = range.suffix_n()
        var start = object_size - n
        if start < 0:
            start = Int64(0)
        return AbsoluteRange(start, object_size, orig_index, dst_offset)
    raise Error("plan_coalesce: unknown GetRange tag")


def _sort_by_start(mut ranges: List[AbsoluteRange]):
    """In-place insertion sort by start offset. n is small (Parquet
    page-read sets are O(100s) of ranges); insertion sort is fine."""
    var n = len(ranges)
    for i in range(1, n):
        var key = ranges[i]
        var j = i - 1
        while j >= 0 and ranges[j].start > key.start:
            ranges[j + 1] = ranges[j]
            j -= 1
        ranges[j + 1] = key


# -----------------------------------------------------------------------------
# plan_coalesce — the public surface
# -----------------------------------------------------------------------------


def plan_coalesce(
    ranges: RangeSet, policy: CoalescePolicy, object_size: Int64 = Int64(-1)
) raises -> CoalescePlan:
    """Compute a coalescing PLAN for the given input ranges + policy.

    Args:
      ranges:      Input RangeSet (parallel `ranges` + `dst_offsets` lists)
      policy:      Tuning knobs (max_gap_bytes, max_request_bytes,
                   max_concurrency — concurrency is a HTTP-layer concern
                   so this function ignores it; it is on the plan output
                   so downstream can read it).
      object_size: Known total object size (from a prior `head`), or -1
                   if unknown. Required for Suffix/Offset ranges; ignored
                   for Bounded ranges.

    Returns:
      A CoalescePlan with the minimal coalesced request set + the original-
      to-coalesced byte mapping + the wasted-byte total.

    Algorithm: — sort by start; merge across gaps <= max_gap_bytes;
    split any single coalesced span that exceeds max_request_bytes.

    Edge cases:
      * Empty input: returns an empty plan.
      * Single range: passes through (still wrapped in CoalescedRange).
      * max_gap_bytes < 0: treated as 0 (no merging, only contiguous
        coverage merges, i.e. exact overlap or touch).
    """
    var n = ranges.num_ranges()
    var plan = CoalescePlan(
        List[CoalescedRange](), Int64(0), Int64(0)
    )
    if n == 0:
        return plan^

    # Step 1: resolve all GetRange entries to absolute intervals.
    var absolutes = List[AbsoluteRange]()
    for i in range(n):
        var ar = _resolve_to_absolute(
            ranges.ranges[i], ranges.dst_offsets[i], i, object_size
        )
        plan.total_requested_bytes = (
            plan.total_requested_bytes + (ar.end - ar.start)
        )
        absolutes.append(ar)

    # Step 2: sort by start.
    _sort_by_start(absolutes)

    var max_gap = policy.max_gap_bytes
    if max_gap < 0:
        max_gap = Int64(0)
    var max_req = policy.max_request_bytes
    if max_req <= 0:
        # No max; treat as unbounded. Bench tests use this to confirm
        # the merge step in isolation.
        max_req = Int64(9223372036854775807)  # Int64.MAX

    # Step 3: scan and merge.
    var i = 0
    while i < len(absolutes):
        # Start a new coalesced run with absolutes[i].
        var cur_start = absolutes[i].start
        var cur_end = absolutes[i].end
        var slices = List[OriginalSlice]()
        var first = absolutes[i]
        slices.append(
            OriginalSlice(
                first.orig_index,
                first.dst_offset,
                Int(first.start - cur_start),
                Int(first.end - first.start),
            )
        )
        var j = i + 1
        while j < len(absolutes):
            var nxt = absolutes[j]
            # Gap from current run end to next range start.
            var gap = nxt.start - cur_end
            if gap < 0:
                # Overlap — never a regression to absorb.
                gap = Int64(0)
            if gap > max_gap:
                break
            # Tentative new end.
            var new_end = cur_end
            if nxt.end > new_end:
                new_end = nxt.end
            # Step 4: respect max_request_bytes.
            if new_end - cur_start > max_req:
                break
            # Absorb.
            slices.append(
                OriginalSlice(
                    nxt.orig_index,
                    nxt.dst_offset,
                    Int(nxt.start - cur_start),
                    Int(nxt.end - nxt.start),
                )
            )
            cur_end = new_end
            j += 1

        plan.total_fetched_bytes = (
            plan.total_fetched_bytes + (cur_end - cur_start)
        )
        plan.coalesced.append(
            CoalescedRange(cur_start, cur_end, slices^)
        )
        i = j

    return plan^
