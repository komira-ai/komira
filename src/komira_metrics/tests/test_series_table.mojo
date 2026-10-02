# =============================================================================
# test_series_table.mojo — THE PER-WORKER SERIES TABLE
# =============================================================================
#
# SCOPE. `SeriesTable` / `SeriesTables` only. The SWEEP that reduces these
# tables into `MetricPoint`s -- and the one-record-per-(series, interval)
# invariant -- is `test_metric_sweep.mojo`.
#
# THE FOUR PROPERTIES WORTH TESTING, because every one of them is SILENT when
# it is wrong:
#
#   1. THE HASH MUST MIX. `key = (name_id << 32) | attrset_id`, so an index
#      taken as `key & (N-1)` is `attrset_id` ALONE. Every metric sharing one
#      attribute set would then land on ONE home slot and the bounded probe
#      would start refusing at 64 distinct names. That is not a distribution
#      nicety -- it is the difference between "one hash and one probe" (the
#      hot-path claim) and a refusal.
#
#   2. A CONFLICT IS REFUSED, NEVER OVERWRITTEN. A slot holding a COUNTER,
#      written as a GAUGE, is two instruments measuring one series. Overwriting
#      is the same corruption as a `MetricsSet` lookup miss returning slot 0,
#      where an unregistered name would increment a REAL unrelated metric.
#
#   3. A REFUSAL IS COUNTED. `n_overflowed` / `n_conflicts` non-zero means
#      observations were LOST. A refusal nothing counts is indistinguishable
#      from a code path that never ran.
#
#   4. THE RESET KEEPS THE SLOT. `take_slot_delta` zeroes the value and leaves
#      the slot OCCUPIED -- the series still exists, it just has no unexported
#      observations. A reset that freed the slot would make a hot series
#      re-insert every interval and would churn the probe.
#
# Encapsulation: `SeriesTables` owns a `Slab`; every value here is POD
# and stack-local. No `UnsafePointer` anywhere in this file.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_metrics.metric_point import (
    METRIC_COUNTER,
    METRIC_GAUGE,
    METRIC_HISTOGRAM,
    METRIC_UPDOWNCOUNTER,
)
from komira_metrics.metrics_set import MAX_WORKERS
from komira_metrics.series_table import (
    _SERIES_ENTRY_SIZE_GUARD,
    _SERIES_TABLE_SIZE_GUARD,
    MAX_SERIES_PER_WORKER,
    SERIES_BITSET_WORDS,
    SERIES_MAX_PROBE,
    SERIES_SLOT_NONE,
    SeriesEntry,
    SeriesTable,
    SeriesTables,
    series_key,
    series_key_attrset_id,
    series_key_name_id,
)


# A scope id used throughout. Any non-zero value; the point is that it is the
# SAME one, so a scope conflict has to be provoked deliberately.
comptime SCOPE: UInt32 = UInt32(0xABCD1234)


def test_the_key_round_trips_both_halves() raises -> None:
    """`series_key` is a LOSSLESS composition, not a digest -- `_slot_for`
    compares keys for equality, so a lossy key would merge two series."""
    var k = series_key(UInt32(0xDEADBEEF), UInt32(0x01020304))
    assert_equal(
        Int(series_key_name_id(k)),
        0xDEADBEEF,
        "the high half of the key is name_id",
    )
    assert_equal(
        Int(series_key_attrset_id(k)),
        0x01020304,
        "the low half of the key is attrset_id",
    )
    # The two boundary cases: an all-zero key is LEGAL (name_id 0 with the
    # empty attribute set), which is exactly why occupancy is a bitset and not
    # `key != 0`.
    var z = series_key(UInt32(0), UInt32(0))
    assert_equal(Int(z), 0, "the all-zero key is a legal key, not a sentinel")


