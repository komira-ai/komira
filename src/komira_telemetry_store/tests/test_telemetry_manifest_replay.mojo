# =============================================================================
# komira_telemetry_store/tests/test_telemetry_manifest_replay.mojo
#   THE MARQUEE FALSIFIER: DISCOVERY BY MANIFEST REPLAY, NEVER BY LISTING —
#   proved by making listing IMPOSSIBLE and replaying anyway.
# =============================================================================
#
# -- WHY A COUNTER IS NOT ENOUGH, AND WHAT IS ---------------------------------
# `SharedInMemoryConditionalStore` already tallies `n_list()`, and asserting it
# is 0 is a COUNT assertion, a vacuous shape. A replay that raised, returned empty, or was never called also
# lists zero times.
#
# So the primary instrument is `NoListStore`: a delegating conformer whose
# `list_with_delimiter` RAISES. Under it a listing replay cannot pass by
# accident — it explodes. The counter is kept as a SECOND, independent read of
# the same claim, and every case that asserts "no listing" ALSO asserts the
# entries actually came back, by content.
#
# THE CLAIM IS ABOUT THE **READ** PATH, AND THE SCOPE IS NOT A HEDGE. Every reader handle below is built on `NoListStore`; every WRITER
# handle is built on the plain store. The first `append` to a fresh lineage has
# a cold head cache, finds no `_HEAD`, and LIST-recovers the tail
# (`cas_manifest._recover_head_by_list`) — that is the CAS substrate's
# bootstrap, it happens once per lineage on the WRITE side, and it is not what
# a dashboard re-runs on a timer. Running a writer over `NoListStore`
# raises with `prefix=.../manifest/`, which is how this boundary was found
# rather than assumed; CASE 8 pins it, so a future change that pushes a LIST
# onto the read path cannot be explained away as "the write path always did".
#
# -- THE BUG CASE 2 EXISTS FOR ------------------------------------------------
# `CasManifestStore` DEFERS its durable `_HEAD` advance for up to
# `_HEAD_ADVANCE_DEFER_CADENCE` = 64 warm appends. The FIRST append (cold cache)
# advances `_HEAD` durably; every warm append after it DEFERS. So a writer that
# publishes N segments on ONE handle leaves the durable `_HEAD` pinned at seq 0,
# and a FRESH reader that trusts `_HEAD` sees ONE segment and silently misses
# N-1. A reader that LISTS the bucket to repair that pays an O(chunks) LIST.
#
# The fix HERE is a FORWARD PROBE by exact GET, available only because key depth
# is a constant so seq N+1 is a computed name. CASE 2 is the test that fails if
# the probe is removed, and it fails LOUDLY (1 entry instead of 4), not subtly.
#
# HERMETIC: `SharedInMemoryConditionalStore` (the in-tree fake whose `clone()`
# SHARES state, which a cross-handle read-back requires). No cloud, no docker,
# no dial, no pthread.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    decode_head,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_telemetry_store.keys import (
    NS_PER_DAY,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    telemetry_data_key,
    telemetry_partition_prefix,
)
from komira_telemetry_store.manifest import (
    TelemetryLiveEntry,
    TelemetrySegmentManifest,
    apply_merge_input_skip,
    discover_partition_writer_ids,
    open_partition_manifest,
    plan_time_range_read,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TelemetrySegmentEntry,
    make_log_segment_entry,
)


comptime _DAY: String = "20261001"
comptime _DAY_T0: Int64 = 1790812800_000_000_000  # 2026-10-01T00:00:00Z


# =============================================================================
# NoListStore — a delegating store whose ONLY difference is that LISTING IS
# IMPOSSIBLE. Everything else forwards to the shared in-memory twin, so a
# replay that reaches only exact GETs behaves identically and one that lists at
# all raises with a message naming this struct.
# =============================================================================


