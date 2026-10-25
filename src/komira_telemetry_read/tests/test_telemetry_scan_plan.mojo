# =============================================================================
# komira_telemetry_read/tests/test_telemetry_scan_plan.mojo
#   The prune itself: a time range becomes a set of object keys, opening the
#   objects the range needs and no others.
# =============================================================================
#
# What each case would catch if it were wrong:
#   4   the plan opens every object in the bucket (day partition and the
#       entry-level `overlaps_time` prune, isolated from each other).
#   5   the read-amplification claim, MEASURED off the store's own LIST counter
#       rather than asserted: LISTs are O(partitions), never O(objects).
#   8   the merge-input skip: every merged row returned TWICE.
#   10  a series filter that defaults to on and empties every log plan.
#   13  the `series.active` guard, with non-zero series bounds (case 10's log
#       fixtures cannot tell guarded from unguarded).
#   14  the `object_key` tie-break: the plan's order depending on shard order.
#
# `SharedInMemoryConditionalStore` is the one in-tree fake whose `clone()`
# SHARES state AND whose per-verb op tallies are shared across every clone. The
# planner clones the store once per lineage, so a per-instance counter would
# report zero and the assertion would be a tautology.
#
# HERMETIC: no cloud, no dial, no clock (every timestamp is a literal).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_shard_keys import shard_manifest_prefix

from komira_telemetry_store.keys import (
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    telemetry_data_key,
    telemetry_partition_prefix,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TelemetrySegmentEntry,
    encode_telemetry_segment_entry,
    make_metric_segment_entry,
    make_raw_segment_entry,
)

from komira_telemetry_read.scan_plan import (
    TelemetrySeriesFilter,
    plan_telemetry_scan,
)

comptime _Store = SharedInMemoryConditionalStore

# 2026-09-15T00:00:00Z in nanoseconds. Every timestamp below is this plus an
# offset, so the cases are clock-independent and the day boundary is exact.
comptime _SEP15: Int64 = 1789430400_000_000_000
comptime _HOUR: Int64 = 3_600_000_000_000
comptime _DAY: Int64 = 86_400_000_000_000


# ---------------------------------------------------------------------------
# Fixture writer. It publishes catalog entries by hand: a catalog entry plus a
# placeholder object body, the smallest thing that exercises the planner. The
# decode is exercised against REAL Parquet bytes in
# test_telemetry_segment_read.mojo, where the writer in komira_telemetry_store
# produces the objects.
# ---------------------------------------------------------------------------


def _uuid16(seed: Int) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 37 + i * 11) % 256)
    return u^


def _lineage(day: String, writer_id: String) raises -> String:
    return shard_manifest_prefix(
        telemetry_partition_prefix(
            String(TELEMETRY_ROOT), String(TELEMETRY_DATASET_LOGS), day
        ),
        writer_id,
    )


def _data_key(day: String, seed: Int, min_ts: Int64) raises -> String:
    return telemetry_data_key(
        String(TELEMETRY_ROOT),
        String(TELEMETRY_DATASET_LOGS),
        day,
        min_ts // Int64(1_000_000),
        _uuid16(seed),
    )


def _append[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage, day: String, writer_id: String, var entry: TelemetrySegmentEntry
) raises:
    """Append one entry through a FRESH manifest handle, which keeps the durable
    `_HEAD` caught up with the tail."""
    var manifest = CasManifestStore[Storage](
        storage.clone(), _lineage(day, writer_id), RetryPolicy.fast_test()
    )
    _ = manifest.append(encode_telemetry_segment_entry(entry), Int64(1))


def _publish_segment[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    day: String,
    writer_id: String,
    seed: Int,
    min_ts: Int64,
    max_ts: Int64,
    var body: String,
) raises -> String:
    """Write one data object and append its catalog entry. Returns the key."""
    var key = _data_key(day, seed, min_ts)
    var bytes = List[UInt8]()
    var b = body.as_bytes()
    for i in range(len(b)):
        bytes.append(b[i])
    _ = storage.put(Path.parse(key), bytes^)
    var entry = make_raw_segment_entry(
        key.copy(),
        min_ts,
        max_ts,
        Int64(1),
        Int64(body.byte_length()),
        _uuid16(seed),
    )
    _append(storage, day, writer_id, entry^)
    return key^


