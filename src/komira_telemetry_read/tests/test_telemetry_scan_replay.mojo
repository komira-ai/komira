# =============================================================================
# komira_telemetry_read/tests/test_telemetry_scan_replay.mojo
#   The manifest replay inside the plan: it must not miss the newest segments a
#   lagging `_HEAD` hides, must step over tombstones and reaped gaps, and must
#   not read a permission failure as "absent".
# =============================================================================
#
# What each case would catch if it were wrong:
#   6   the newest segments invisible to a fresh reader: the durable `_HEAD` is
#       a lower bound, and a replay that stops at it loses data silently.
#   11  a tombstone ABOVE the head ending the walk (drops the newest data).
#   12  a reaped hole BELOW the head ending the walk (reads as an empty bucket).
#   15  a `404` inside an object key classifying a denied error as not-found.
#
# HERMETIC: `SharedInMemoryConditionalStore`, no cloud, no clock.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    is_not_found as _is_not_found,
)
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
    make_raw_segment_entry,
)

from komira_telemetry_read.scan_plan import plan_telemetry_scan

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


def _publish_long_lived(
    store: _Store,
    mut writer: CasManifestStore[_Store],
    day: String,
    count: Int,
    seed_base: Int,
    mut keys: List[String],
) raises:
    """Append `count` segments through ONE long-lived manifest handle. After its
    first append the handle's local cache is warm, and the substrate defers the
    durable `_HEAD` advance, so the durable head LAGS the true tail."""
    for i in range(count):
        var min_ts = _SEP15 + Int64(i) * _HOUR
        var key = _data_key(day, seed_base + i, min_ts)
        _ = store.put(Path.parse(key), List[UInt8]())
        var entry = make_raw_segment_entry(
            key.copy(),
            min_ts,
            min_ts + _HOUR // 2,
            Int64(1),
            Int64(0),
            _uuid16(seed_base + i),
        )
        _ = writer.append(encode_telemetry_segment_entry(entry), Int64(1))
        keys.append(key^)


# =============================================================================
# CASE 6 - THE STALE-`_HEAD` GAP. The newest segments must be visible to a FRESH
# reader handle.
#
# A durable `_HEAD` is a lower bound on the tail. A replay that reads `_HEAD` and
# stops sees the first segment of a lagging lineage and silently misses the
# rest. `_replay_lineage_entries` forward-probes PAST the durable head instead.
# =============================================================================
def test_06_a_lagging_durable_head_does_not_hide_the_newest_segments() raises:
    var store = _Store()
    var day = String("20260915")
    var lineage = _lineage(day, String("writer-warm"))
    var writer = CasManifestStore[_Store](
        store.clone(), lineage.copy(), RetryPolicy.fast_test()
    )
    var n = 5
    var keys = List[String]()
    _publish_long_lived(store, writer, day, n, 100, keys)

    # THE MEASUREMENT that makes this case non-vacuous: a FRESH handle's durable
    # `_HEAD` really is behind. If this stops being true the case would still
    # pass below but would no longer be testing anything.
    var fresh = CasManifestStore[_Store](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    var durable = fresh.read_durable_head().chunk_seq
    assert_true(
        durable < Int64(n - 1),
        "6: PRECONDITION: the durable `_HEAD` LAGS the true tail (saw"
        " chunk_seq="
        + String(durable)
        + " for "
        + String(n)
        + " committed chunks)",
    )

    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + Int64(24) * _HOUR,
    )
    assert_equal(
        len(plan.object_keys()),
        n,
        "6: a FRESH reader handle sees all "
        + String(n)
        + " committed segments, not just the "
        + String(Int(durable) + 1)
        + " the durable `_HEAD` admits to",
    )
    assert_equal(plan.entries_replayed, n, "6: and it replayed all of them")