def test_a_single_worker_accumulates_and_reduces() raises -> None:
    var t = SeriesTables()
    for _ in range(1000):
        assert_true(
            t.add(3, UInt32(11), SCOPE, UInt32(22), METRIC_COUNTER, Int64(2)),
            "an ordinary counter add is accepted",
        )
    assert_equal(
        Int(t.reduce_sum(UInt32(11), UInt32(22))),
        2000,
        "1000 adds of 2 reduce to 2000",
    )
    # ONE occupied slot, on ONE worker. The 1000 observations did not create
    # 1000 anything -- which is the storage half of amendment 2.
    assert_equal(t.live_series(), 1, "1000 observations occupy ONE slot")
    assert_equal(t.num_overflowed(), 0, "no refusal")
    assert_equal(t.num_conflicts(), 0, "no conflict")


def test_the_reduction_spans_workers_the_way_counter_reduce_does() raises -> None:
    """The export sweep reduces across the 64 tables, exactly as
    `Counter.reduce()` reduces across the 64 slots."""
    var t = SeriesTables()
    for w in range(MAX_WORKERS):
        for _ in range(10):
            _ = t.add(
                w, UInt32(7), SCOPE, UInt32(0), METRIC_COUNTER, Int64(w + 1)
            )
    # sum over w of 10*(w+1), w in [0,64) == 10 * (64*65/2) == 20800
    assert_equal(
        Int(t.reduce_sum(UInt32(7), UInt32(0))),
        20800,
        "the reduction sums every worker's private slot",
    )
    assert_equal(
        t.live_series(),
        MAX_WORKERS,
        "ONE series touched by 64 workers occupies 64 slots -- live_series"
        " counts SLOTS, not distinct series",
    )


def test_a_different_attrset_is_a_different_series() raises -> None:
    var t = SeriesTables()
    _ = t.add(0, UInt32(5), SCOPE, UInt32(100), METRIC_COUNTER, Int64(3))
    _ = t.add(0, UInt32(5), SCOPE, UInt32(200), METRIC_COUNTER, Int64(4))
    assert_equal(Int(t.reduce_sum(UInt32(5), UInt32(100))), 3, "series A")
    assert_equal(Int(t.reduce_sum(UInt32(5), UInt32(200))), 4, "series B")
    assert_equal(t.live_series(), 2, "two attrsets, two slots")


def test_a_series_never_touched_reduces_to_zero_not_to_someone_elses_value() raises -> None:
    """A lookup MISS must be a miss. If it fell through to a neighbouring slot
    (as a `MetricsSet` miss falling through to slot 0 would), an unregistered
    series would report a real metric's value."""
    var t = SeriesTables()
    _ = t.add(0, UInt32(5), SCOPE, UInt32(100), METRIC_COUNTER, Int64(4242))
    assert_equal(
        Int(t.reduce_sum(UInt32(5), UInt32(101))),
        0,
        "an adjacent attrset_id reads 0, NOT the neighbour's 4242",
    )
    assert_equal(
        Int(t.reduce_sum(UInt32(6), UInt32(100))),
        0,
        "an adjacent name_id reads 0, NOT the neighbour's 4242",
    )


def test_512_names_sharing_ONE_attrset_all_get_their_own_slot() raises -> None:
    """⭐ THE MIXING TEST, AND IT IS THE ONE THAT FALSIFIES A MISSING `_mix64`.

    Every one of these series has attrset_id 0. Indexed by the raw key, all 512
    share home slot 0, the bounded probe gives up after `SERIES_MAX_PROBE` = 64,
    and the 65th name onward is REFUSED. With the mix they scatter and all 512
    land.

    ⚠ THE CONTROL IS THE VALUE CHECK, NOT THE REFUSAL COUNT. A table that
    accepted every write but stored them all in one slot would pass a
    `n_overflowed == 0` assertion; only reading each series back separately
    catches it."""
    var t = SeriesTables()
    for i in range(512):
        assert_true(
            t.add(
                0,
                UInt32(1000 + i),
                SCOPE,
                UInt32(0),
                METRIC_COUNTER,
                Int64(i + 1),
            ),
            "name #" + String(i) + " sharing attrset 0 is accepted",
        )
    assert_equal(
        t.num_overflowed(),
        0,
        "512 names on ONE attrset overflow nothing -- WITHOUT the mix, name 65"
        " onward is refused",
    )
    assert_equal(t.live_series(), 512, "512 distinct slots")
    for i in range(512):
        assert_equal(
            Int(t.reduce_sum(UInt32(1000 + i), UInt32(0))),
            i + 1,
            "series #" + String(i) + " holds its OWN value",
        )