def _has_key(keys: List[String], want: String) -> Bool:
    for i in range(len(keys)):
        if keys[i] == want:
            return True
    return False


def _publish_merged[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    day: String,
    writer_id: String,
    seed: Int,
    min_ts: Int64,
    max_ts: Int64,
    absorbed: List[Int],
) raises -> String:
    """A COMPACTED segment naming the seeds it absorbed."""
    var key = _data_key(day, seed, min_ts)
    _ = storage.put(Path.parse(key), List[UInt8]())
    var inputs = List[UInt8]()
    for i in range(len(absorbed)):
        var u = _uuid16(absorbed[i])
        for k in range(16):
            inputs.append(u[k])
    var entry = TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION,
        _uuid16(seed),
        key.copy(),
        min_ts,
        max_ts,
        Int64(0),
        Int64(0),
        Int64(len(absorbed)),
        Int64(0),
        Int64(1),  # merge_ops > 0 == compacted
        inputs^,
        False,
    )
    _append(storage, day, writer_id, entry^)
    return key^


def _publish_series_segment[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    day: String,
    writer_id: String,
    seed: Int,
    min_ts: Int64,
    max_ts: Int64,
    min_series: Int64,
    max_series: Int64,
) raises -> String:
    """A METRICS-shaped catalog entry: NON-ZERO series bounds.

    The one thing `_publish_segment` cannot produce, and the reason the series
    guard is untestable over log-shaped fixtures: a log entry carries 0/0, and
    `overlaps_series(0, 0)` is True for a 0/0 entry, so the guarded and the
    unguarded planner return the same plan over logs."""
    var key = _data_key(day, seed, min_ts)
    _ = storage.put(Path.parse(key), List[UInt8]())
    var entry = make_metric_segment_entry(
        _uuid16(seed),
        key.copy(),
        min_ts,
        max_ts,
        min_series,
        max_series,
        Int64(1),
        Int64(0),
    )
    _append(storage, day, writer_id, entry^)
    return key^


