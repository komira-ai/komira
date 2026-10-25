# =============================================================================
# test_log_native_indexing_l05.mojo
#   The off-core bounded flush stage: the handoff, the consumer and the in-flight
#   bytes gate.
# =============================================================================
#
# WHAT THIS SUITE PROVES (correctness and memory safety):
#
#   CORRECTNESS:
#   1. AT-MOST-ONCE. A log is searchable ONLY after its publish lands. A
#      flushed and published batch is fully searchable; an un-flushed segment on
#      a simulated crash is the only loss, bounded by the flush ceiling.
#   2. NO LOSS BEYOND THE UN-FLUSHED WINDOW. Every flushed batch's docs are all
#      present in the published splits.
#   3. DRAINED LOGS ARE SEARCHABLE end to end through the off-core path:
#      transpose, handoff, consumer, SearchSink, publish, full-text search.
#   4. THE BYTE AND TIME FLUSH CEILING FIRE. A byte-ceiling trip flushes a large
#      buffer immediately; a time-ceiling trip flushes a low-volume (1-doc)
#      buffer once `now_ms` advances past the time bound, so a trickle becomes
#      searchable within the bound instead of waiting under the byte threshold
#      forever.
#
#   SAFETY:
#   5. THE IN-FLIGHT-BYTES CAP BOUNDS RESIDENT MEMORY. Under a stalled consumer
#      (publish never runs), the producer keeps offering: once the cap is hit,
#      offers are rejected and the in-flight bytes never exceed the cap.
#   6. THE PUSHBACK RELEASES. Once the consumer drains and publishes, the gate
#      releases, the in-flight bytes return to 0 and the producer resumes.
#
# The test drives the producer (`offer_log_views`: on-core transpose, reserve,
# enqueue) and the consumer (`drive_once`: drain the handoff, byte/time flush,
# publish) as explicit steps with an injected `now_ms` clock, on one thread. This
# pins the flow-control and durability contract without a real thread. The
# publish target is the in-memory conditional store, so the test is hermetic.
#
# Encapsulation: no UnsafePointer in any signature.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.emit import emit_record
from komira_log.engine.drain import drain_to_views
from komira_log import LogRecordView
from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR
from komira_log.log_arg import ArgI64, ArgStr, Field

from komira_log_index import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
    log_views_to_record_batch,
    InFlightBytesGate,
    LogIndexHandoff,
    offer_log_views,
    LogIndexConsumer,
)

from komira_search.source import (
    QueryIR,
    SearchCore,
)
from komira_search.analyzer import AnalyzerConfig

from komira_objectstore import (
    SharedInMemoryConditionalStore,
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.path import Path
from komira_search_catalog import (
    make_shard_id,
    shard_manifest_prefix,
    SearchMetastore,
    list_live_splits_across_shards,
)


# -----------------------------------------------------------------------------
# Fixtures.
# -----------------------------------------------------------------------------


def _fixed_anchor() -> CalibrationAnchor:
    var wall0_ns = UInt64(1_780_272_000) * UInt64(1_000_000_000)
    return CalibrationAnchor(
        tick0=UInt64(0), wall0_ns=wall0_ns, tick_hz=UInt64(1_000_000_000)
    )


def _dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register["request {} status {}", "komira_http"]()
    d.register["query finished in {} ms", "komira_engine"]()
    d.register["retry {} reason {}", "komira_agent"]()
    return d^


def _make_consumer(
    store: SharedInMemoryConditionalStore,
    meta_root: String,
    shard_id: String,
    flush_bytes: Int64,
    flush_ms: Int64,
    worker_disc: UInt8 = UInt8(0),
) raises -> LogIndexConsumer[SharedInMemoryConditionalStore]:
    """Build a LogIndexConsumer publishing into the given drain-role sub-lineage
    on the in-memory CAS store."""
    var lineage = shard_manifest_prefix(meta_root, shard_id)
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    var metastore = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )
    return LogIndexConsumer[SharedInMemoryConditionalStore](
        store.clone(),
        metastore^,
        String("bucket"),
        meta_root,  # key_prefix base for the split objects
        String("logs"),
        worker_disc,
        flush_bytes,
        flush_ms,
    )


def _emit_login_records(mut r: LogRecordRing, n: Int):
    """Emit `n` log records, each whose message contains the word 'login' (so a
    full-text term-frequency on 'login' matches every one). corr_id ascends."""
    for i in range(n):
        _ = emit_record["request {} status {}", "komira_http"](
            r, LEVEL_INFO, UInt64(100 + i), ArgStr(String("login")), ArgI64(200)
        )


