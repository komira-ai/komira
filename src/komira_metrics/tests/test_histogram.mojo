# =============================================================================
# test_histogram.mojo — the distribution instrument
# =============================================================================
#
# SCOPE. `HistogramValue`, `HistogramPoint`, `HistogramTable` /
# `HistogramTables` and the bucket function. The SWEEP's histogram arm --
# reduction across 64 workers, the shared batch ceiling, the delta reset -- is
# in `test_metric_sweep.mojo` beside the scalar cases it shares a generation
# with.
#
# WHY THIS INSTRUMENT AT ALL: without it nothing records a distribution.
# `MetricsSet.Time` looks like a latency instrument and is a SUM, and a sum has
# no distribution to recover -- so a p99 is inexpressible.
#
# THE FOUR PROPERTIES WORTH TESTING, each silent when wrong:
#
#   1. THE BOUNDS AND THE BUCKET FUNCTION ARE TWO SPELLINGS OF ONE LIST.
#      `histogram_bound(i)` is what an exporter writes; `histogram_bucket_index`
#      is where the observation went. A drift between them puts observations in
#      a bucket whose exported bound says something else -- and BOTH outputs
#      stay well-formed, so nothing surfaces.
#
#   2. THE BOUNDS ARE INCLUSIVE UPPER BOUNDS. `v == bound` belongs to THAT
#      bucket, `v == bound + 1` to the next. Off by one here shifts an entire
#      distribution by one bucket, which reads as a real latency change.
#
#   3. BUCKET COUNTS ARE ADDITIVE, and that is the only reason a histogram can
#      be reduced across 64 per-worker tables at all. A percentile is not
#      additive; this is why the buckets are what is stored.
#
#   4. min/max ARE STORED, NOT DERIVED. A bucketed distribution cannot recover
#      them -- every observation past the last bound is "greater than 1000" and
#      nothing more.
#
# Encapsulation: POD values and a `Slab`-owning table. No
# `UnsafePointer` anywhere in this file.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_metrics.histogram import (
    _HISTOGRAM_POINT_SIZE_GUARD,
    _HISTOGRAM_TABLE_SIZE_GUARD,
    _HISTOGRAM_VALUE_SIZE_GUARD,
    histogram_bound,
    histogram_bucket_index,
    histogram_point,
    HISTOGRAM_BITSET_WORDS,
    HISTOGRAM_BOUNDS,
    HISTOGRAM_BUCKETS,
    HISTOGRAM_MAX_PROBE,
    HISTOGRAM_SLOT_NONE,
    HistogramPoint,
    HistogramTable,
    HistogramTables,
    HistogramValue,
    MAX_HISTOGRAM_SERIES_PER_WORKER,
)
from komira_metrics.metric_point import METRIC_HISTOGRAM
from komira_metrics.metrics_set import MAX_WORKERS


comptime SCOPE: UInt32 = UInt32(0x5C09E)


# =============================================================================
# THE BUCKETS
# =============================================================================


def test_the_bounds_and_the_bucket_function_are_ONE_list() raises -> None:
    """⭐ THE DRIFT GUARD. Both are hand-written comparison chains -- unrolled
    on purpose, because building an 11-element array per observation would be
    the whole hot-path budget -- so nothing but this test keeps them in step."""
    for i in range(HISTOGRAM_BOUNDS):
        var b = histogram_bound(i)
        assert_equal(
            histogram_bucket_index(b),
            i,
            "the value AT bound #" + String(i) + " lands in bucket " + String(i),
        )
        assert_equal(
            histogram_bucket_index(b + Int64(1)),
            i + 1,
            "and one PAST bound #" + String(i) + " lands in the next bucket",
        )


def test_the_bounds_ascend_strictly() raises -> None:
    """A non-monotone bound list makes the comparison chain unreachable past
    the inversion, and every observation beyond it piles into one bucket."""
    for i in range(1, HISTOGRAM_BOUNDS):
        assert_true(
            histogram_bound(i) > histogram_bound(i - 1),
            "bound #" + String(i) + " exceeds its predecessor",
        )