# =============================================================================
# CASE 4 - THE PLAN OPENS THE OBJECTS THE RANGE NEEDS AND NO OTHERS.
# =============================================================================
def test_04_the_plan_prunes_by_time_across_days() raises:
    var store = _Store()
    var w = String("writer-a")
    # Three days, one segment each, each one hour wide.
    var k13 = _publish_segment(
        store, String("20260913"), w, 1, _SEP15 - Int64(2) * _DAY,
        _SEP15 - Int64(2) * _DAY + _HOUR, String("day13"),
    )
    var k14 = _publish_segment(
        store, String("20260914"), w, 2, _SEP15 - _DAY,
        _SEP15 - _DAY + _HOUR, String("day14"),
    )
    var k15 = _publish_segment(
        store, String("20260915"), w, 3, _SEP15, _SEP15 + _HOUR, String("day15"),
    )

    # Ask for the middle day only.
    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15 - _DAY,
        _SEP15 - _DAY + _HOUR,
    )
    var keys = plan.object_keys()
    assert_equal(len(keys), 1, "4: exactly ONE segment survives a one-day range")
    assert_equal(keys[0], k14, "4: and it is the one whose day was asked for")
    assert_false(_has_key(keys, k13), "4: the earlier day is NOT in the plan")
    assert_false(_has_key(keys, k15), "4: the later day is NOT in the plan")

    # The accounting separates "nothing matched" from "nothing was read".
    assert_equal(
        len(plan.days),
        1,
        "4: the range computed to ONE day partition, so the other two days were"
        " never even enumerated",
    )
    assert_equal(
        plan.entries_replayed,
        1,
        "4: only the asked-for day's catalog was replayed at all: the day"
        " partition prunes BEFORE the manifest",
    )

    # A range covering all three days keeps all three, pruning nothing.
    var wide = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15 - Int64(2) * _DAY,
        _SEP15 + _HOUR,
    )
    assert_equal(len(wide.object_keys()), 3, "4: a 3-day range keeps all three")
    assert_equal(len(wide.days), 3, "4: and enumerated three partitions")
    assert_equal(
        wide.pruned_by_time, 0, "4: nothing was pruned by time on the wide read"
    )
    # Ascending by min_ts: a caller's "first N objects" must be reproducible.
    var wk = wide.object_keys()
    assert_equal(wk[0], k13, "4: ascending by min_ts_ns, oldest first")
    assert_equal(wk[2], k15, "4: ascending by min_ts_ns, newest last")

    # THE ENTRY-LEVEL TIME PRUNE, ISOLATED FROM THE DAY PARTITION. A range
    # starting two hours INTO the 14th and ending inside the 15th enumerates
    # BOTH days and replays BOTH catalogs, so the partition prunes nothing; but
    # k14 covers 00:00-01:00 on the 14th and ends before the range begins, so
    # the only thing that can drop it is `overlaps_time` on its own entry.
    var entry_pruned = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15 - _DAY + Int64(2) * _HOUR,
        _SEP15 + _HOUR,
    )
    assert_equal(
        len(entry_pruned.days),
        2,
        "4: the range spans TWO day partitions, so the day arithmetic prunes"
        " NEITHER of them",
    )
    assert_equal(
        entry_pruned.entries_replayed,
        2,
        "4: and BOTH days' catalogs really were replayed, so the entry that"
        " gets dropped was READ, not skipped upstream by the partition",
    )
    assert_equal(
        entry_pruned.pruned_by_time,
        1,
        "4: EXACTLY ONE entry was pruned by `overlaps_time` on its own min/max:"
        " k14 ends at 01:00 on the 14th and the range starts at 02:00",
    )
    var ek = entry_pruned.object_keys()
    assert_equal(len(ek), 1, "4: so ONE object survives the two-day range")
    assert_equal(ek[0], k15, "4: and it is the later day's")
    assert_false(
        _has_key(ek, k14),
        "4: the 14th's segment is ABSENT even though the 14th WAS enumerated"
        " and its catalog replayed: a plan that returned it would GET an object"
        " holding no matching row",
    )


# =============================================================================
# CASE 5 - READ AMPLIFICATION, MEASURED. LISTs are O(partitions), never
# O(objects), and a pruned object is never fetched.
# =============================================================================
def test_05_read_amplification_is_measured_not_asserted() raises:
    var store = _Store()
    var w = String("writer-a")
    # SIX segments in ONE day. If the plan listed per object, the LIST count
    # would grow with this number.
    for i in range(6):
        _ = _publish_segment(
            store, String("20260915"), w, 10 + i,
            _SEP15 + Int64(i) * _HOUR, _SEP15 + Int64(i) * _HOUR + _HOUR // 2,
            String("seg"),
        )

    store.reset_op_counts()
    var plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _SEP15, _SEP15 + _HOUR // 4
    )
    var lists = store.n_list()

    # Only the first hour's segment overlaps [0, 15min].
    assert_equal(
        len(plan.object_keys()),
        1,
        "5: one of six segments overlaps the 15-minute window",
    )
    assert_equal(
        plan.pruned_by_time,
        5,
        "5: FIVE segments were pruned on their catalog entry, and a pruned"
        " segment is never GET",
    )
    assert_equal(plan.entries_replayed, 6, "5: all six catalogs WERE replayed")

    # One day partition and one writer shard: one shard-enumeration LIST plus
    # the substrate's two tombstone LISTs for that shard (`tombstones/` and
    # `moved_tombstones/`).
    assert_equal(
        lists,
        Int64(3),
        "5: the plan issued exactly (1 day-enumeration + 2 tombstone) LISTs;"
        " the tombstone set is discovered by two LISTs per shard",
    )

    # The same three LISTs when SIX segments survive.
    store.reset_op_counts()
    var wide = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + Int64(6) * _HOUR,
    )
    assert_equal(len(wide.object_keys()), 6, "5: the wide plan keeps all six")
    assert_equal(
        store.n_list(),
        Int64(3),
        "5: SIX surviving segments cost the SAME three LISTs as one: the listing"
        " count is a function of PARTITIONS, not of objects",
    )