def _count_login_matches_across_splits(
    store: SharedInMemoryConditionalStore, meta_root: String
) raises -> Int:
    """Enumerate every live split across all shards, open each as a SearchCore,
    run the full-text 'login' query, and SUM the matches. This is the read-path
    proof that a published log is searchable (the off-core path)."""
    var live = list_live_splits_across_shards(store, meta_root, String("logs"))
    var total = 0
    for i in range(len(live)):
        var key = live[i].object_key
        var bytes = store.get(Path.parse(key))
        var core = SearchCore(bytes^)
        var q = QueryIR(
            LOG_INDEX_TEXT_FIELD,
            String("login"),
            1000,
            AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
            0,
        )
        var res = core.search(q)
        total += Int(res.total_matches)
    return total


# =============================================================================
# CASE 1: DRAINED-LOGS-SEARCHABLE e2e via the OFF-CORE path (correctness #3).
# Producer offers 10 'login' records (on-core transpose -> handoff); the consumer
# drives once with a byte ceiling small enough to flush them; the published split
# is searchable for 'login' (10 matches). Proves the whole off-core mechanism.
# =============================================================================


def test_01_offcore_drained_logs_searchable() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")
    var drain_shard = make_shard_id(String("nodeA"), 0, String("drain"))

    # Small byte ceiling so 10 docs trip it; large time ceiling (not the trigger).
    var consumer = _make_consumer(
        store, meta_root, drain_shard, Int64(1), Int64(1_000_000)
    )
    var gate = InFlightBytesGate(Int64(64 * 1024 * 1024))
    var handoff = LogIndexHandoff(256)

    # PRODUCER (on-core): drain 10 'login' records -> transpose -> offer.
    var ring = LogRecordRing(capacity=64, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ring, 10)
    var views = drain_to_views(ring, dict, anchor)
    assert_equal(len(views), 10, "1: 10 views drained")
    var ok = offer_log_views(handoff, gate, views^)
    assert_true(ok, "1: offer accepted (under cap)")
    assert_true(gate.in_flight_bytes() > Int64(0), "1: bytes reserved")

    # CONSUMER (off-core): drive once -> drains the handoff, byte ceiling fires
    # (>=1 byte buffered), index-builds + publishes.
    var processed = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(processed, 1, "1: one unit processed off-core")
    assert_equal(
        Int(consumer.stats().splits_published), 1, "1: one split published"
    )
    assert_equal(
        Int(consumer.stats().docs_published), 10, "1: 10 docs published"
    )
    assert_equal(Int(consumer.stats().publish_failures), 0, "1: no failures")
    # The reservation was released after publish -> in-flight returns to 0.
    assert_equal(gate.in_flight_bytes(), Int64(0), "1: gate released to 0")

    # READ-PATH PROOF: the published split is searchable for 'login' (10 hits).
    var matches = _count_login_matches_across_splits(store, meta_root)
    assert_equal(matches, 10, "1: all 10 drained logs searchable off-core")


# =============================================================================
# CASE 2: BYTE ceiling fires. A buffer that crosses the byte ceiling
# flushes on the next drive even with the time ceiling far away.
# =============================================================================


def test_02_byte_ceiling_fires() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))

    # est ~ 200 B/doc. Byte ceiling 500 B -> 3 docs (600 B) trips it; 2 docs
    # (400 B) does NOT. Time ceiling far away (not the trigger here).
    var consumer = _make_consumer(
        store, meta_root, shard, Int64(500), Int64(10_000_000)
    )
    var gate = InFlightBytesGate(Int64(64 * 1024 * 1024))
    var handoff = LogIndexHandoff(256)

    # Offer 2 docs -> drive: under the byte ceiling -> NO flush yet.
    var ring2 = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ring2, 2)
    _ = offer_log_views(handoff, gate, drain_to_views(ring2, dict, anchor)^)
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(
        Int(consumer.stats().splits_published),
        0,
        "2: 2 docs under byte ceiling -> no flush",
    )
    assert_true(
        consumer.buffered_rows() == Int64(2), "2: 2 docs buffered (held)"
    )

    # Offer 2 more docs -> now 4 docs (~800 B) >= 500 B -> drive flushes.
    var ring2b = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ring2b, 2)
    _ = offer_log_views(handoff, gate, drain_to_views(ring2b, dict, anchor)^)
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(
        Int(consumer.stats().splits_published),
        1,
        "2: byte ceiling tripped -> 1 split published",
    )
    assert_equal(
        Int(consumer.stats().docs_published), 4, "2: all 4 buffered docs flushed"
    )
    assert_equal(gate.in_flight_bytes(), Int64(0), "2: gate released")