def test_there_are_TWELVE_buckets_and_the_last_is_plus_infinity() raises -> None:
    """The record-size arithmetic is built on this count: 12 x 8 B + a 20 B header =
    116 B > `ARG_INLINE_BYTES` 48, so a default-bucket histogram record ALWAYS
    takes the ring-arena path. Change the count and that sentence changes."""
    assert_equal(HISTOGRAM_BOUNDS, 11, "eleven bounds")
    assert_equal(HISTOGRAM_BUCKETS, 12, "twelve buckets")
    assert_equal(
        histogram_bucket_index(Int64(1_000_000_000)),
        HISTOGRAM_BOUNDS,
        "anything past the last bound is the +Inf bucket",
    )
    var p = HistogramPoint()
    assert_true(
        not Bool(p.bucket_upper_bound(HISTOGRAM_BOUNDS)),
        "the +Inf bucket has NO upper bound -- rendering one as a large integer"
        " would make it look bounded",
    )
    assert_equal(
        Int(p.bucket_upper_bound(0).value()),
        0,
        "and every other bucket does have one",
    )
    assert_true(
        not Bool(p.bucket_upper_bound(HISTOGRAM_BUCKETS)),
        "an out-of-range bucket is None, not a wrapped bound",
    )


def test_negative_and_zero_land_in_the_first_bucket() raises -> None:
    """The first bound is 0, so `v <= 0` is bucket 0. A negative duration is
    nonsense but a negative measurement is not, and it must not fall off the
    front of the chain into the +Inf bucket."""
    assert_equal(histogram_bucket_index(Int64(0)), 0, "zero")
    assert_equal(histogram_bucket_index(Int64(-1)), 0, "minus one")
    assert_equal(histogram_bucket_index(Int64(-1_000_000)), 0, "very negative")


# =============================================================================
# THE ACCUMULATOR
# =============================================================================


def test_record_accumulates_count_sum_min_max_and_ONE_bucket() raises -> None:
    var h = HistogramValue()
    h.record(Int64(7))
    h.record(Int64(3))
    h.record(Int64(900))
    assert_equal(Int(h.count), 3, "three observations")
    assert_equal(Int(h.sum), 910, "7 + 3 + 900")
    assert_equal(Int(h.min), 3, "min")
    assert_equal(Int(h.max), 900, "max")
    assert_equal(Int(h.buckets[1]), 1, "3 is in bucket 1 (v <= 5)")
    assert_equal(Int(h.buckets[2]), 1, "7 is in bucket 2 (v <= 10)")
    assert_equal(Int(h.buckets[10]), 1, "900 is in bucket 10 (v <= 1000)")
    var total = UInt64(0)
    for i in range(HISTOGRAM_BUCKETS):
        total += h.buckets[i]
    assert_equal(
        Int(total),
        3,
        "the buckets sum to the count -- an observation lands in EXACTLY one",
    )


def test_min_and_max_are_STORED_because_buckets_cannot_recover_them() raises -> None:
    """Every observation here is in the +Inf bucket, so the distribution alone
    says only 'all three exceed 1000'."""
    var h = HistogramValue()
    h.record(Int64(5000))
    h.record(Int64(1_000_000))
    h.record(Int64(2000))
    assert_equal(
        Int(h.buckets[HISTOGRAM_BOUNDS]), 3, "all three in the +Inf bucket"
    )
    assert_equal(Int(h.min), 2000, "and the min survives anyway")
    assert_equal(Int(h.max), 1_000_000, "and the max")


def test_a_zero_observation_value_is_not_a_zero_observation_COUNT() raises -> None:
    """`min`/`max` of an EMPTY value are 0, which is indistinguishable from a
    single observation of 0. The file header says to read `count` first; this
    pins that it is the only way."""
    var empty = HistogramValue()
    assert_equal(Int(empty.count), 0, "empty")
    assert_equal(Int(empty.min), 0, "with min 0")
    var one = HistogramValue()
    one.record(Int64(0))
    assert_equal(Int(one.count), 1, "one observation of zero")
    assert_equal(Int(one.min), 0, "with the SAME min 0 -- only count separates")
    assert_equal(Int(one.buckets[0]), 1, "and a bucket that empty does not have")