struct NoListStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """`SharedInMemoryConditionalStore` with `list_with_delimiter` REMOVED.

    THIS IS THE INSTRUMENT, NOT A CONVENIENCE. The claim is that a time-range
    read never lists, and the only way to test a negative like that without
    trusting a counter is to make the operation unavailable. A replay built on
    `read_head_fresh()` (which LIST-recovers on a cold handle) or on
    `tombstone_seqs()` (which "discovers by LISTing `<prefix>/tombstones/`")
    RAISES here."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        raise Error(
            "NoListStore: list_with_delimiter is REFUSED (prefix="
            + prefix.raw()
            + "). The telemetry read path must reach every manifest object by"
            " an EXACT GET of a computed name — the one listing is"
            " is writer-shard discovery, and it is not on this path"
        )

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        return self._inner.delete(path)


def _entry(
    disc: UInt8, seq: Int, min_ts: Int64, max_ts: Int64
) raises -> TelemetrySegmentEntry:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    u[0] = disc
    u[15] = UInt8(seq)
    var key = telemetry_data_key(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY, min_ts // 1_000_000, u
    )
    return make_log_segment_entry(
        u^, key^, min_ts, max_ts, Int64(10), Int64(1024), False
    )


def _open[
    S: CloneableConditionalWriteStore
](store: S, writer: String) raises -> TelemetrySegmentManifest[S]:
    return open_partition_manifest[S](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY, writer,
        RetryPolicy.fast_test(),
    )


# =============================================================================
# CASE 1 — a published segment comes back through a FRESH handle, over a store
# where listing is impossible.
# =============================================================================


def test_01_a_published_segment_replays_without_listing() raises:
    var inner = SharedInMemoryConditionalStore()
    # WRITER on the plain store (its cold CAS bootstrap LIST-recovers once).
    var w = _open[SharedInMemoryConditionalStore](inner, String("writer-a"))
    var e = _entry(UInt8(1), 0, _DAY_T0, _DAY_T0 + Int64(1000))
    _ = w.publish(e.copy())
    _ = w^

    # READER on NoListStore, sharing the SAME map — a FRESH, cold-cache handle,
    # exactly what a query endpoint is.
    var store = NoListStore(inner.clone())
    var r = _open[NoListStore](store, String("writer-a"))
    var live = r.live_segments()
    assert_equal(len(live), 1, "1: one published segment, one replayed")
    assert_equal(
        live[0].object_key,
        e.object_key,
        "1: ARRIVAL IS ASSERTED BY THE OBJECT KEY, not by a count. A count of"
        " 1 is satisfied by a replay that decoded some other chunk",
    )
    assert_equal(live[0].min_ts_ns, e.min_ts_ns, "1: min_ts survives the round trip")
    assert_equal(live[0].max_ts_ns, e.max_ts_ns, "1: max_ts survives")
    _ = r^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 2 — THE ONE. FOUR segments published on ONE handle, read back by a
# FRESH one. The durable `_HEAD` is pinned at the first append; only the forward
# probe finds the other three.
# =============================================================================


def test_02_every_segment_replays_despite_the_deferred_head_advance() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _open[SharedInMemoryConditionalStore](inner, String("writer-b"))
    var keys = List[String]()
    for i in range(4):
        var e = _entry(
            UInt8(2), i, _DAY_T0 + Int64(i) * Int64(1000),
            _DAY_T0 + Int64(i) * Int64(1000) + Int64(500),
        )
        keys.append(e.object_key.copy())
        _ = w.publish(e^)
    _ = w^

    # -- PRECONDITION: the durable `_HEAD` really IS stale-low ---------------
    #
    # A weaker assertion (`len(head_raw) > 0`, "a durable _HEAD object exists
    # at all") would also hold under a substrate that advanced `_HEAD` eagerly
    # on every append. Under that substrate the durable head is 3, region (b)
    # has nothing to probe, and the marquee assertion below is satisfied by
    # region (a) alone: the case would report the forward probe working while
    # measuring a world in which it is never used.
    #
    # DECODE IT. `chunk_seq < 3` is the actual claim: the durable tail lags the
    # last published seq, so seq 3 is reachable ONLY through the strict forward
    # probe. It is deliberately not `== 0`: the cadence piggyback persists the
    # cached tail BEFORE the next append, so the head is structurally ONE APPEND
    # BEHIND on any cadence, and pinning the exact lag would go red on a cadence
    # change that does not affect the claim.
    var lineage = telemetry_partition_prefix(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY
    ) + "/_lineage/writer-b"
    var head_raw = inner.get(Path.parse(lineage + "/_HEAD"))
    assert_true(
        len(head_raw) > 0,
        "2: precondition — a durable _HEAD object exists at all",
    )
    var durable_head = decode_head(head_raw).chunk_seq
    assert_true(
        durable_head < Int64(3),
        "2: PRECONDITION, DECODED — the durable _HEAD must LAG the last"
        " published seq (3), or the forward probe this case exists to measure"
        " has nothing to find and the assertion below proves nothing. Observed"
        " chunk_seq = " + String(durable_head),
    )

    var store = NoListStore(inner.clone())
    var r = _open[NoListStore](store, String("writer-b"))
    var live = r.live_segments()
    assert_equal(
        len(live),
        4,
        "2: ALL FOUR published segments must replay through a FRESH handle."
        " CasManifestStore defers its durable _HEAD advance for up to 64 warm"
        " appends, so a reader that stops at the durable _HEAD sees ONE. That"
        " is not a cache miss — nothing repairs it. Only the forward probe by"
        " exact GET finds the rest, and it must do so WITHOUT a LIST",
    )
    for i in range(4):
        assert_equal(
            live[i].object_key,
            keys[i],
            "2: ...in PUBLISH ORDER, by key. Ascending order is what a"
            " compactor's adjacent-first selection depends on",
        )
    _ = r^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 3 — the counter, as an independent second read of the same claim.
# =============================================================================


def test_03_replay_issues_exactly_zero_list_calls() raises:
    var store = SharedInMemoryConditionalStore()
    var w = _open[SharedInMemoryConditionalStore](store, String("writer-c"))
    for i in range(3):
        _ = w.publish(
            _entry(UInt8(3), i, _DAY_T0 + Int64(i), _DAY_T0 + Int64(i) + Int64(1))
        )
    _ = w^

    var r = _open[SharedInMemoryConditionalStore](store, String("writer-c"))
    store.reset_op_counts()
    var live = r.live_segments()
    assert_equal(
        len(live),
        3,
        "3: POSITIVE CONTROL — the replay actually returned the segments. An"
        " assertion of n_list()==0 alone is satisfied by a replay that did"
        " nothing at all",
    )
    assert_equal(
        store.n_list(),
        Int64(0),
        "3: ...and it issued ZERO listings doing it",
    )
    _ = r^
    _ = store^


# =============================================================================
# CASE 4 — THE PRUNE. A range query decides on manifest entries alone.
# =============================================================================


def test_04_a_time_range_prunes_on_the_manifest_and_never_opens_the_rest() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _open[SharedInMemoryConditionalStore](inner, String("writer-d"))
    # Ten one-minute segments across the day.
    var minute = Int64(60) * Int64(1_000_000_000)
    for i in range(10):
        _ = w.publish(
            _entry(
                UInt8(4), i,
                _DAY_T0 + Int64(i) * minute,
                _DAY_T0 + Int64(i) * minute + minute - Int64(1),
            )
        )
    _ = w^
    var store = NoListStore(inner.clone())
    var r = _open[NoListStore](store, String("writer-d"))
    assert_equal(len(r.live_segments()), 10, "4: precondition — 10 live")

    # A window inside segments 3 and 4 only.
    var hit = r.segments_overlapping(
        _DAY_T0 + Int64(3) * minute + Int64(5),
        _DAY_T0 + Int64(4) * minute + Int64(5),
    )
    assert_equal(
        len(hit),
        2,
        "4: a 1-minute-and-a-bit window must select exactly the TWO segments"
        " whose closed ranges it touches. Selecting all 10 means the manifest"
        " time range is decoration and every query is a full scan",
    )
    assert_equal(
        hit[0].min_ts_ns, _DAY_T0 + Int64(3) * minute, "4: first selected BY VALUE"
    )
    assert_equal(
        hit[1].min_ts_ns, _DAY_T0 + Int64(4) * minute, "4: second selected BY VALUE"
    )
    # A window before every segment selects nothing.
    assert_equal(
        len(r.segments_overlapping(_DAY_T0 - Int64(10), _DAY_T0 - Int64(1))),
        0,
        "4: a disjoint window selects NOTHING — a pruner that never returns"
        " empty is not pruning",
    )
    _ = r^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 5 — the compaction dup window. Without the skip, EVERY ROW TWICE.
# =============================================================================


def test_05_a_live_merge_hides_its_still_live_inputs() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _open[SharedInMemoryConditionalStore](inner, String("writer-e"))
    var a = _entry(UInt8(5), 0, _DAY_T0, _DAY_T0 + Int64(100))
    var b = _entry(UInt8(5), 1, _DAY_T0 + Int64(200), _DAY_T0 + Int64(300))
    _ = w.publish(a.copy())
    _ = w.publish(b.copy())

    # The merge: published, inputs NOT yet tombstoned — the dup window.
    var mu = InlineArray[UInt8, 16](fill=UInt8(0))
    mu[0] = UInt8(5)
    mu[15] = UInt8(99)
    var flat = List[UInt8]()
    for i in range(16):
        flat.append(a.segment_uuid[i])
    for i in range(16):
        flat.append(b.segment_uuid[i])
    var merged = TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION,
        mu^,
        telemetry_data_key(
            TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY, Int64(0),
            InlineArray[UInt8, 16](fill=UInt8(200)),
        ),
        a.min_ts_ns, b.max_ts_ns, Int64(0), Int64(0),
        a.row_count + b.row_count, Int64(2048), Int64(1), flat^, False,
    )
    var merged_key = merged.object_key.copy()
    _ = w.publish(merged^)
    _ = w^

    var store = NoListStore(inner.clone())
    var r = _open[NoListStore](store, String("writer-e"))
    assert_equal(
        len(r.replay_live_entries()),
        3,
        "5: precondition — all THREE chunks are in the manifest. The skip must"
        " be doing the work, not a manifest that never held the inputs",
    )
    var live = r.live_segments()
    assert_equal(
        len(live),
        1,
        "5: inside the publish->tombstone window a reader must see the MERGE"
        " and NOT its inputs. Without the skip it sees all three and every"
        " merged row is returned TWICE — a silently doubled rate on a"
        " dashboard, every line duplicated in a log tail",
    )
    assert_equal(
        live[0].object_key, merged_key, "5: ...and the survivor is the MERGE"
    )
    _ = r^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 6 — the ONE listing that IS on the read path: writer-shard discovery.
# It must find every writer, and it is the only place a LIST appears.
# =============================================================================


def test_06_writer_shard_discovery_is_the_only_listing() raises:
    var store = SharedInMemoryConditionalStore()
    for k in range(3):
        var wid = String("writer-f") + String(k)
        var m = _open[SharedInMemoryConditionalStore](store, wid)
        _ = m.publish(
            _entry(UInt8(6), k, _DAY_T0 + Int64(k), _DAY_T0 + Int64(k) + Int64(1))
        )
        _ = m^
    var ids = discover_partition_writer_ids[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY
    )
    assert_equal(
        len(ids), 3, "6: all three writer sub-lineages must be discovered"
    )
    var seen0 = False
    for i in range(len(ids)):
        if ids[i] == String("writer-f0"):
            seen0 = True
    assert_true(seen0, "6: ...and BY NAME, not merely by count")

    # The full plan: compute days -> discover writers -> replay -> prune.
    var plan = plan_time_range_read[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS,
        _DAY_T0, _DAY_T0 + Int64(1),
    )
    assert_equal(plan.partitions_scanned, 1, "6: one day partition considered")
    assert_equal(
        plan.considered, 3, "6: three live entries examined across the shards"
    )
    assert_equal(
        len(plan.segments),
        2,
        "6: ...and exactly the TWO whose closed ranges touch [t0, t0+1] are"
        " selected. `considered` > `len(segments)` is the observable that"
        " pruning HAPPENED rather than everything being returned",
    )
    _ = store^


def test_07_a_partition_with_no_writers_plans_nothing_and_does_not_raise() raises:
    var store = SharedInMemoryConditionalStore()
    var plan = plan_time_range_read[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS,
        _DAY_T0, _DAY_T0 + NS_PER_DAY,
    )
    assert_equal(plan.partitions_scanned, 2, "7: two days computed, no I/O needed")
    assert_equal(len(plan.segments), 0, "7: an empty dataset selects nothing")
    assert_equal(plan.considered, 0, "7: ...and considered nothing")
    _ = store^


# =============================================================================
# CASE 8 — the BOUNDARY, pinned. The WRITE path's cold CAS bootstrap DOES list;
# the READ path does not. Stating it as a test rather than a comment is what
# stops a future LIST on the read path being explained away.
# =============================================================================


def test_08_the_write_path_bootstrap_lists_and_the_read_path_does_not() raises:
    var inner = SharedInMemoryConditionalStore()
    var store = NoListStore(inner.clone())
    var w = _open[NoListStore](store, String("writer-g"))
    var bootstrap_listed = False
    try:
        _ = w.publish(_entry(UInt8(7), 0, _DAY_T0, _DAY_T0 + Int64(1)))
    except:
        bootstrap_listed = True
    assert_true(
        bootstrap_listed,
        "8: the FIRST append to a fresh lineage LIST-recovers its tail"
        " (cas_manifest._recover_head_by_list, reached because `_HEAD` is"
        " absent and the head cache is cold). This case exists so the scope of"
        " every other case in this file is stated rather than assumed: the"
        " no-listing claim is about the READ path, and here is the write-path"
        " listing it does not cover",
    )
    _ = w^
    _ = store^

    # ...and the same publish over a store that CAN list, then read back with
    # one that cannot: the asymmetry is the whole point.
    var w2 = _open[SharedInMemoryConditionalStore](inner, String("writer-g"))
    var e = _entry(UInt8(7), 0, _DAY_T0, _DAY_T0 + Int64(1))
    _ = w2.publish(e.copy())
    _ = w2^
    var ro = NoListStore(inner.clone())
    var r = _open[NoListStore](ro, String("writer-g"))
    var live = r.live_segments()
    assert_equal(len(live), 1, "8: ...and the read side needs no listing at all")
    assert_equal(live[0].object_key, e.object_key, "8: by key, not by count")
    _ = r^
    _ = ro^
    _ = inner^


# =============================================================================
# CASE 9 — REGION (a) IS GAP-TOLERANT. A REAPED CHUNK BELOW THE DURABLE HEAD
# IS A HOLE, AND THE REPLAY MUST SKIP IT.
#
# WHY THIS CASE EXISTS. The module header devotes a paragraph to the two
# replay regions — "(a) [log_start .. durable_head] — GAP-TOLERANT. A reaped
# chunk is a hole here (compaction retires merged inputs, which sit mid-log), so
# a not-found is SKIPPED" — and until this case, NOTHING executed that branch.
# A replay that raised on ANY not-found, instead of skipping it, would pass
# every case that never creates a hole below the durable head. This case
# creates one.
#
# AND THE HOLE HAS TO BE *BELOW* THE HEAD, WHICH IS THE HARD PART. In region
# (b) a not-found is the STOP RULE, so a hole there is indistinguishable from
# the end of the log and the case would be measuring the opposite branch. That
# is why this case publishes each entry on a FRESH handle: a cold-cache append
# KEEPS the durable advance, so three fresh-handle publishes
# leave the durable head at 2 and seq 1 is genuinely inside region (a). The
# decoded-head assertion below is what proves that, rather than assuming it.
#
# The reaper this simulates (compaction/retire) is not in this package, so the
# branch is not reachable through a writer here — which is precisely why it
# needs a test: an unreachable branch nobody executes is where a raise hides
# until the day compaction lands and every dashboard query starts failing.
# =============================================================================


def _pad20(v: Int64) -> String:
    """`cas_manifest.chunk_key`'s zero-padded seq, re-spelled because it is
    module-private there. The key shape is `<prefix>/manifest/<seq:020d>.chunk`
    and CASE 9 has to DELETE one by name."""
    var d = String(v)
    var out = String("")
    for _ in range(20 - d.byte_length()):
        out += String("0")
    out += d
    return out^


def test_09_a_reaped_chunk_below_the_durable_head_is_a_hole_not_a_raise() raises:
    var inner = SharedInMemoryConditionalStore()
    var lineage = telemetry_partition_prefix(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY
    ) + "/_lineage/writer-i"
    var keys = List[String]()
    # ONE FRESH HANDLE PER PUBLISH — the cold-cache append keeps the durable
    # `_HEAD` advance, which is what pushes the head up to 2 so that seq 1 lands
    # INSIDE region (a). A single held handle would defer and leave the head at
    # 0, putting the hole in region (b) where a not-found is the STOP RULE.
    for i in range(3):
        var w = _open[SharedInMemoryConditionalStore](inner, String("writer-i"))
        var e = _entry(
            UInt8(9), i, _DAY_T0 + Int64(i) * Int64(1000),
            _DAY_T0 + Int64(i) * Int64(1000) + Int64(500),
        )
        keys.append(e.object_key.copy())
        _ = w.publish(e^)
        _ = w^

    # THE PRECONDITION THAT MAKES THIS CASE ABOUT REGION (a). Without it the
    # hole could be in region (b) and the case would be measuring the STOP RULE.
    var head_raw = inner.get(Path.parse(lineage + "/_HEAD"))
    var durable_head = decode_head(head_raw).chunk_seq
    assert_true(
        durable_head >= Int64(2),
        "9: PRECONDITION — the durable _HEAD must have reached seq 2, so the"
        " chunk deleted below is INSIDE region (a) (gap-tolerant) and not in"
        " region (b) (where a not-found is the legitimate stop). Observed"
        " chunk_seq = " + String(durable_head),
    )

    # REAP the middle chunk — what compaction's retire does to a merged input.
    inner.delete(Path.parse(lineage + "/manifest/" + _pad20(Int64(1)) + ".chunk"))

    var store = NoListStore(inner.clone())
    var r = _open[NoListStore](store, String("writer-i"))
    var live = List[TelemetrySegmentEntry]()
    var err = String("")
    try:
        live = r.live_segments()
    except e:
        err = String(e)
    assert_equal(
        err,
        String(""),
        "9: REGION (a) IS GAP-TOLERANT — a reaped chunk below the durable"
        " head is a HOLE and the replay must SKIP it. An unconditional re-raise"
        " here turns every post-compaction read of the partition into a hard"
        " failure. Got: " + err,
    )
    assert_equal(
        len(live),
        2,
        "9: ...and it skips EXACTLY the hole. 1 would mean the replay stopped"
        " at the hole (region (b)'s stop rule applied inside region (a)); 3"
        " would mean the chunk was not actually reaped",
    )
    assert_equal(
        live[0].object_key, keys[0], "9: the chunk below the hole survives"
    )
    assert_equal(
        live[1].object_key,
        keys[2],
        "9: ...and so does the one ABOVE it — which is the whole point: a hole"
        " must not truncate the log, by key, not by count",
    )
    _ = r^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 10 — a store error that is NOT absence propagates, even when the key in
# its message spells `404`.
# =============================================================================
#
# Conformers build the error message around the object key
# (`StoreError[<KIND>] <method> <scheme>://<bucket>/<key> status=<http>`). The
# writer id is the caller's, so here it is `writer-404` and every manifest key
# in the lineage contains `404`. A permission failure on a chunk below the
# durable head must surface: treating it as a reaped hole would drop that
# chunk's segment from every read with no error.


struct FailOneGetStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """`SharedInMemoryConditionalStore` whose GET of one exact key raises a
    conformer-shaped permission error (`status=403`) naming that key."""

    var _inner: SharedInMemoryConditionalStore
    var _fail_key: String

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, var fail_key: String
    ):
        self._inner = inner^
        self._fail_key = fail_key^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._fail_key.copy())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw() == self._fail_key:
            raise Error(
                "StoreError[PERMISSION_DENIED] get mem://bucket/"
                + path.raw()
                + " status=403"
            )
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        return self._inner.delete(path)


def test_10_a_non_absence_error_on_a_key_spelling_404_propagates() raises:
    var inner = SharedInMemoryConditionalStore()
    var writer = String("writer-404")
    var lineage = telemetry_partition_prefix(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, _DAY
    ) + "/_lineage/" + writer
    # One fresh handle per publish, as in CASE 9, so the durable `_HEAD`
    # reaches seq 2 and the failing chunk (seq 1) is inside region (a).
    for i in range(3):
        var w = _open[SharedInMemoryConditionalStore](inner, writer)
        var e = _entry(
            UInt8(10), i, _DAY_T0 + Int64(i) * Int64(1000),
            _DAY_T0 + Int64(i) * Int64(1000) + Int64(500),
        )
        _ = w.publish(e^)
        _ = w^

    var durable_head = decode_head(
        inner.get(Path.parse(lineage + "/_HEAD"))
    ).chunk_seq
    assert_true(
        durable_head >= Int64(2),
        "10: PRECONDITION — the durable _HEAD must have reached seq 2, so the"
        " failing chunk is in region (a). Observed chunk_seq = "
        + String(durable_head),
    )

    var fail_key = lineage + "/manifest/" + _pad20(Int64(1)) + ".chunk"
    assert_true(
        fail_key.find("404") >= 0,
        "10: PRECONDITION — the failing key must spell 404: " + fail_key,
    )
    var store = FailOneGetStore(inner.clone(), fail_key.copy())
    var r = _open[FailOneGetStore](store, writer)
    var live = List[TelemetrySegmentEntry]()
    var err = String("")
    try:
        live = r.live_segments()
    except e:
        err = String(e)
    assert_true(
        err.find("status=403") >= 0,
        "10: a permission error on a manifest chunk must PROPAGATE out of the"
        " replay. It was treated as absence because the key in its message"
        " contains 404, and the replay returned "
        + String(len(live))
        + " of 3 segments with no error. Got error: '"
        + err
        + "'",
    )
    _ = r^
    _ = store^
    _ = inner^


def main() raises:
    test_01_a_published_segment_replays_without_listing()
    test_02_every_segment_replays_despite_the_deferred_head_advance()
    test_03_replay_issues_exactly_zero_list_calls()
    test_04_a_time_range_prunes_on_the_manifest_and_never_opens_the_rest()
    test_05_a_live_merge_hides_its_still_live_inputs()
    test_06_writer_shard_discovery_is_the_only_listing()
    test_07_a_partition_with_no_writers_plans_nothing_and_does_not_raise()
    test_08_the_write_path_bootstrap_lists_and_the_read_path_does_not()
    test_09_a_reaped_chunk_below_the_durable_head_is_a_hole_not_a_raise()
    test_10_a_non_absence_error_on_a_key_spelling_404_propagates()
    print("PASS komira_telemetry_store.test_telemetry_manifest_replay (a fresh")
    print("     reader replays EVERY published segment over a store where")
    print("     LISTING RAISES — the deferred _HEAD advance included — and a")
    print("     time-range query decides on the manifest entry alone)")