def test_a_kind_conflict_is_refused_and_counted_and_changes_nothing() raises -> None:
    var t = SeriesTables()
    assert_true(
        t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_COUNTER, Int64(77)),
        "the counter lands",
    )
    assert_false(
        t.set_gauge(0, UInt32(9), SCOPE, UInt32(0), Int64(-1)),
        "the SAME series written as a GAUGE is REFUSED",
    )
    assert_equal(
        Int(t.reduce_sum(UInt32(9), UInt32(0))),
        77,
        "and the counter still holds 77 -- the refusal wrote NOTHING",
    )
    assert_equal(t.num_conflicts(), 1, "the refusal is counted exactly once")
    # The reverse direction too, on a fresh series.
    assert_true(
        t.set_gauge(0, UInt32(10), SCOPE, UInt32(0), Int64(5)), "gauge lands"
    )
    assert_false(
        t.add(0, UInt32(10), SCOPE, UInt32(0), METRIC_COUNTER, Int64(1)),
        "the SAME series written as a COUNTER is REFUSED",
    )
    assert_equal(t.num_conflicts(), 2, "counted again")


def test_an_updowncounter_and_a_counter_are_different_kinds_and_conflict() raises -> None:
    """They are BOTH delta sums, so the arithmetic would be identical -- which
    is exactly why the refusal has to be on the KIND and not on the behaviour.
    An UPDOWNCOUNTER lowers to a different OTLP message arm (non-monotonic), so
    merging them produces a well-formed record that says the wrong thing."""
    var t = SeriesTables()
    _ = t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_COUNTER, Int64(1))
    assert_false(
        t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_UPDOWNCOUNTER, Int64(1)),
        "COUNTER and UPDOWNCOUNTER are different instruments",
    )
    assert_equal(t.num_conflicts(), 1, "counted")


def test_a_scope_conflict_is_refused_and_counted() raises -> None:
    """Scope is stored PER SLOT (see the file header's decision note), so a
    second scope on one series is detectable -- and it must be, because
    `MetricPoint.scope_id` is what joins a metric to the module's log lines."""
    var t = SeriesTables()
    _ = t.add(0, UInt32(9), UInt32(111), UInt32(0), METRIC_COUNTER, Int64(1))
    assert_false(
        t.add(0, UInt32(9), UInt32(222), UInt32(0), METRIC_COUNTER, Int64(1)),
        "the same series under a DIFFERENT scope is refused",
    )
    assert_equal(t.num_conflicts(), 1, "counted")
    assert_equal(
        Int(t.reduce_sum(UInt32(9), UInt32(0))),
        1,
        "and the original scope's value is untouched",
    )


def test_add_refuses_a_gauge_kind_outright() raises -> None:
    """`add` ACCUMULATES. A gauge is a level; summing every reading in an
    interval would report the wrong number with no error anywhere."""
    var t = SeriesTables()
    assert_false(
        t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_GAUGE, Int64(1)),
        "add() refuses METRIC_GAUGE",
    )
    assert_false(
        t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_HISTOGRAM, Int64(1)),
        "add() refuses METRIC_HISTOGRAM -- a histogram has buckets, not a sum",
    )
    assert_equal(t.num_conflicts(), 2, "both counted")
    assert_equal(t.live_series(), 0, "and neither allocated a slot")