# =============================================================================
# CASE 8 - THE MERGE-INPUT SKIP. A compacted segment HIDES the inputs it
# absorbed. Without it every merged row is returned TWICE between a merge's
# publish and its inputs' tombstone.
# =============================================================================
def test_08_a_compacted_segment_hides_the_inputs_it_absorbed() raises:
    var store = _Store()
    var day = String("20260915")
    var w = String("writer-a")
    var a = _publish_segment(
        store, day, w, 31, _SEP15, _SEP15 + _HOUR, String("a")
    )
    var b = _publish_segment(
        store, day, w, 32, _SEP15 + _HOUR, _SEP15 + Int64(2) * _HOUR, String("b")
    )
    # Both inputs are still LIVE: the merge has published but not yet
    # tombstoned them.
    var absorbed = List[Int]()
    absorbed.append(31)
    absorbed.append(32)
    var m = _publish_merged(
        store, day, w, 33, _SEP15, _SEP15 + Int64(2) * _HOUR, absorbed
    )

    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + Int64(2) * _HOUR,
    )
    var keys = plan.object_keys()
    assert_equal(
        len(keys),
        1,
        "8: the merged segment is returned and its two live inputs are NOT",
    )
    assert_equal(keys[0], m, "8: and the survivor is the merged segment")
    assert_false(_has_key(keys, a), "8: absorbed input A is skipped")
    assert_false(_has_key(keys, b), "8: absorbed input B is skipped")
    assert_equal(plan.skipped_absorbed, 2, "8: and both skips are ACCOUNTED")
    assert_equal(
        plan.entries_replayed,
        3,
        "8: all three catalog entries were replayed: the skip is a READ-time"
        " decision, not a missing entry",
    )


# =============================================================================
# CASE 10 - THE SERIES FILTER MUST NOT BE APPLIED TO LOGS BY DEFAULT.
#
# A log catalog entry carries min_series_id == max_series_id == 0. An unguarded
# range filter would prune EVERY log segment and return an empty plan over a
# bucket full of data.
# =============================================================================
def test_10_the_series_filter_is_inert_for_logs_by_default() raises:
    var store = _Store()
    var day = String("20260915")
    var k = _publish_segment(
        store, day, String("w"), 41, _SEP15, _SEP15 + _HOUR, String("x")
    )

    var default_plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _SEP15, _SEP15 + _HOUR
    )
    assert_equal(
        len(default_plan.object_keys()),
        1,
        "10: the DEFAULT filter is inert: a log segment survives",
    )
    assert_equal(k, default_plan.object_keys()[0], "10: the right one")

    # An ACTIVE filter over a non-zero range prunes it, which would be
    # catastrophic as the default.
    var filtered = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + _HOUR,
        TelemetrySeriesFilter.range(Int64(100), Int64(200)),
    )
    assert_equal(
        len(filtered.object_keys()),
        0,
        "10: an ACTIVE series filter DOES prune a log segment (whose series"
        " bounds are 0/0), which is why it must never default to on",
    )
    assert_equal(filtered.pruned_by_series, 1, "10: and the skip is accounted")


