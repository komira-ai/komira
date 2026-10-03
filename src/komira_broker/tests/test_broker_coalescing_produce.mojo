# =============================================================================
# tests/test_broker_coalescing_produce.mojo
#   The GATE for the BROKER produce path on the CoalescingWindow primitive
#   (the parkable path).
# =============================================================================
#
# The produce path (komira_broker.broker_coalescing_produce)
# plugs the 3 broker conformers (BrokerHeadReader / BrokerSegCodec /
# BrokerBatchAppender) into the GENERAL coalescing-window spine and drives ONE
# CoalescingWindow per partition (BrokerCoalescingProduce). This GATE drives it
# end-to-end over the in-mem slow-CAS rig (the same SharedInMemorySlowCasStore the
# primitive's own test parks on), asserting:
#
#   (1) at-least-once COALESCING: offer N batches under the count/size band off,
#       FORCE one explicit flush -> ONE manifest chunk carrying all N batches'
#       records, the offset range contiguous from 0 (behavior-preserving vs the
#       bespoke flush).
#   (a) MANDATORY — IDEMPOTENT-mode conformer test: an EOS produce (configure_eos
#       _singleton + buffer one + force) flushes ONE producer batch per spine
#       (the acks=all singleton path); a DUPLICATE re-produce of the SAME
#       (producer_id, first_seq) is DEDUPED (append_idempotent reports DUPLICATE,
#       the recorded offset returned, NO second chunk). Without this, the
#       broker's EOS path is not trustworthy.
#   (b) MANDATORY — parkable-produce test: a produce on a SLOW-CAS store PARKS
#       (the stage-blob PUT + the exact-slot create-CAS park on the reactor),
#       and a DIFFERENT partition's produce makes progress WHILE the first is
#       parked — the burst-stall fix, structurally.
#   (c) MANDATORY — acks=all singleton fast-path: a 1-batch EXPLICIT force flushes
#       the singleton (no coalescing) and acks the offset.
#   (2) the EOS singleton invariant GUARD: an EOS append with no producer identity
#       raises (the N==1 singleton contract — defense-in-depth).
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins, no
# unsafe_from_address / take_pointee.
# =============================================================================

from std.sys.info import CompilationTarget

from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_broker.broker_coalescing_produce import (
    BrokerBatchAppender,
    BrokerCoalescingProduce,
    BrokerProduceItem,
    BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
    BPO_AT_LEAST_ONCE,
    BPO_EOS_COMMITTED,
    BPO_EOS_DUPLICATE,
)

from komira_broker.broker_core import SegmentFooter
from komira_broker.manifest_body import ManifestBody

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)


comptime _Slow = SharedInMemorySlowCasStore
comptime _Shared = SharedInMemoryConditionalStore
comptime _SlowMeta = CasManifestStore[_Slow]
# The verification meta reads the SAME inner Arc-backed map as the driver's WAL
# (built over `slow.inner_ref().clone()` — the inner _Shared store the _Slow
# store wraps), so num_chunks() observes the committed chunks.
comptime _SharedMeta = CasManifestStore[_Shared]


# =============================================================================
# rig — a real (epoll/kqueue) reactor so the slow-CAS register_timer FIRES.
# =============================================================================
def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    """ONE-column `val:INT64` batch where val == base_val + i (mirrors the broker
    flush-elision test's builder — so val == its absolute offset by construction
    across the topic)."""
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_driver(
    var slow: _Slow, cluster: String, topic: String, pid: Int64
) raises -> BrokerCoalescingProduce[_Slow]:
    return BrokerCoalescingProduce[_Slow](
        slow^, cluster, topic, pid, String("broker-A")
    )


def _drive_to_done(
    mut win: BrokerCoalescingProduce[_Slow],
    mut reactor: Reactor[NoopSink],
    guard_max: Int = 256,
) raises:
    """Drive the in-flight produce flush to completion via the reactor demux (the
    same loop the primitive's test uses)."""
    var guard = 0
    while win.is_inflight() and guard < guard_max:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1


def _meta_chunks(slow: _Slow, cluster: String, topic: String, pid: Int64) raises -> Int64:
    var prefix = _partition_prefix(cluster, topic, pid)
    var meta = _SharedMeta(slow.inner_ref().clone(), prefix^)
    return meta.num_chunks()