def test_a_gauge_is_last_write_wins_and_reduces_to_the_last_worker() raises -> None:
    var t = SeriesTables()
    _ = t.set_gauge(0, UInt32(9), SCOPE, UInt32(0), Int64(10))
    _ = t.set_gauge(0, UInt32(9), SCOPE, UInt32(0), Int64(20))
    var v = t.reduce_last(UInt32(9), UInt32(0))
    assert_true(Bool(v), "the gauge is present")
    assert_equal(Int(v.value()), 20, "the LAST write wins, not the sum")
    # Two workers: ascending worker order, so the highest worker holding the
    # series wins. Arbitrary among concurrent writers -- and OTel's synchronous
    # gauge says so -- but DETERMINISTIC given a table state.
    _ = t.set_gauge(5, UInt32(9), SCOPE, UInt32(0), Int64(99))
    var v2 = t.reduce_last(UInt32(9), UInt32(0))
    assert_equal(Int(v2.value()), 99, "worker 5 outranks worker 0")
    assert_true(
        not Bool(t.reduce_last(UInt32(1234), UInt32(0))),
        "a series no worker holds reduces to None, not to 0 -- a gauge of 0 is"
        " a real level and must not be forgeable by absence",
    )


def test_take_slot_delta_zeroes_the_value_and_KEEPS_the_slot() raises -> None:
    var t = SeriesTables()
    _ = t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_COUNTER, Int64(41))
    var idx = t.next_occupied(0, 0)
    assert_true(idx != SERIES_SLOT_NONE, "the slot is findable")
    assert_equal(Int(t.take_slot_delta(0, idx)), 41, "the delta comes out")
    assert_equal(
        Int(t.reduce_sum(UInt32(9), UInt32(0))), 0, "and the value is now 0"
    )
    assert_equal(
        t.worker_live_count(0),
        1,
        "the SLOT survives -- the series still exists, it just has no"
        " unexported observations",
    )
    # And the same slot keeps accumulating without re-inserting.
    _ = t.add(0, UInt32(9), SCOPE, UInt32(0), METRIC_COUNTER, Int64(8))
    assert_equal(Int(t.reduce_sum(UInt32(9), UInt32(0))), 8, "next interval")
    assert_equal(t.worker_live_count(0), 1, "still one slot")


def test_next_occupied_enumerates_exactly_the_occupied_slots() raises -> None:
    var t = SeriesTables()
    for i in range(37):
        _ = t.add(
            0, UInt32(500 + i), SCOPE, UInt32(3), METRIC_COUNTER, Int64(1)
        )
    var seen = 0
    var idx = t.next_occupied(0, 0)
    var last = -1
    while idx != SERIES_SLOT_NONE:
        assert_true(idx > last, "next_occupied is strictly ascending")
        last = idx
        seen += 1
        idx = t.next_occupied(0, idx + 1)
    assert_equal(seen, 37, "every occupied slot is enumerated exactly once")


def test_a_full_table_REFUSES_and_counts_and_never_returns_a_wrong_slot() raises -> None:
    """The overflow arm, DRIVEN. An arm no test enters is an arm whose refusal
    has never happened.

    Filling 4096 slots via the bounded probe does not get to 4096: past a high
    load factor a new key's 64-probe run is full even though slots remain. That
    is the DESIGNED behaviour (the header explains why the probe is bounded on
    a hot path), so the assertion is on the two properties that matter -- the
    refusal is counted, and nothing accepted got the wrong value."""
    var t = SeriesTables()
    var accepted = 0
    var refused = 0
    # 3x the table size, so the refusal arm is unavoidable.
    for i in range(3 * MAX_SERIES_PER_WORKER):
        if t.add(
            0, UInt32(i), SCOPE, UInt32(0xC0DE), METRIC_COUNTER, Int64(i + 1)
        ):
            accepted += 1
        else:
            refused += 1
    assert_true(refused > 0, "a table 3x oversubscribed REFUSES")
    assert_equal(
        t.worker_num_overflowed(0),
        refused,
        "every refusal is counted exactly once",
    )
    assert_equal(
        accepted,
        t.worker_live_count(0),
        "accepted writes == occupied slots: no write landed in a slot it did"
        " not claim",
    )
    assert_true(
        accepted <= MAX_SERIES_PER_WORKER,
        "and the ceiling was never exceeded",
    )
    # THE CONTROL that a naive refusal count would miss: everything ACCEPTED
    # still reads back its own value.
    var checked = 0
    for i in range(3 * MAX_SERIES_PER_WORKER):
        var v = t.reduce_sum(UInt32(i), UInt32(0xC0DE))
        if v != Int64(0):
            assert_equal(
                Int(v), i + 1, "series #" + String(i) + " holds its OWN value"
            )
            checked += 1
    assert_equal(
        checked, accepted, "and every accepted series is readable, exactly once"
    )