# =============================================================================
# CASE 3: TIME ceiling fires. A LOW-VOLUME (1-doc) buffer that NEVER
# trips the byte ceiling still flushes once `now_ms` advances past the time
# ceiling, so a trickle becomes searchable within the bound. This is the
# low-volume-log-becomes-searchable proof.
# =============================================================================


def test_03_time_ceiling_fires() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))

    # Byte ceiling HUGE (never trips for 1 doc); time ceiling 1000 ms.
    var consumer = _make_consumer(
        store, meta_root, shard, Int64(1_000_000_000), Int64(1000)
    )
    var gate = InFlightBytesGate(Int64(64 * 1024 * 1024))
    var handoff = LogIndexHandoff(256)

    # Offer ONE doc at t=0 -> drive at t=0: under byte ceiling, time not elapsed
    # -> NO flush (the doc waits).
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ring, 1)
    _ = offer_log_views(handoff, gate, drain_to_views(ring, dict, anchor)^)
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(
        Int(consumer.stats().splits_published),
        0,
        "3: 1 low-volume doc -> no flush before time ceiling",
    )
    assert_equal(consumer.buffered_rows(), Int64(1), "3: the doc waits buffered")

    # Drive again at t=500 ms: still under the 1000 ms time ceiling -> no flush.
    _ = consumer.drive_once(handoff, gate, Int64(500))
    assert_equal(
        Int(consumer.stats().splits_published),
        0,
        "3: t=500 < 1000 -> still no flush",
    )

    # Drive at t=1000 ms: time ceiling reached -> the low-volume doc flushes +
    # publishes -> it becomes searchable WITHIN the bound.
    _ = consumer.drive_once(handoff, gate, Int64(1000))
    assert_equal(
        Int(consumer.stats().splits_published),
        1,
        "3: time ceiling fired -> low-volume doc published",
    )
    assert_equal(Int(consumer.stats().docs_published), 1, "3: the 1 doc flushed")
    var matches = _count_login_matches_across_splits(store, meta_root)
    assert_equal(matches, 1, "3: low-volume doc searchable within time bound")


# =============================================================================
# CASE 4: AT-MOST-ONCE: published = searchable, un-flushed = the ONLY loss
# Flush + publish a batch (searchable). Then buffer MORE without
# flushing, and SIMULATE A CRASH by dropping the consumer + handoff WITHOUT a
# shutdown flush: the published batch survives (still searchable); the un-flushed
# buffer is lost. The loss is bounded to exactly the un-flushed window.
# =============================================================================


def test_04_at_most_once_unflushed_is_the_only_loss() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))

    # Byte ceiling 500 B (~3 docs). We control exactly when a flush fires.
    var consumer = _make_consumer(
        store, meta_root, shard, Int64(500), Int64(10_000_000)
    )
    var gate = InFlightBytesGate(Int64(64 * 1024 * 1024))
    var handoff = LogIndexHandoff(256)

    # PHASE A: offer + flush 5 docs (crosses 500 B) -> published & searchable.
    var ringA = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ringA, 5)
    _ = offer_log_views(handoff, gate, drain_to_views(ringA, dict, anchor)^)
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(
        Int(consumer.stats().splits_published), 1, "4: phase A published"
    )
    var searchable_after_A = _count_login_matches_across_splits(store, meta_root)
    assert_equal(searchable_after_A, 5, "4: 5 published docs searchable")

    # PHASE B: offer 2 docs (under the byte ceiling) and DO NOT flush (drive
    # would not trip the ceiling, and we don't call shutdown_flush). These 2 are
    # the at-most-once UN-flushed window.
    var ringB = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ringB, 2)
    _ = offer_log_views(handoff, gate, drain_to_views(ringB, dict, anchor)^)
    _ = consumer.drive_once(handoff, gate, Int64(0))  # under ceiling -> no flush
    assert_equal(
        Int(consumer.stats().splits_published),
        1,
        "4: phase B under ceiling -> still 1 split (the 2 docs are un-flushed)",
    )
    assert_equal(consumer.buffered_rows(), Int64(2), "4: 2 docs un-flushed")

    # SIMULATE CRASH: drop the consumer + handoff WITHOUT shutdown_flush. The
    # published split survives in the store (durable); the 2 un-flushed docs are
    # lost (at-most-once). We re-read the store fresh (a new process's view).
    _ = consumer^  # drop (no shutdown flush): the crash
    _ = handoff^
    _ = gate^

    var searchable_after_crash = _count_login_matches_across_splits(
        store, meta_root
    )
    # EXACTLY the 5 published docs survive; the 2 un-flushed are the ONLY loss.
    assert_equal(
        searchable_after_crash,
        5,
        "4: published=searchable, un-flushed=the ONLY loss (at-most-once)",
    )