def test_merge_is_ADDITIVE_which_is_why_a_histogram_reduces_at_all() raises -> None:
    var a = HistogramValue()
    a.record(Int64(1))
    a.record(Int64(1000))
    var b = HistogramValue()
    b.record(Int64(1))
    b.record(Int64(99999))
    a.merge(b)
    assert_equal(Int(a.count), 4, "counts add")
    assert_equal(Int(a.sum), 101001, "sums add")
    assert_equal(Int(a.min), 1, "min is the min of mins")
    assert_equal(Int(a.max), 99999, "max is the max of maxes")
    assert_equal(Int(a.buckets[1]), 2, "bucket counts add")
    assert_equal(Int(a.buckets[10]), 1, "and the rest are preserved")
    assert_equal(Int(a.buckets[HISTOGRAM_BOUNDS]), 1, "including +Inf")


def test_merging_an_EMPTY_value_does_not_drag_min_to_zero() raises -> None:
    """The bug this guard exists for: a naive `min(self.min, other.min)` over
    an empty `other` whose min is 0 would report a minimum of 0 for a series
    whose smallest observation was 500 -- and 0 is a plausible latency, so
    nothing looks wrong."""
    var a = HistogramValue()
    a.record(Int64(500))
    a.record(Int64(700))
    a.merge(HistogramValue())
    assert_equal(Int(a.count), 2, "the empty side adds nothing")
    assert_equal(Int(a.min), 500, "and does NOT drag the min to 0")
    assert_equal(Int(a.max), 700, "nor the max")
    # And the other direction: an empty accumulator taking a real merge adopts
    # its bounds rather than keeping its own zeroes.
    var e = HistogramValue()
    e.merge(a)
    assert_equal(Int(e.min), 500, "an EMPTY accumulator adopts the merged min")
    assert_equal(Int(e.max), 700, "and max")


def test_reset_zeroes_everything_including_every_bucket() raises -> None:
    var h = HistogramValue()
    for i in range(200):
        h.record(Int64(i))
    h.reset()
    assert_equal(Int(h.count), 0, "count")
    assert_equal(Int(h.sum), 0, "sum")
    assert_equal(Int(h.min), 0, "min")
    assert_equal(Int(h.max), 0, "max")
    for i in range(HISTOGRAM_BUCKETS):
        assert_equal(
            Int(h.buckets[i]), 0, "bucket " + String(i) + " -- ALL of them"
        )


# =============================================================================
# THE TABLE
# =============================================================================


def test_the_table_keys_by_name_AND_attrset_like_the_series_table() raises -> None:
    var t = HistogramTables()
    _ = t.record(0, UInt32(1), SCOPE, UInt32(10), Int64(5))
    _ = t.record(0, UInt32(1), SCOPE, UInt32(20), Int64(900))
    _ = t.record(0, UInt32(2), SCOPE, UInt32(10), Int64(900))
    assert_equal(t.live_series(), 3, "three distinct series")
    assert_equal(Int(t.reduce(UInt32(1), UInt32(10)).buckets[1]), 1, "A")
    assert_equal(Int(t.reduce(UInt32(1), UInt32(20)).buckets[10]), 1, "B")
    assert_equal(
        Int(t.reduce(UInt32(1), UInt32(30)).count),
        0,
        "a series nobody touched is EMPTY, not a neighbour's distribution",
    )


def test_the_reduction_folds_every_worker() raises -> None:
    var t = HistogramTables()
    for w in range(MAX_WORKERS):
        _ = t.record(w, UInt32(1), SCOPE, UInt32(0), Int64(w))
    var r = t.reduce(UInt32(1), UInt32(0))
    assert_equal(Int(r.count), MAX_WORKERS, "64 observations, one per worker")
    assert_equal(Int(r.sum), 2016, "0+1+...+63")
    assert_equal(Int(r.min), 0, "min across workers")
    assert_equal(Int(r.max), 63, "max across workers")