def test_clear_forgets_every_series_and_every_counter() raises -> None:
    var t = SeriesTables()
    for i in range(20):
        _ = t.add(
            i % MAX_WORKERS,
            UInt32(i),
            SCOPE,
            UInt32(0),
            METRIC_COUNTER,
            Int64(1),
        )
    _ = t.add(0, UInt32(0), SCOPE, UInt32(0), METRIC_GAUGE, Int64(1))
    assert_equal(t.live_series(), 20, "20 slots before")
    assert_equal(t.num_conflicts(), 1, "and one counted refusal")
    t.clear()
    assert_equal(t.live_series(), 0, "0 slots after")
    assert_equal(t.num_conflicts(), 0, "and the counters reset with them")
    assert_equal(
        Int(t.reduce_sum(UInt32(3), UInt32(0))),
        0,
        "a cleared series reads 0, not its stale value",
    )


def test_an_out_of_range_worker_is_refused_not_wrapped() raises -> None:
    """A `worker_id` past `MAX_WORKERS` must not silently alias worker
    `id % 64` -- that is a cross-worker write, which is the one thing the
    no-atomic hot path cannot survive."""
    var t = SeriesTables()
    assert_false(
        t.add(MAX_WORKERS, UInt32(1), SCOPE, UInt32(0), METRIC_COUNTER, Int64(1)),
        "worker_id == MAX_WORKERS is refused",
    )
    assert_false(
        t.add(-1, UInt32(1), SCOPE, UInt32(0), METRIC_COUNTER, Int64(1)),
        "a negative worker_id is refused",
    )
    assert_false(
        t.set_gauge(999, UInt32(1), SCOPE, UInt32(0), Int64(1)),
        "and the gauge path refuses too",
    )
    assert_equal(t.live_series(), 0, "nothing was written anywhere")


def test_the_size_guards_are_the_bytes_the_header_arithmetic_claims() raises -> None:
    """THE `comptime _*_SIZE_GUARD` DECLARATIONS ARE READ HERE. The file
    header derives 84.5 KiB per worker and 5.28 MiB per process from these
    numbers; a guard nothing reads is a number that drifts."""
    assert_equal(
        _SERIES_ENTRY_SIZE_GUARD,
        16,
        "_SERIES_ENTRY_SIZE_GUARD is 16 B -- the table's stated stride",
    )
    assert_equal(
        _SERIES_ENTRY_SIZE_GUARD,
        size_of[SeriesEntry](),
        "the guard IS size_of[SeriesEntry](), not a number beside it",
    )
    assert_equal(
        MAX_SERIES_PER_WORKER,
        4096,
        "MAX_SERIES_PER_WORKER is DEFAULT_RING_CAPACITY (every ceiling is"
        " derived from the transport)",
    )
    assert_equal(SERIES_BITSET_WORDS, 64, "4096 slots == 64 x 64-bit words")
    assert_equal(SERIES_MAX_PROBE, 64, "the hot-path probe cap")
    # 65536 entries + 16384 scopes + 4096 kinds + 512 bitset + 16 counters
    assert_equal(
        _SERIES_TABLE_SIZE_GUARD,
        86544,
        "_SERIES_TABLE_SIZE_GUARD is 86544 B = 84.5 KiB -- the number the"
        " header's 5.28 MiB per process is derived FROM. If this changed, fix"
        " the header's arithmetic; do not just update the number.",
    )
    assert_equal(
        _SERIES_TABLE_SIZE_GUARD,
        size_of[SeriesTable](),
        "the guard IS size_of[SeriesTable]()",
    )
    assert_equal(
        _SERIES_TABLE_SIZE_GUARD * MAX_WORKERS,
        5538816,
        "5538816 B = 5.28 MiB per process -- 97x smaller than a naive"
        " 512 MiB per-series replication, which is the conclusion that has to"
        " survive even when the number moves",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