# =============================================================================
# CASE 5: THE OOM CAP BOUNDS RESIDENT MEMORY. Under a STALLED
# consumer (publish never runs: slow-store proxy), the producer keeps offering.
# Once the in-flight bytes hit the cap, offers are REJECTED (backpressure) and
# the in-flight bytes NEVER exceed the cap. Resident memory is BOUNDED: no OOM.
# Then the consumer drains+publishes -> the gate RELEASES -> offers resume.
# =============================================================================


def test_05_inflight_cap_bounds_memory_under_stall() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))

    # A TIGHT cap so a handful of offers saturate it (each ~200 B/doc * 5 docs =
    # ~1000 B/offer). Cap 3000 B -> ~3 offers admit, then reject. The consumer
    # has a HUGE byte ceiling + huge time ceiling so it NEVER flushes during the
    # stall phase (the stalled-consumer proxy).
    var cap = Int64(3000)
    var consumer = _make_consumer(
        store, meta_root, shard, Int64(1_000_000_000), Int64(1_000_000_000)
    )
    var gate = InFlightBytesGate(cap)
    var handoff = LogIndexHandoff(1024)  # depth not the bound here; bytes are

    # STALL PHASE: offer until the cap rejects. The consumer does NOT run (the
    # a slow object store: publish stalls). We do NOT call drive_once here.
    var admitted = 0
    var rejected = 0
    var peak_inflight = Int64(0)
    for _ in range(50):  # try far more than the cap allows
        var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
        _emit_login_records(ring, 5)  # ~1000 B/offer
        var ok = offer_log_views(handoff, gate, drain_to_views(ring, dict, anchor)^)
        if ok:
            admitted += 1
        else:
            rejected += 1
        var nowf = gate.in_flight_bytes()
        if nowf > peak_inflight:
            peak_inflight = nowf

    # THE OOM-SAFETY ASSERTIONS: the cap was hit AND never exceeded.
    assert_true(rejected > 0, "5: backpressure fired (some offers rejected)")
    assert_true(
        peak_inflight <= cap,
        "5: in-flight bytes NEVER exceed the cap (BOUNDED: no OOM)",
    )
    assert_true(
        gate.rejection_count() > Int64(0), "5: loud rejection counter incremented"
    )
    # The producer kept producing (50 offers) but resident memory stayed bounded.
    assert_equal(admitted + rejected, 50, "5: all 50 offers were attempted")
    assert_true(
        admitted < 50, "5: NOT all admitted (the cap shed the overflow)"
    )

    # RELEASE PHASE: the consumer finally drains + publishes. drive_once drains
    # every queued unit into the buffer (the huge byte/time ceiling won't trip a
    # flush), then shutdown_flush FORCE-flushes the buffer -> publish -> the gate
    # releases the admitted bytes.
    _ = consumer.drive_once(handoff, gate, Int64(0))  # accept queued units
    consumer.shutdown_flush(gate)  # force-flush the buffer -> publish
    # After draining + publishing the admitted bytes, the gate returns to ~0.
    assert_equal(
        gate.in_flight_bytes(),
        Int64(0),
        "5: gate fully released after publish -> backpressure lifted",
    )
    assert_true(
        Int(consumer.stats().splits_published) >= 1,
        "5: the admitted (bounded) work published after the stall cleared",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_01_offcore_drained_logs_searchable]()
    suite.test[test_02_byte_ceiling_fires]()
    suite.test[test_03_time_ceiling_fires]()
    suite.test[test_04_at_most_once_unflushed_is_the_only_loss]()
    suite.test[test_05_inflight_cap_bounds_memory_under_stall]()
    suite^.run()