def test_a_scope_conflict_is_refused_and_counted() raises -> None:
    var t = HistogramTables()
    _ = t.record(0, UInt32(1), UInt32(111), UInt32(0), Int64(5))
    assert_false(
        t.record(0, UInt32(1), UInt32(222), UInt32(0), Int64(5)),
        "the same series under a different scope is REFUSED",
    )
    assert_equal(t.num_conflicts(), 1, "and counted")
    assert_equal(
        Int(t.reduce(UInt32(1), UInt32(0)).count),
        1,
        "the refusal recorded nothing",
    )


def test_a_full_table_REFUSES_and_counts() raises -> None:
    var t = HistogramTables()
    var accepted = 0
    var refused = 0
    for i in range(3 * MAX_HISTOGRAM_SERIES_PER_WORKER):
        if t.record(0, UInt32(i), SCOPE, UInt32(0), Int64(1)):
            accepted += 1
        else:
            refused += 1
    assert_true(refused > 0, "a 3x oversubscribed table refuses")
    assert_equal(t.num_overflowed(), refused, "every refusal counted once")
    assert_equal(
        accepted, t.live_series(), "and every acceptance claimed its own slot"
    )
    assert_true(
        accepted <= MAX_HISTOGRAM_SERIES_PER_WORKER, "the ceiling holds"
    )


def test_take_slot_delta_zeroes_the_distribution_and_KEEPS_the_slot() raises -> None:
    var t = HistogramTables()
    _ = t.record(0, UInt32(1), SCOPE, UInt32(0), Int64(7))
    _ = t.record(0, UInt32(1), SCOPE, UInt32(0), Int64(7))
    var idx = t.next_occupied(0, 0)
    assert_true(idx != HISTOGRAM_SLOT_NONE, "the slot is findable")
    var taken = t.take_slot_delta(0, idx)
    assert_equal(Int(taken.count), 2, "the distribution comes out whole")
    assert_equal(Int(taken.buckets[2]), 2, "with its buckets")
    assert_equal(
        Int(t.reduce(UInt32(1), UInt32(0)).count),
        0,
        "and the source is now empty",
    )
    assert_equal(t.live_series(), 1, "but the SLOT survives")
    _ = t.record(0, UInt32(1), SCOPE, UInt32(0), Int64(7))
    assert_equal(
        Int(t.reduce(UInt32(1), UInt32(0)).count),
        1,
        "the next interval accumulates from zero, not from 2",
    )


def test_a_RECLAIMED_slot_does_not_inherit_the_previous_distribution() raises -> None:
    """`clear()` zeroes only occupancy and counters -- the 32 KiB of value bytes
    stay. So `_slot_for` has to write a FRESH `HistogramValue` when it claims a
    slot, or a new series silently starts with a dead one's buckets."""
    var t = HistogramTable()
    for _ in range(50):
        _ = t.record(UInt32(1), SCOPE, UInt32(0), Int64(900))
    var before = t.lookup(UInt32(1), UInt32(0))
    assert_equal(Int(before.value().count), 50, "50 observations recorded")
    t.clear()
    assert_equal(t.live_count(), 0, "cleared")
    # Re-record the SAME key, so it lands in the SAME slot it just vacated.
    _ = t.record(UInt32(1), SCOPE, UInt32(0), Int64(1))
    var after = t.lookup(UInt32(1), UInt32(0))
    assert_equal(
        Int(after.value().count),
        1,
        "the re-claimed slot starts at ONE, not at 51",
    )
    assert_equal(
        Int(after.value().buckets[10]),
        0,
        "and carries none of the dead series' buckets",
    )


def test_next_occupied_enumerates_exactly_the_occupied_slots() raises -> None:
    var t = HistogramTables()
    for i in range(29):
        _ = t.record(0, UInt32(100 + i), SCOPE, UInt32(0), Int64(1))
    var seen = 0
    var idx = t.next_occupied(0, 0)
    var last = -1
    while idx != HISTOGRAM_SLOT_NONE:
        assert_true(idx > last, "strictly ascending")
        last = idx
        seen += 1
        idx = t.next_occupied(0, idx + 1)
    assert_equal(seen, 29, "every occupied slot, exactly once")