# =============================================================================
# CASE 11 - A TOMBSTONE ABOVE THE DURABLE `_HEAD` IS NOT THE END OF THE
# MANIFEST. The forward probe must step over it and keep walking.
#
# A tombstone marker only exists for a slot that was COMMITTED, so it is
# positive evidence the true tail is at least there. Terminating on one drops
# every segment published after the last compaction, which is exactly the newest
# data, and reports it as an empty result rather than an error.
#
# THE SHAPE: one long-lived writer handle (so the durable `_HEAD` lags), a
# tombstone placed strictly ABOVE that lagging head, and LIVE chunks above the
# tombstone. Both regions of the one loop are then in play.
# =============================================================================
def test_11_a_tombstone_above_the_durable_head_does_not_end_the_walk() raises:
    var store = _Store()
    var day = String("20260915")
    var lineage = _lineage(day, String("writer-tomb"))
    var writer = CasManifestStore[_Store](
        store.clone(), lineage.copy(), RetryPolicy.fast_test()
    )
    var n = 5
    var keys = List[String]()
    _publish_long_lived(store, writer, day, n, 200, keys)

    var fresh = CasManifestStore[_Store](
        store.clone(), lineage.copy(), RetryPolicy.fast_test()
    )
    var durable = fresh.read_durable_head().chunk_seq
    var tomb_seq = durable + Int64(1)

    # ---- the preconditions, without which this case proves nothing ----
    var before = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + Int64(24) * _HOUR,
    )
    assert_equal(
        len(before.object_keys()),
        n,
        "11: PRECONDITION: all "
        + String(n)
        + " segments are visible BEFORE anything is tombstoned",
    )
    assert_true(
        tomb_seq > durable,
        "11: PRECONDITION: the chunk about to be tombstoned sits ABOVE the"
        " durable `_HEAD` (durable="
        + String(durable)
        + "), the only region where a `break` in the tombstone arm is reachable",
    )
    assert_true(
        tomb_seq < Int64(n - 1),
        "11: PRECONDITION: at least one LIVE chunk sits ABOVE the tombstone"
        " (tomb="
        + String(tomb_seq)
        + ", n="
        + String(n)
        + "), so a walk that stopped at the tombstone comes back visibly short",
    )

    # An EXPLICIT schedule timestamp: `schedule_for_delete` would read the wall
    # clock, and nothing in this file may.
    writer.schedule_for_delete_at(tomb_seq, Int64(0))

    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + Int64(24) * _HOUR,
    )
    var got = plan.object_keys()
    assert_equal(
        len(got),
        n - 1,
        "11: the tombstoned chunk's BODY is skipped and the walk CONTINUES:"
        " every chunk above it is still returned. A `break` in this arm returns"
        " only the "
        + String(Int(tomb_seq))
        + " chunk(s) BELOW the tombstone and loses the newest segments"
        " silently",
    )
    assert_false(
        _has_key(got, keys[Int(tomb_seq)]),
        "11: the tombstoned segment itself is NOT in the plan",
    )
    for i in range(Int(tomb_seq) + 1, n):
        assert_true(
            _has_key(got, keys[i]),
            "11: chunk "
            + String(i)
            + " sits ABOVE the tombstone AND above the durable `_HEAD`, and is"
            " still in the plan",
        )
    assert_equal(
        plan.entries_replayed,
        n - 1,
        "11: and the accounting agrees: "
        + String(n - 1)
        + " entries replayed, the tombstoned one contributing none",
    )