def _shared_meta(
    slow: _Slow, cluster: String, topic: String, pid: Int64
) raises -> _SharedMeta:
    """A verification meta over the SAME inner Arc-backed map the driver's WAL
    wrote to — so read_chunk(seq) (the committed manifest body) + get_object(key)
    (the staged segment blob) both observe the durable bytes."""
    var prefix = _partition_prefix(cluster, topic, pid)
    return _SharedMeta(slow.inner_ref().clone(), prefix^)


# =============================================================================
# (1) at-least-once COALESCING — offer N batches, force ONE flush, ONE chunk.
# =============================================================================
def test_at_least_once_coalesces_n_batches_one_chunk() raises:
    """Offer N producer batches (the count/size bands off), FORCE one explicit
    flush -> the spine coalesces all N into ONE Arrow-IPC segment + ONE manifest
    chunk; every produce shares the won chunk_seq; the offset range starts at 0
    and is contiguous. Behavior-preserving vs the bespoke `flush`."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)  # instant reads/appends -> burst convergence.
    var win = _make_driver(
        slow.clone(), String("cl"), String("topic-alo"), Int64(0)
    )
    # Offer 4 batches of 3 records each (12 records total). The count band is off
    # (the driver's policy has max_count=0); the size band is 8 MiB (far off), so
    # NOTHING auto-flushes — the buffer accumulates.
    var N = 4
    var recs_per = 3
    for i in range(N):
        var op = win.produce[NoopSink](
            _make_int64_batch(Int64(i * recs_per), recs_per),
            Int64(i),
            reactor,
        )
        _ = op
    assert_false(win.is_inflight(), "no auto-flush (bands off)")
    assert_equal(win.pending_count(), N, "all N batches buffered (coalescing)")

    # FORCE one explicit flush — coalesce all N into ONE chunk.
    win.reconfigure_at_least_once()
    var fop = win.force[NoopSink](Int64(100), reactor)
    _ = fop
    _drive_to_done(win, reactor)
    assert_false(win.is_inflight(), "the coalesced flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())

    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), N, "all N producer batches got an outcome")
    # All N share ONE chunk_seq (one coalesced append) + the at-least-once kind.
    var seq0 = outcomes[0][1].chunk_seq
    for i in range(N):
        assert_equal(
            outcomes[i][1].chunk_seq, seq0, "all N share one chunk_seq"
        )
        assert_equal(
            Int(outcomes[i][1].eos_kind),
            Int(BPO_AT_LEAST_ONCE),
            "at-least-once discriminant",
        )
    # The coalesced chunk's offset range is [0 .. 11] (12 records).
    assert_equal(outcomes[0][1].base_offset, Int64(0), "offset base 0")
    assert_equal(
        outcomes[0][1].last_offset, Int64(N * recs_per - 1), "last offset 11"
    )
    # EXACTLY ONE chunk committed.
    assert_equal(
        Int(_meta_chunks(slow, String("cl"), String("topic-alo"), Int64(0))),
        1,
        "exactly one coalesced chunk",
    )
    print("  test_at_least_once_coalesces_n_batches_one_chunk: PASS")


# =============================================================================
# (a) MANDATORY — IDEMPOTENT-mode conformer test: EOS singleton flush + dedup.
# =============================================================================
def test_eos_singleton_flush_and_dedup() raises:
    """The singleton-mode gate — the broker's EOS path is not trustworthy without this.

    An EOS produce (configure_eos_singleton + buffer ONE batch + force) flushes
    exactly ONE producer batch per spine (the acks=all singleton path) and commits
    via append_idempotent. A re-produce of the SAME (producer_id, first_seq) is
    DEDUPED: append_idempotent reports DUPLICATE, the RECORDED offset is returned,
    and NO second chunk is appended.

    FALSIFIES a non-EOS path: were the appender to drive the at-least-once
    `append` (or to coalesce N>1 under one dedup key), the duplicate re-produce
    would append a SECOND chunk (num_chunks() == 2) and report a fresh offset —
    this test asserts num_chunks() stays 1 and the discriminant flips
    COMMITTED -> DUPLICATE with the SAME offset."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)
    var win = _make_driver(
        slow.clone(), String("cl"), String("topic-eos"), Int64(0)
    )

    var producer_id = Int64(7)
    var producer_epoch = Int64(0)
    var first_seq = Int64(0)
    var last_seq = Int64(2)  # a 3-record batch: seqs 0,1,2.

    # ---- First EOS produce: buffer ONE batch, configure EOS, force. ----
    win.buffer[NoopSink](_make_int64_batch(Int64(0), 3), Int64(0), reactor)
    assert_equal(win.pending_count(), 1, "exactly one buffered (EOS singleton)")
    win.reconfigure_eos_singleton(
        producer_id, producer_epoch, first_seq, last_seq, Int64(0)
    )
    var fop = win.force[NoopSink](Int64(100), reactor)
    _ = fop
    _drive_to_done(win, reactor)
    assert_false(win.is_inflight(), "the EOS singleton flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())

    var oc1 = win.take_outcomes()
    assert_equal(len(oc1), 1, "the EOS singleton committed exactly one outcome")
    assert_true(win.last_eos_engaged(), "the EOS cell was stamped")
    assert_equal(
        Int(win.last_eos_kind()),
        Int(BPO_EOS_COMMITTED),
        "the first EOS produce is COMMITTED",
    )
    var committed_base = win.last_eos_base_offset()
    var committed_last = win.last_eos_last_offset()
    assert_equal(committed_base, Int64(0), "EOS committed base offset 0")
    assert_equal(committed_last, Int64(2), "EOS committed last offset 2")
    assert_equal(
        Int(_meta_chunks(slow, String("cl"), String("topic-eos"), Int64(0))),
        1,
        "one chunk after the first EOS produce",
    )

    # ---- DUPLICATE re-produce: the SAME (producer_id, first_seq). ----
    win.buffer[NoopSink](_make_int64_batch(Int64(0), 3), Int64(0), reactor)
    win.reconfigure_eos_singleton(
        producer_id, producer_epoch, first_seq, last_seq, Int64(0)
    )
    var fop2 = win.force[NoopSink](Int64(200), reactor)
    _ = fop2
    _drive_to_done(win, reactor)
    assert_false(win.is_inflight(), "the duplicate EOS flush completed")
    assert_false(win.has_error(), "no error on duplicate: " + win.err_text())

    var oc2 = win.take_outcomes()
    assert_equal(len(oc2), 1, "the duplicate produce still yields one outcome")
    assert_equal(
        Int(win.last_eos_kind()),
        Int(BPO_EOS_DUPLICATE),
        "the SAME (producer_id, first_seq) is DEDUPED -> DUPLICATE",
    )
    # The DUPLICATE returns the RECORDED offset (no new offset assigned).
    assert_equal(
        win.last_eos_base_offset(),
        committed_base,
        "duplicate returns the recorded base offset (idempotent ack)",
    )
    assert_equal(
        win.last_eos_last_offset(),
        committed_last,
        "duplicate returns the recorded last offset",
    )
    # NO second chunk — the dedup blocked the re-append.
    assert_equal(
        Int(_meta_chunks(slow, String("cl"), String("topic-eos"), Int64(0))),
        1,
        "NO second chunk — append_idempotent deduped the duplicate",
    )
    print("  test_eos_singleton_flush_and_dedup: PASS")


# =============================================================================
# (b) MANDATORY — parkable-produce: one produce parks while another progresses.
# =============================================================================
def test_parkable_produce_other_partition_progresses() raises:
    """The burst-stall fix, structurally. A produce on a SLOW-CAS store PARKS
    (the stage-blob PUT + the exact-slot create-CAS each park on the reactor); a
    DIFFERENT partition's produce on an INSTANT store completes WHILE the first is
    still parked — proving the parked produce does not block other work.

    FALSIFIES a blocking handler: a synchronous flush would not yield control
    between the stage-blob PUT and the append, so the second partition could not
    run until the first fully drained. Here we assert partition-1 commits its
    chunk WHILE partition-0 is observably still in-flight (parked)."""
    var reactor = _new_reactor()
    # Partition 0: a SLOW store (stage-blob + append park multiple ticks).
    var slow0 = _Slow(slow_ticks=3)
    var win0 = _make_driver(
        slow0.clone(), String("cl"), String("topic-park"), Int64(0)
    )
    # Partition 1: an INSTANT store (its produce converges in the start burst).
    var slow1 = _Slow(slow_ticks=0)
    var win1 = _make_driver(
        slow1.clone(), String("cl"), String("topic-park"), Int64(1)
    )

    # Start partition 0's flush — it PARKS (the stage-blob / append on slow0).
    win0.buffer[NoopSink](_make_int64_batch(Int64(0), 5), Int64(0), reactor)
    win0.reconfigure_at_least_once()
    var op0 = win0.force[NoopSink](Int64(10), reactor)
    assert_true(win0.is_inflight(), "partition-0 produce is parked mid-flight")
    assert_true(op0 != Int64(0), "partition-0 parked on a biased op_id")

    # WHILE partition 0 is parked: partition 1 produces + converges in its start
    # burst (instant store) — it does NOT wait for partition 0.
    win1.buffer[NoopSink](_make_int64_batch(Int64(0), 4), Int64(1), reactor)
    win1.reconfigure_at_least_once()
    var op1 = win1.force[NoopSink](Int64(11), reactor)
    _ = op1
    _drive_to_done(win1, reactor, guard_max=16)
    assert_false(win1.is_inflight(), "partition-1 completed WHILE p0 parked")
    assert_false(win1.has_error(), "p1 no error: " + win1.err_text())
    var oc1 = win1.take_outcomes()
    assert_equal(len(oc1), 1, "partition-1 produce committed its batch")
    assert_equal(
        Int(_meta_chunks(slow1, String("cl"), String("topic-park"), Int64(1))),
        1,
        "partition-1 chunk committed while p0 still parked",
    )
    # Partition 0 is STILL parked (it has not been driven) — the discriminating
    # proof that p1 ran independently of p0's parked flush.
    assert_true(
        win0.is_inflight(),
        "partition-0 is STILL parked (p1 progressed without draining p0)",
    )

    # Now drain partition 0 to completion (the parked produce resumes + commits).
    _drive_to_done(win0, reactor)
    assert_false(win0.is_inflight(), "partition-0 produce eventually completed")
    assert_false(win0.has_error(), "p0 no error: " + win0.err_text())
    var oc0 = win0.take_outcomes()
    assert_equal(len(oc0), 1, "partition-0 produce committed after the park")
    assert_equal(
        Int(_meta_chunks(slow0, String("cl"), String("topic-park"), Int64(0))),
        1,
        "partition-0 chunk committed after resuming",
    )
    print("  test_parkable_produce_other_partition_progresses: PASS")


# =============================================================================
# (c) MANDATORY — acks=all singleton fast-path: a 1-batch EXPLICIT force.
# =============================================================================
def test_acks_all_singleton_fast_path() raises:
    """A 1-batch EXPLICIT force (the acks=all single-record commit hot path)
    flushes the singleton (no coalescing) and acks the offset range. The
    singleton drain is an O(1) whole-Slab move (the primitive's committed-singleton
    fast path) — no per-item realloc."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)
    var win = _make_driver(
        slow.clone(), String("cl"), String("topic-single"), Int64(0)
    )

    # Buffer exactly ONE batch (acks=all: one producer batch per flush).
    win.buffer[NoopSink](_make_int64_batch(Int64(0), 1), Int64(0), reactor)
    assert_equal(win.pending_count(), 1, "exactly one buffered (singleton)")
    win.reconfigure_at_least_once()
    var fop = win.force[NoopSink](Int64(50), reactor)
    _ = fop
    _drive_to_done(win, reactor)
    assert_false(win.is_inflight(), "the singleton flush completed")
    assert_false(win.has_error(), "no error: " + win.err_text())

    var outcomes = win.take_outcomes()
    assert_equal(len(outcomes), 1, "the singleton committed")
    assert_equal(
        Int(outcomes[0][1].intra_batch_seq), 0, "singleton intra-batch seq 0"
    )
    assert_equal(outcomes[0][1].base_offset, Int64(0), "singleton base offset 0")
    assert_equal(outcomes[0][1].last_offset, Int64(0), "singleton last offset 0")
    assert_equal(
        Int(_meta_chunks(slow, String("cl"), String("topic-single"), Int64(0))),
        1,
        "exactly one chunk for the singleton",
    )
    print("  test_acks_all_singleton_fast_path: PASS")


# =============================================================================
# (2) the EOS singleton invariant GUARD — an EOS append with no producer
#     identity RAISES (the N==1 contract; defense-in-depth).
# =============================================================================
def test_eos_singleton_invariant_guard_raises_without_producer() raises:
    """The singleton invariant guard: an IDEMPOTENT-SINGLETON appender
    with NO producer identity (producer_id < 0 / first_seq < 0) MUST raise (the
    EOS sentinel keys exactly one (producer_id, first_seq) per append). Drives the
    appender directly with an invalid producer identity + asserts the raise.

    FALSIFIES a missing guard: were the guard absent, the EOS append would call
    append_idempotent with producer_id=-1 — a malformed dedup key — silently
    corrupting the exactly-once contract."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)
    var prefix = _partition_prefix(String("cl"), String("topic-guard"), Int64(0))
    var wal = _SlowMeta(slow.clone(), prefix^)
    # An IDEMPOTENT-SINGLETON appender with NO producer identity (the default -1).
    # NOTE: the appender's EOS cell is a fresh ArcPointer; we reach the guard via
    # the public append_start. The body / record_count are immaterial — the guard
    # fires BEFORE the append_idempotent call.
    from std.memory import ArcPointer
    from komira_broker.broker_coalescing_produce import _EosResultCell

    var cell = ArcPointer[_EosResultCell](_EosResultCell())
    var appender = BrokerBatchAppender[_Slow](
        wal^,
        BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
        cell,
        Int64(-1),  # producer_id = -1 (NO identity) -> the guard must fire.
        Int64(0),
        Int64(-1),  # first_seq = -1 (NO identity).
        Int64(-1),
        Int64(0),
        Int64(0),
        Int64(0),
    )
    var raised = False
    try:
        var body = List[UInt8]()
        body.append(UInt8(1))
        _ = appender.append_start[NoopSink](body^, Int64(1), Int64(1), Int64(0), Int64(0), reactor)
    except e:
        if String(e).find("singleton invariant") >= 0 or String(e).find("producer identity") >= 0:
            raised = True
    assert_true(
        raised,
        "the EOS singleton invariant guard raised on a missing producer identity",
    )
    print("  test_eos_singleton_invariant_guard_raises_without_producer: PASS")


# =============================================================================
# DISCRIMINATING — two flushes sharing flush_ts mint DISTINCT keys
#             + each manifest chunk references its OWN segment bytes (no silent
#             cross-flush data loss).
# =============================================================================
def test_two_flushes_same_flush_ts_distinct_keys_no_data_loss() raises:
    """Silent data-loss guard: two AT-LEAST-ONCE flushes on ONE driver that
    share a flush_ts (both items enqueued at ts_ms=0) + the same proc_nonce MUST
    mint DISTINCT segment keys, and each committed manifest chunk MUST reference
    its OWN segment bytes.

    The hazard: if the codec's _seg_counter reset to 0 per flush, flush 1 +
    flush 2 would mint the IDENTICAL key `<0>-<broker>-<nonce>-1`. Flush 2's
    content-create PUT would 412 on flush 1's object, and if that 412 were
    treated as a WIN, chunk 1's manifest body would reference flush 1's bytes.
    get_object(chunk1.key) would then return flush 1's segment (record_count 3),
    NOT flush 2's (record_count 5): flush 2's 5 records val 100..104 would be
    SILENTLY LOST. This test asserts chunk0.key != chunk1.key AND
    get_object(chunk1.key) is flush 2's OWN segment (record_count 5, its OWN
    crc).

    Distinct content per flush (different record_count + CRC) is what makes the
    test discriminating: flush 1 = 3 records val 0..2; flush 2 = 5 records val
    100..104."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=0)  # instant -> both flushes converge in-burst.
    var cluster = String("cl")
    var topic = String("topic-blkr1")
    var win = _make_driver(slow.clone(), cluster, topic, Int64(0))

    # ---- Flush 1: 3 records (val 0,1,2), enqueued at ts_ms=0 -> flush_ts=0. ----
    win.buffer[NoopSink](_make_int64_batch(Int64(0), 3), Int64(0), reactor)
    assert_equal(win.pending_count(), 1, "flush1: one batch buffered")
    win.reconfigure_at_least_once()
    var fop1 = win.force[NoopSink](Int64(0), reactor)
    _ = fop1
    _drive_to_done(win, reactor)
    assert_false(win.is_inflight(), "flush1 completed")
    assert_false(win.has_error(), "flush1 no error: " + win.err_text())
    var oc1 = win.take_outcomes()
    assert_equal(len(oc1), 1, "flush1 committed one outcome")

    # ---- Flush 2: 5 records (val 100..104), ALSO enqueued at ts_ms=0 ->
    #      flush_ts=0 (SAME flush_ts + SAME proc_nonce as flush 1). ----
    win.buffer[NoopSink](_make_int64_batch(Int64(100), 5), Int64(0), reactor)
    assert_equal(win.pending_count(), 1, "flush2: one batch buffered")
    win.reconfigure_at_least_once()
    var fop2 = win.force[NoopSink](Int64(0), reactor)
    _ = fop2
    _drive_to_done(win, reactor)
    assert_false(win.is_inflight(), "flush2 completed")
    assert_false(win.has_error(), "flush2 no error: " + win.err_text())
    var oc2 = win.take_outcomes()
    assert_equal(len(oc2), 1, "flush2 committed one outcome")

    # ---- TWO chunks committed (the silent-loss bug would still commit two
    #      chunks; the loss is in WHICH segment each chunk references). ----
    var meta = _shared_meta(slow, cluster, topic, Int64(0))
    assert_equal(Int(meta.num_chunks()), 2, "two committed manifest chunks")

    # Decode each chunk's manifest body -> its segment key + record_count.
    var body0 = ManifestBody.decode(meta.read_chunk(Int64(0)))
    var body1 = ManifestBody.decode(meta.read_chunk(Int64(1)))
    var key0 = body0.object_key
    var key1 = body1.object_key
    assert_equal(body0.record_count, Int64(3), "chunk0 body record_count 3")
    assert_equal(body1.record_count, Int64(5), "chunk1 body record_count 5")

    # THE BLOCKER ASSERTION (1): the two flushes minted DISTINCT keys.
    assert_true(
        key0 != key1,
        "two flushes sharing flush_ts mint DISTINCT segment keys: key0="
        + key0
        + " key1="
        + key1,
    )

    # THE BLOCKER ASSERTION (2): each segment object IS the flush's OWN bytes.
    var foot0 = SegmentFooter.decode(meta.get_object(key0))
    var foot1 = SegmentFooter.decode(meta.get_object(key1))
    assert_equal(
        foot0.record_count,
        Int64(3),
        "get_object(key0) is flush1's OWN segment (record_count 3)",
    )
    assert_equal(
        foot1.record_count,
        Int64(5),
        "get_object(key1) is flush2's OWN segment (record_count 5) — a key"
        " collision would return flush1's segment (record_count 3): flush2's"
        " records LOST",
    )
    # The footer CRCs differ (distinct content) — the chunk1 segment is NOT a copy
    # of chunk0's (a key collision would make key1 == key0 -> identical CRC).
    assert_true(
        foot0.crc32 != foot1.crc32,
        "the two segments carry DISTINCT CRCs (distinct content) — a key1"
        " aliasing key0 would make the CRCs identical",
    )
    print(
        "  test_two_flushes_same_flush_ts_distinct_keys_no_data_loss: PASS"
    )


# =============================================================================
# Slow-store EOS flush — parks on the stage-blob, the EOS append
#            completes in a burst, the flush commits without wedging.
# =============================================================================
def test_eos_slow_store_completes_without_wedge() raises:
    """An EOS (IDEMPOTENT-SINGLETON) flush on a SLOW-CAS store PARKS on the
    parkable stage-blob PUT (slow_ticks reactor ticks), then its EOS
    append_idempotent completes in ONE synchronous burst at append_start (READY
    immediately). The EOS commit
    is NOT poll-shaped (CasManifestStore.append_idempotent runs the store's own
    reactor to completion), the at-least-once ESCALATING path is the parkable hot
    path. This asserts the EOS flush nonetheless drains to DONE through the demux
    (it does NOT wedge the parkable window) and stamps the COMMITTED discriminant.

    WORST-CASE RTTs for an EOS flush on a real store: the parkable stage-blob PUT
    (1 RTT, parked across the reactor) + the BLOCKING append_idempotent (the
    sentinel claim + the chunk append — up to 2 RTTs run inline, NOT parked). So
    the EOS flush blocks the serve thread for the append_idempotent duration; the
    parkability win applies only to the stage-blob leg; the EOS append is not
    poll-shaped. The dominant at-least-once produce path is
    fully parkable (it is covered by test_parkable_produce_other_partition_*)."""
    var reactor = _new_reactor()
    var slow = _Slow(slow_ticks=3)  # the stage-blob PUT parks 3 reactor ticks.
    var cluster = String("cl")
    var topic = String("topic-eos-slow")
    var win = _make_driver(slow.clone(), cluster, topic, Int64(0))

    var producer_id = Int64(11)
    var first_seq = Int64(0)
    var last_seq = Int64(2)

    win.buffer[NoopSink](_make_int64_batch(Int64(0), 3), Int64(0), reactor)
    win.reconfigure_eos_singleton(
        producer_id, Int64(0), first_seq, last_seq, Int64(0)
    )
    var fop = win.force[NoopSink](Int64(100), reactor)
    # The flush PARKS on the slow stage-blob PUT (does not converge in the start
    # burst) — the parkable leg of the EOS flush.
    assert_true(win.is_inflight(), "EOS flush parked on the slow stage-blob PUT")
    assert_true(fop != Int64(0), "EOS flush parked on a biased op_id")

    # Drain through the demux — it MUST reach DONE (no wedge) within the bound.
    _drive_to_done(win, reactor, guard_max=64)
    assert_false(win.is_inflight(), "EOS flush drained to DONE (no wedge)")
    assert_false(win.has_error(), "EOS slow flush no error: " + win.err_text())

    var oc = win.take_outcomes()
    assert_equal(len(oc), 1, "EOS slow flush committed one outcome")
    assert_true(win.last_eos_engaged(), "EOS cell stamped after the slow flush")
    assert_equal(
        Int(win.last_eos_kind()),
        Int(BPO_EOS_COMMITTED),
        "EOS slow flush is COMMITTED",
    )
    assert_equal(win.last_eos_base_offset(), Int64(0), "EOS slow base offset 0")
    assert_equal(win.last_eos_last_offset(), Int64(2), "EOS slow last offset 2")
    assert_equal(
        Int(_meta_chunks(slow, cluster, topic, Int64(0))),
        1,
        "one chunk committed by the slow EOS flush",
    )
    print("  test_eos_slow_store_completes_without_wedge: PASS")


# =============================================================================
# Slot contention — two drivers contend the SAME partition slot; the
#         loser's append 412s -> the LIVE re-encode loop re-mints a fresh key +
#         re-appends at the new slot -> converges. Guards the per-flush key
#         range's re-mint x re-encode interaction.
# =============================================================================
def test_slot_contention_rekey_reencode_converges() raises:
    """Two BrokerCoalescingProduce drivers on the SAME partition (same manifest
    prefix, sharing the inner Arc-backed store) contend the SAME create-CAS slot.
    Driver A commits first; driver B's exact-slot append 412s (LOST_SLOT) -> the
    spine's LIVE 412-loop re-reads the authoritative head + re-encodes the SAME
    retained items (which RE-MINTS a fresh segment key from B's OWN disjoint stride
    range — the re-mint x re-encode interaction) + re-appends at the new
    auth_head+1. Both commits converge: TWO chunks, distinct offset ranges, each
    referencing its OWN segment.

    This guards the disjoint key range's interaction with the escalating 412-loop: a
    re-encode after a lost slot must mint a NON-colliding key (it draws the next
    counter in B's reserved range), so B's re-appended chunk references B's OWN
    re-staged bytes, never A's."""
    var reactor = _new_reactor()
    # Both drivers share ONE inner store (same partition) so their create-CAS at
    # slot 0 genuinely contends. Driver A instant; driver B instant too (we order
    # them by driving A to DONE first, then B — B then loses slot 0 to A).
    var base = _Slow(slow_ticks=0)
    var cluster = String("cl")
    var topic = String("topic-contend")
    var win_a = BrokerCoalescingProduce[_Slow](
        base.clone(), cluster, topic, Int64(0), String("broker-A")
    )
    var win_b = BrokerCoalescingProduce[_Slow](
        base.clone(), cluster, topic, Int64(0), String("broker-B")
    )

    # Driver A: buffer 2 records, flush, commit (wins slot 0).
    win_a.buffer[NoopSink](_make_int64_batch(Int64(0), 2), Int64(0), reactor)
    win_a.reconfigure_at_least_once()
    var fa = win_a.force[NoopSink](Int64(10), reactor)
    _ = fa
    _drive_to_done(win_a, reactor)
    assert_false(win_a.is_inflight(), "driver A committed")
    assert_false(win_a.has_error(), "driver A no error: " + win_a.err_text())
    var oca = win_a.take_outcomes()
    assert_equal(len(oca), 1, "driver A one outcome")
    assert_equal(oca[0][1].base_offset, Int64(0), "driver A base offset 0")

    # Driver B: buffer 3 records, flush -> its exact-slot append at slot 0 412s
    # (A already won it) -> the LIVE 412-loop re-reads head (now chunk_seq 0) +
    # re-encodes (RE-MINTS a fresh key) + re-appends at slot 1 -> converges.
    win_b.buffer[NoopSink](_make_int64_batch(Int64(100), 3), Int64(0), reactor)
    win_b.reconfigure_at_least_once()
    var fb = win_b.force[NoopSink](Int64(20), reactor)
    _ = fb
    _drive_to_done(win_b, reactor)
    assert_false(win_b.is_inflight(), "driver B converged after losing slot 0")
    assert_false(win_b.has_error(), "driver B no error: " + win_b.err_text())
    var ocb = win_b.take_outcomes()
    assert_equal(len(ocb), 1, "driver B one outcome")
    # B's offsets follow A's (A committed [0,1]; B re-appended at [2,3,4]).
    assert_equal(ocb[0][1].base_offset, Int64(2), "driver B base offset 2 (after A)")
    assert_equal(ocb[0][1].last_offset, Int64(4), "driver B last offset 4")

    # TWO chunks; B's chunk references B's OWN re-staged segment (record_count 3),
    # NOT A's (record_count 2) — the re-mint x re-encode is correct.
    var meta = _shared_meta(base, cluster, topic, Int64(0))
    assert_equal(Int(meta.num_chunks()), 2, "two chunks (A + B converged)")
    var body_a = ManifestBody.decode(meta.read_chunk(Int64(0)))
    var body_b = ManifestBody.decode(meta.read_chunk(Int64(1)))
    assert_true(
        body_a.object_key != body_b.object_key,
        "A's and B's chunks reference DISTINCT segment keys",
    )
    var foot_b = SegmentFooter.decode(meta.get_object(body_b.object_key))
    assert_equal(
        foot_b.record_count,
        Int64(3),
        "B's chunk references B's OWN re-staged segment (record_count 3)",
    )
    print("  test_slot_contention_rekey_reencode_converges: PASS")


def main() raises:
    print(
        "test_broker_coalescing_produce — the BROKER produce-on-CoalescingWindow"
        " GATE (parkable)"
    )
    # DISCRIMINATING — two flushes sharing flush_ts (silent data-loss)
    test_two_flushes_same_flush_ts_distinct_keys_no_data_loss()
    # Slow-store EOS flush completes without wedging
    test_eos_slow_store_completes_without_wedge()
    # Slot contention -> re-mint x re-encode converges
    test_slot_contention_rekey_reencode_converges()
    # (1) at-least-once coalescing (behavior-preserving)
    test_at_least_once_coalesces_n_batches_one_chunk()
    # (a) MANDATORY — IDEMPOTENT-mode conformer (the singleton-mode gate)
    test_eos_singleton_flush_and_dedup()
    # (b) MANDATORY — parkable produce (the burst-stall fix)
    test_parkable_produce_other_partition_progresses()
    # (c) MANDATORY — acks=all singleton fast-path
    test_acks_all_singleton_fast_path()
    # (2) the EOS singleton invariant guard
    test_eos_singleton_invariant_guard_raises_without_producer()
    print("ALL test_broker_coalescing_produce tests PASS")