# =============================================================================
# CASE 13 - THE `series.active` GUARD, MADE FALSIFIABLE. A segment with NON-ZERO
# series bounds SURVIVES the default (inert) filter.
#
# Case 10 cannot see the guard: its fixtures are log-shaped, so guarded and
# unguarded agree on every log segment. This case publishes series bounds
# [1000, 2000] under the DEFAULT `TelemetrySeriesFilter.none()`, whose (lo, hi)
# is (0, 0). Unguarded, `overlaps_series(0, 0)` is FALSE and the segment would
# be pruned.
# =============================================================================
def test_13_the_inert_default_filter_keeps_a_non_zero_series_segment() raises:
    var store = _Store()
    var day = String("20260915")
    var w = String("writer-metrics")
    var k = _publish_series_segment(
        store, day, w, 51, _SEP15, _SEP15 + _HOUR, Int64(1000), Int64(2000)
    )

    var plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _SEP15, _SEP15 + _HOUR
    )
    assert_equal(
        len(plan.object_keys()),
        1,
        "13: a segment whose series bounds are [1000, 2000] SURVIVES the"
        " DEFAULT filter",
    )
    assert_equal(plan.object_keys()[0], k, "13: and it is the one we wrote")
    assert_equal(
        plan.pruned_by_series,
        0,
        "13: and NOTHING was pruned by series: the counter is the direct"
        " reading of whether the guard held",
    )

    # The positive control, so the assertions above cannot be satisfied by a
    # series prune that does not work: an ACTIVE filter both KEEPS and PRUNES
    # this same segment, on the same code path.
    var inside = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + _HOUR,
        TelemetrySeriesFilter.range(Int64(1500), Int64(1600)),
    )
    assert_equal(
        len(inside.object_keys()),
        1,
        "13: an ACTIVE filter INSIDE the segment's series range keeps it",
    )
    var outside = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + _HOUR,
        TelemetrySeriesFilter.range(Int64(5000), Int64(6000)),
    )
    assert_equal(
        len(outside.object_keys()),
        0,
        "13: and an ACTIVE filter DISJOINT from it prunes it, so the series"
        " prune is live and the survival above is the GUARD",
    )
    assert_equal(outside.pruned_by_series, 1, "13: and that skip is accounted")


# =============================================================================
# CASE 14 - THE `object_key` TIE-BREAK. Two segments sharing a `min_ts_ns` come
# back in a REPRODUCIBLE order.
#
# The publish order is descending on purpose: the insertion sort's primary
# comparison is a strict `>` on `min_ts_ns`, so equal elements never swap on it.
# Without the tie-break the plan's order is replay order. Publishing the LARGER
# key first makes "unchanged" and "tie-broken" two DIFFERENT observable orders.
# =============================================================================
def test_14_two_segments_sharing_a_min_ts_order_by_object_key() raises:
    var store = _Store()
    var day = String("20260915")
    var w = String("writer-tie")
    # SAME `min_ts_ns` (so `start_ms`, and therefore the key prefix, is
    # identical); the segment uuid is the only thing that differs.
    var kb = _publish_segment(
        store, day, w, 62, _SEP15, _SEP15 + _HOUR, String("b")
    )
    var ka = _publish_segment(
        store, day, w, 61, _SEP15, _SEP15 + _HOUR // 2, String("a")
    )
    assert_true(
        ka < kb,
        "14: PRECONDITION: the two keys are ordered lexicographically ("
        + ka
        + " < "
        + kb
        + "), and the LARGER one was published FIRST, so replay order and"
        " tie-broken order are different lists",
    )

    var plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _SEP15, _SEP15 + _HOUR
    )
    var keys = plan.object_keys()
    assert_equal(
        len(keys),
        2,
        "14: PRECONDITION: both segments survive the range, so the ordering"
        " below is over a real tie",
    )
    assert_equal(
        keys[0],
        ka,
        "14: with `min_ts_ns` TIED, the SMALLER `object_key` comes first",
    )
    assert_equal(
        keys[1], kb, "14: and the larger key is second: a total order"
    )


def main() raises:
    test_04_the_plan_prunes_by_time_across_days()
    test_05_read_amplification_is_measured_not_asserted()
    test_08_a_compacted_segment_hides_the_inputs_it_absorbed()
    test_10_the_series_filter_is_inert_for_logs_by_default()
    test_13_the_inert_default_filter_keeps_a_non_zero_series_segment()
    test_14_two_segments_sharing_a_min_ts_order_by_object_key()
    print("test_telemetry_scan_plan: OK")