# =============================================================================
# CASE 12 - A REAPED GAP BELOW THE DURABLE `_HEAD` IS WALKED OVER.
#
# The other half of the same rule. Below the head a missing chunk is a REAPED
# gap (step over it); above the head it is THE TRUE TAIL (stop). Merging the
# below-head arm into the tail's `break` returns ZERO segments for a lineage
# whose oldest chunk has been reaped, which is every lineage past its first
# retention sweep.
#
# `reap` deletes the tombstone marker with the chunk, which is what makes this a
# bare HOLE rather than a tombstone: after the reap `tombstone_seqs()` no longer
# names the seq, so the walk reaches the not-found arm and not the tombstone arm.
# =============================================================================
def test_12_a_reaped_gap_below_the_durable_head_is_walked_over() raises:
    var store = _Store()
    var day = String("20260915")
    var w = String("writer-reap")
    var keys = List[String]()
    for i in range(3):
        # A FRESH handle per append (`_publish_segment`), the opposite of case
        # 11's long-lived writer: it keeps the durable `_HEAD` caught up, which
        # puts the reaped chunk BELOW it.
        keys.append(
            _publish_segment(
                store, day, w, 300 + i,
                _SEP15 + Int64(i) * _HOUR,
                _SEP15 + Int64(i) * _HOUR + _HOUR // 2,
                String("seg"),
            )
        )

    var mgr = CasManifestStore[_Store](
        store.clone(), _lineage(day, w), RetryPolicy.fast_test()
    )
    var durable = mgr.read_durable_head().chunk_seq
    assert_true(
        durable >= Int64(1),
        "12: PRECONDITION: the durable `_HEAD` is at or above the chunk being"
        " reaped (saw chunk_seq="
        + String(durable)
        + "); below the head is the only region where the reaped-gap arm is"
        " reachable",
    )

    # Tombstone, then reap. The reaper drops the marker with the chunk, so what
    # is left at seq 0 is a NOT-FOUND chunk with NO tombstone.
    mgr.schedule_for_delete_at(Int64(0), Int64(0))
    mgr.reap(Int64(0))

    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _SEP15,
        _SEP15 + Int64(24) * _HOUR,
    )
    var got = plan.object_keys()
    assert_equal(
        len(got),
        2,
        "12: the walk STEPS OVER the reaped hole at seq 0 and returns the two"
        " chunks above it",
    )
    assert_false(
        _has_key(got, keys[0]),
        "12: the reaped chunk's entry is gone: its body no longer exists",
    )
    assert_true(
        _has_key(got, keys[1]),
        "12: chunk 1, which sits ABOVE the hole, is still returned",
    )
    assert_true(_has_key(got, keys[2]), "12: and so is chunk 2")
    assert_equal(
        plan.entries_replayed,
        2,
        "12: and the accounting says TWO entries were replayed, not three: the"
        " gap contributed nothing and raised nothing",
    )


# =============================================================================
# CASE 15 - A DENIED ERROR ON A `404`-BEARING KEY IS NOT READ AS ABSENT.
#
# `_is_not_found` once matched a bare `404`, and the message it searches
# CONTAINS THE OBJECT KEY: the cloud error mapper renders
# `StoreError[<KIND>] <method> <scheme>://<bucket>/<key> status=<http>`. A
# telemetry key's alphabet is `[0-9a-f/.-]`, so `404` can occur inside one; `=`
# cannot. With the bare needle a permission failure on such a key read as
# not-found, which makes a broken credential indistinguishable from an empty
# dataset and stops a manifest replay early with no error.
#
# The control in the other direction is the second half: a REAL not-found must
# still be recognised, or the matcher would be a gate that simply says no.
# =============================================================================
def test_15_a_denied_error_on_a_404_bearing_key_is_not_read_as_absent() raises:
    var key = String(
        "telemetry/logs/20260916/data/00000000000000000000-404abc0123456789"
        "404abc0123456789.parquet"
    )
    var denied = (
        String("StoreError[DENIED] ReadObject gs://example-bucket/")
        + key
        + String(" status=403 grpc_code=7")
    )
    assert_false(
        _is_not_found(denied),
        "a DENIED error whose KEY contains '404' must not read as not-found:"
        " that is a broken credential reported as an absent object",
    )

    var absent = (
        String("StoreError[NOT_FOUND] ReadObject gs://example-bucket/")
        + key
        + String(" status=404 grpc_code=5")
    )
    assert_true(
        _is_not_found(absent),
        "a genuine not-found must still be recognised",
    )


def main() raises:
    test_06_a_lagging_durable_head_does_not_hide_the_newest_segments()
    test_11_a_tombstone_above_the_durable_head_does_not_end_the_walk()
    test_12_a_reaped_gap_below_the_durable_head_is_walked_over()
    test_15_a_denied_error_on_a_404_bearing_key_is_not_read_as_absent()
    print("test_telemetry_scan_replay: OK")