def test_an_out_of_range_worker_is_refused_not_wrapped() raises -> None:
    var t = HistogramTables()
    assert_false(
        t.record(MAX_WORKERS, UInt32(1), SCOPE, UInt32(0), Int64(1)),
        "worker_id == MAX_WORKERS is refused",
    )
    assert_false(
        t.record(-1, UInt32(1), SCOPE, UInt32(0), Int64(1)),
        "a negative worker_id is refused",
    )
    assert_equal(t.live_series(), 0, "nothing was written anywhere")


# =============================================================================
# THE POINT
# =============================================================================


def test_a_histogram_point_carries_the_whole_distribution() raises -> None:
    var h = HistogramValue()
    h.record(Int64(3))
    h.record(Int64(60))
    h.record(Int64(99999))
    var p = histogram_point(
        UInt32(11), UInt32(22), UInt32(33), h, UInt64(1000), UInt64(2000)
    )
    assert_equal(Int(p.name_id), 11, "name")
    assert_equal(Int(p.scope_id), 22, "scope")
    assert_equal(Int(p.attrset_id), 33, "attrset")
    assert_equal(
        Int(p.kind),
        Int(METRIC_HISTOGRAM),
        "the kind is carried even though it is constant -- a consumer's CLOSED"
        " discriminant switch has to work over both record shapes",
    )
    assert_equal(Int(p.start_time_unix_ns), 1000, "interval start")
    assert_equal(Int(p.time_unix_ns), 2000, "interval end")
    assert_equal(Int(p.count), 3, "count")
    assert_equal(Int(p.sum), 100062, "sum")
    assert_equal(Int(p.min), 3, "min")
    assert_equal(Int(p.max), 99999, "max")
    assert_equal(Int(p.bucket(1)), 1, "3 -> bucket 1")
    assert_equal(Int(p.bucket(5)), 1, "60 -> bucket 5 (v <= 75)")
    assert_equal(Int(p.bucket(HISTOGRAM_BOUNDS)), 1, "99999 -> +Inf")


def test_the_size_guards_are_the_bytes_the_header_arithmetic_claims() raises -> None:
    assert_equal(
        _HISTOGRAM_VALUE_SIZE_GUARD,
        128,
        "_HISTOGRAM_VALUE_SIZE_GUARD is 128 B -- 8 count + 8 sum + 8 min + 8"
        " max + 12 x 8 buckets",
    )
    assert_equal(
        _HISTOGRAM_VALUE_SIZE_GUARD,
        size_of[HistogramValue](),
        "the guard IS size_of[HistogramValue]()",
    )
    assert_equal(
        _HISTOGRAM_POINT_SIZE_GUARD,
        size_of[HistogramPoint](),
        "the guard IS size_of[HistogramPoint]()",
    )
    assert_equal(
        MAX_HISTOGRAM_SERIES_PER_WORKER,
        256,
        "256 -- NOT the scalar table's 4096: a 128 B value at 4096 slots would"
        " be 32 MiB per process, six times the ENTIRE scalar table",
    )
    assert_equal(HISTOGRAM_BITSET_WORDS, 4, "256 slots == 4 x 64-bit words")
    assert_equal(HISTOGRAM_MAX_PROBE, 32, "the hot-path probe cap")
    assert_equal(
        _HISTOGRAM_TABLE_SIZE_GUARD,
        35888,
        "_HISTOGRAM_TABLE_SIZE_GUARD is 35888 B = 35.0 KiB -- the number the"
        " header's 2.19 MiB per process is derived FROM. If this changed, fix"
        " the header's arithmetic; do not just update the number.",
    )
    assert_equal(
        _HISTOGRAM_TABLE_SIZE_GUARD * MAX_WORKERS,
        2296832,
        "2296832 B = 2.19 MiB per process",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
