# =============================================================================
# tests/test_broker_reap_below_log_start_offline.mojo
#   The reaper never deletes a live chunk — OFFLINE
# =============================================================================
#
# A tombstone at or above `_LOG_START.log_start_seq` sits on a LIVE chunk:
# every reader and replay starts at the log start. RetentionPass tombstones
# before it advances, so a failed advance (or a crash between the two) leaves
# such tombstones behind; before this fix the ReapWorker deleted their `.seg`
# data and chunk keys once grace elapsed.
#
#   (1) RetentionPass's advance fails after its tombstones. Past grace, the
#       ReapWorker deletes nothing (`.seg` and chunk key survive) and counts
#       the tombstones in `skipped_live_count`. A later pass re-tombstones and
#       re-advances (it is not fooled into "nothing to do"), and the next reap
#       reclaims everything. Catches: no skip; `>` instead of `>=` (the chunk
#       AT the log start); a pass that never re-advances.
#   (2) An unreadable `_LOG_START` makes the ReapWorker raise before any
#       delete. Catches: a read error treated as "no floor" (fail open).
#   (3) Split-parent compaction advances the parent's log start past its top
#       chunk BEFORE it tombstones, so the reaper reclaims the parent; when the
#       advance fails, nothing is tombstoned and nothing is deleted. Catches:
#       the old tombstone-only order (the reaper would skip the parent forever).
#   (4) `compact_split_parent_gen` whose step-5 advance fails after the
#       collapse CAS landed: a re-run finds the lineage collapsed, finishes
#       step 5 and the parent is reclaimed (before, the re-run raised "is not a
#       retired partition" and nothing revisited the parent). A pid that was
#       never split is still refused. A parent whose prefix retention already
#       reaped is retired without raising on the missing chunks.
#   (5) `advance_log_start_monotone` retries a lost CAS and gives up after
#       its bounded attempts.
#   (6) A read error on a LIVE chunk in the segment fold's and the
#       migration's retire walks is raised before any tombstone or advance.
#       Catches: the old catch-all `except: continue  # already-reaped`. A
#       live chunk that READS AS ABSENT (not_found) is raised too. Catches: a
#       walk that skips only not_found. After a failed (swallowed) advance,
#       both walks' re-runs re-advance and count no new tombstone (they
#       re-stamp the stranded ones; test_broker_moved_payload_reap_offline).
#
# Faults come from `_FaultStore`, which wraps the shared in-memory store and
# keeps its rules as marker objects IN that store, so every clone sees them.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.manifest_body import ManifestBody
from komira_broker.partition_compaction import (
    _schedule_parent_chunks_for_delete,
    compact_split_parent_gen,
)
from komira_broker.partition_map import (
    PartitionMap,
    persist_create_if_absent,
    prefix_gen_manifest_prefix,
)
from komira_broker.partition_split import split_topic
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.sublineage_migration import SubLineageMigration
from komira_broker.sublineage_segment_fold import SegmentBaseFold
from komira_broker.retention import (
    ReapResult,
    advance_log_start_monotone,
    ReapWorker,
    RetentionPass,
    RetentionPolicy,
)

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
    log_start_key,
    tombstone_key,
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


comptime _Inner = SharedInMemoryConditionalStore
comptime _FAIL_GET = "__fault__/get/"
comptime _FAIL_PUT = "__fault__/put/"
# The first GET of the target succeeds and arms `_FAIL_GET` for the rest:
# a tail recovery reads the chunk, the walk after it then fails.
comptime _FAIL_GET_AFTER_ONE = "__fault__/get_after_one/"
# The same, but the failing GET reads as ABSENCE (`not_found`) while the
# chunk is still there: the shape the old "already-reaped" skip trusted.
comptime _ABSENT_GET = "__fault__/absent_get/"
comptime _ABSENT_GET_AFTER_ONE = "__fault__/absent_get_after_one/"
# A conditional PUT to the target loses its precondition: every time, or once.
comptime _LOSE_CAS = "__fault__/412/"
comptime _LOSE_CAS_ONCE = "__fault__/412once/"
comptime _GRACE = Int64(60_000)


def _has(store: _Inner, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


def _arm(store: _Inner, rule: String, target: String) raises:
    _ = store.put(Path.parse(rule + target), List[UInt8]())


def _disarm(store: _Inner, rule: String, target: String) raises:
    store.delete(Path.parse(rule + target))


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates every verb to a shared in-memory store, failing a GET or a
    PUT a rule names. The injected error carries no absence or precondition
    token."""

    var _inner: _Inner

    def __init__(out self, var inner: _Inner):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def _fail_if(self, rule: String, path: Path) raises:
        if _has(self._inner, rule + path.raw()):
            raise Error("injected fault: transport error status=503 " + rule)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def _before_get(self, path: Path) raises:
        self._fail_if(_FAIL_GET, path)
        if _has(self._inner, _ABSENT_GET + path.raw()):
            raise Error("injected: not_found (404), the chunk reads as absent")
        if _has(self._inner, _FAIL_GET_AFTER_ONE + path.raw()):
            _disarm(self._inner, _FAIL_GET_AFTER_ONE, path.raw())
            _arm(self._inner, _FAIL_GET, path.raw())
        if _has(self._inner, _ABSENT_GET_AFTER_ONE + path.raw()):
            _disarm(self._inner, _ABSENT_GET_AFTER_ONE, path.raw())
            _arm(self._inner, _ABSENT_GET, path.raw())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._before_get(path)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._before_get(path)
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._fail_if(_FAIL_PUT, path)
        var lose = _has(self._inner, _LOSE_CAS + path.raw())
        if _has(self._inner, _LOSE_CAS_ONCE + path.raw()):
            _disarm(self._inner, _LOSE_CAS_ONCE, path.raw())
            lose = True
        if lose:
            raise Error("injected: precondition (412) — a concurrent writer won")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._fail_if(_FAIL_PUT, path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._fail_if(_FAIL_PUT, path)
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


comptime _CLUSTER = "reapls"
comptime _TOPIC = "t"


def _prefix(pid: Int64) -> String:
    return String(_CLUSTER) + "/_meta/topics/" + String(_TOPIC) + "/" + String(pid)


def _manifest(inner: _Inner, pid: Int64) raises -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=_FaultStore(inner.clone()),
        prefix=_prefix(pid),
        retry=RetryPolicy.fast_test(),
    )


def _batch(base_val: Int64, n: Int) raises -> RecordBatch:
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


def _produce_chunks(inner: _Inner, pid: Int64, n_chunks: Int) raises:
    """`n_chunks` chunks of 10 records, created at ts 1000, 2000, ..."""
    _produce_at(inner, _prefix(pid), pid, n_chunks)


def _produce_at(
    inner: _Inner, prefix: String, pid: Int64, n_chunks: Int
) raises:
    """`_produce_chunks` into the manifest at `prefix`."""
    var broker = BrokerCore[_FaultStore](
        segment_store=_FaultStore(inner.clone()),
        manifest=CasManifestStore[_FaultStore](
            store=_FaultStore(inner.clone()),
            prefix=prefix,
            retry=RetryPolicy.fast_test(),
        ),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=pid,
        broker_id=String("broker-A"),
    )
    for i in range(n_chunks):
        var ts = Int64(1000) + Int64(i) * Int64(1000)
        _ = broker.produce(_batch(Int64(i * 10), 10), ts)
        _ = broker.flush_if_buffered(ts)
    _ = broker^


def _seg_keys(inner: _Inner, pid: Int64, n: Int) raises -> List[String]:
    var m = _manifest(inner, pid)
    var out = List[String]()
    for s in range(n):
        out.append(String(ManifestBody.decode(m.read_chunk(Int64(s))).object_key))
    _ = m^
    return out^


def _reap(
    inner: _Inner, pid: Int64, now_ms: Int64
) raises -> ReapResult:
    var seg_store = _FaultStore(inner.clone())
    var m = _manifest(inner, pid)
    var w = ReapWorker[_FaultStore](_GRACE)
    var r = w.run(seg_store, m, now_ms)
    _ = m^
    return r^


def _assert_live(
    inner: _Inner, pid: Int64, segs: List[String], upto: Int, what: String
) raises:
    for s in range(upto):
        assert_true(_has(inner, segs[s]), what + ": .seg " + String(s) + " kept")
        assert_true(
            _has(inner, chunk_key(_prefix(pid), Int64(s)).raw()),
            what + ": chunk key " + String(s) + " kept",
        )


def _assert_reclaimed(
    inner: _Inner, pid: Int64, segs: List[String], upto: Int, what: String
) raises:
    for s in range(upto):
        assert_false(
            _has(inner, segs[s]), what + ": .seg " + String(s) + " deleted"
        )
        assert_false(
            _has(inner, chunk_key(_prefix(pid), Int64(s)).raw()),
            what + ": chunk key " + String(s) + " deleted",
        )


# =============================================================================
# (1) a failed RetentionPass advance strands tombstones; the reaper skips them
# =============================================================================


def test_failed_advance_tombstones_are_skipped_then_reclaimed() raises:
    print("[test_failed_advance_tombstones_are_skipped_then_reclaimed] starting...")
    var inner = _Inner()
    var pid = Int64(0)
    _produce_chunks(inner, pid, 4)  # chunks 0..3; 3 is the active chunk
    var segs = _seg_keys(inner, pid, 4)
    var lk = log_start_key(_prefix(pid)).raw()

    # Chunks 0..2 are out of policy (ages 9000, 8000, 7000 > 6000). The pass
    # tombstones them, then its advance fails.
    _arm(inner, _FAIL_PUT, lk)
    var policy = RetentionPolicy.time_based(Int64(6000))
    var m = _manifest(inner, pid)
    var rp = RetentionPass[_FaultStore](policy)
    var raised = False
    try:
        _ = rp.run(m, Int64(10_000))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the advance failed")
    var tombs = m.tombstone_seqs()
    assert_equal(len(tombs), 3, "3 tombstones stranded on live chunks")
    assert_equal(m.read_log_start_seq(), Int64(0), "log start did not move")

    # Grace elapses: the reaper deletes NOTHING and counts the live tombstones.
    var r1 = _reap(inner, pid, Int64(10_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(0), "nothing reaped")
    assert_equal(r1.skipped_live_count, Int64(3), "3 live tombstones skipped")
    assert_equal(r1.log_start_seq, Int64(0), "the floor read")
    _assert_live(inner, pid, segs, 4, "after the skip")

    # A later pass re-tombstones the same chunks and advances.
    _disarm(inner, _FAIL_PUT, lk)
    var res = rp.run(m, Int64(20_000))
    assert_true(res.advanced_log_start, "the later pass advances")
    assert_equal(res.tombstoned_count, Int64(3), "it re-tombstones all 3")
    assert_equal(res.new_log_start_seq, Int64(3), "log start at chunk 3")
    assert_equal(m.read_log_start_seq(), Int64(3), "persisted")

    # Its tombstones carry the new pass's time: still within grace at the old
    # deadline, reclaimed after the new one.
    var r2 = _reap(inner, pid, Int64(10_000) + _GRACE)
    assert_equal(r2.reaped_count, Int64(0), "re-tombstoned: grace restarts")
    assert_equal(r2.skipped_live_count, Int64(0), "none is live any more")
    var r3 = _reap(inner, pid, Int64(20_000) + _GRACE)
    assert_equal(r3.reaped_count, Int64(3), "all 3 reclaimed")
    assert_equal(r3.skipped_live_count, Int64(0), "none skipped")
    assert_equal(r3.log_start_seq, Int64(3), "the floor read")
    _assert_reclaimed(inner, pid, segs, 3, "after the advance")
    assert_true(_has(inner, segs[3]), "the active chunk's .seg kept")
    _ = m^
    _ = rp^
    print("[test_failed_advance_tombstones_are_skipped_then_reclaimed] PASS")


# =============================================================================
# (2) an unreadable _LOG_START: the reaper raises before any delete
# =============================================================================


def test_unreadable_log_start_reaps_nothing() raises:
    print("[test_unreadable_log_start_reaps_nothing] starting...")
    var inner = _Inner()
    var pid = Int64(1)
    _produce_chunks(inner, pid, 3)
    var segs = _seg_keys(inner, pid, 3)
    var m = _manifest(inner, pid)
    var rp = RetentionPass[_FaultStore](RetentionPolicy.time_based(Int64(6000)))
    var res = rp.run(m, Int64(10_000))
    assert_equal(res.new_log_start_seq, Int64(2), "chunks 0, 1 retired")

    var lk = log_start_key(_prefix(pid)).raw()
    _arm(inner, _FAIL_GET, lk)
    var raised = False
    try:
        _ = _reap(inner, pid, Int64(10_000) + _GRACE)
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the reaper reports the unreadable log start")
    _assert_live(inner, pid, segs, 3, "fail closed")

    _disarm(inner, _FAIL_GET, lk)
    var r = _reap(inner, pid, Int64(10_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(2), "readable again: both reaped")
    _assert_reclaimed(inner, pid, segs, 2, "after the read recovers")
    _ = m^
    _ = rp^
    print("[test_unreadable_log_start_reaps_nothing] PASS")


# =============================================================================
# (3) split-parent compaction advances the parent's log start first
# =============================================================================


def test_parent_compaction_advances_then_reaper_reclaims() raises:
    print("[test_parent_compaction_advances_then_reaper_reclaims] starting...")
    var inner = _Inner()
    var pid = Int64(2)
    _produce_chunks(inner, pid, 4)
    var segs = _seg_keys(inner, pid, 4)
    var maint = _manifest(inner, pid)
    var now_ms = Int64(50_000)
    _schedule_parent_chunks_for_delete[_FaultStore](maint, now_ms)

    var ls = maint.read_log_start()
    assert_equal(ls.log_start_seq, Int64(4), "parent log start past top (3)")
    assert_equal(ls.log_start_offset, Int64(40), "at the parent's next offset")
    assert_equal(len(maint.tombstone_seqs()), 4, "all 4 parent chunks marked")

    # Within grace nothing goes; after it, the whole parent is reclaimed.
    var r0 = _reap(inner, pid, now_ms + _GRACE - Int64(1))
    assert_equal(r0.reaped_count, Int64(0), "within grace")
    _assert_live(inner, pid, segs, 4, "within grace")
    var r = _reap(inner, pid, now_ms + _GRACE)
    assert_equal(r.reaped_count, Int64(4), "the parent is reclaimed")
    assert_equal(r.skipped_live_count, Int64(0), "no parent chunk is live")
    _assert_reclaimed(inner, pid, segs, 4, "parent")
    _ = maint^
    print("[test_parent_compaction_advances_then_reaper_reclaims] PASS")


def test_parent_compaction_failed_advance_marks_nothing() raises:
    print("[test_parent_compaction_failed_advance_marks_nothing] starting...")
    var inner = _Inner()
    var pid = Int64(3)
    _produce_chunks(inner, pid, 3)
    var segs = _seg_keys(inner, pid, 3)
    var lk = log_start_key(_prefix(pid)).raw()
    _arm(inner, _FAIL_PUT, lk)
    var maint = _manifest(inner, pid)
    var raised = False
    try:
        _schedule_parent_chunks_for_delete[_FaultStore](maint, Int64(50_000))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the failed advance raises")
    assert_equal(len(maint.tombstone_seqs()), 0, "no tombstone before the advance")
    var r = _reap(inner, pid, Int64(50_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(0), "nothing reaped")
    _assert_live(inner, pid, segs, 3, "failed parent advance")
    _disarm(inner, _FAIL_PUT, lk)
    _ = maint^
    print("[test_parent_compaction_failed_advance_marks_nothing] PASS")


def test_parent_compaction_empty_parent_is_a_noop() raises:
    print("[test_parent_compaction_empty_parent_is_a_noop] starting...")
    var inner = _Inner()
    var maint = _manifest(inner, Int64(4))
    _schedule_parent_chunks_for_delete[_FaultStore](maint, Int64(50_000))
    assert_false(
        _has(inner, log_start_key(_prefix(Int64(4))).raw()),
        "an empty parent writes no log start",
    )
    assert_equal(len(maint.tombstone_seqs()), 0, "and no tombstone")
    _ = maint^
    print("[test_parent_compaction_empty_parent_is_a_noop] PASS")


# =============================================================================
# (4) split-parent compaction resumes after a failed step-5 advance
# =============================================================================


def _core(
    inner: _Inner, prefix: String, pid: Int
) raises -> BrokerCore[_FaultStore]:
    return BrokerCore[_FaultStore](
        segment_store=_FaultStore(inner.clone()),
        manifest=CasManifestStore[_FaultStore](
            store=_FaultStore(inner.clone()),
            prefix=prefix,
            retry=RetryPolicy.fast_test(),
        ),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(pid),
        broker_id=String("broker-A"),
    )


def _compact_gen(
    inner: _Inner, a: Int, b: Int, var batches: Slab[RecordBatch]
) raises -> Bool:
    """One `compact_split_parent_gen` run of parent pid 0; its `collapsed`."""
    var c = String(_CLUSTER)
    var t = String(_TOPIC)
    var res = compact_split_parent_gen[_FaultStore](
        _FaultStore(inner.clone()),
        c,
        t,
        batches^,
        _core(inner, prefix_gen_manifest_prefix(c, t, a, Int64(0)), a),
        _core(inner, prefix_gen_manifest_prefix(c, t, b, Int64(0)), b),
        _manifest(inner, Int64(0)),
        0,
        Int64(50_000),
    )
    return res.collapsed


def test_parent_compaction_resumes_after_failed_advance() raises:
    print("[test_parent_compaction_resumes_after_failed_advance] starting...")
    var inner = _Inner()
    persist_create_if_absent[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        PartitionMap.auto_seed(),
    )
    _produce_chunks(inner, Int64(0), 3)
    var segs = _seg_keys(inner, Int64(0), 3)
    var split = split_topic[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        _manifest(inner, Int64(0)),
        0,
    )
    var a = split.child_a_pid
    var b = split.child_b_pid

    # The collapse CAS lands; the parent's advance (step 5) then fails.
    var lk = log_start_key(_prefix(Int64(0))).raw()
    _arm(inner, _FAIL_PUT, lk)
    var batches = Slab[RecordBatch]()
    batches.append(_batch(Int64(0), 30))
    var raised = False
    try:
        _ = _compact_gen(inner, a, b, batches^)
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "step 5 failed after the collapse")
    var m = _manifest(inner, Int64(0))
    assert_equal(len(m.tombstone_seqs()), 0, "no parent tombstone yet")
    _disarm(inner, _FAIL_PUT, lk)

    # The re-run finds the lineage collapsed and finishes step 5.
    var collapsed = _compact_gen(inner, a, b, Slab[RecordBatch]())
    assert_true(collapsed, "the re-run reports the collapse")
    var ls = m.read_log_start()
    assert_equal(ls.log_start_seq, Int64(3), "parent log start past top (2)")
    assert_equal(ls.log_start_offset, Int64(30), "at the parent's next offset")
    assert_equal(len(m.tombstone_seqs()), 3, "all 3 parent chunks marked")
    var r = _reap(inner, Int64(0), Int64(50_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(3), "the parent is reclaimed")
    _assert_reclaimed(inner, Int64(0), segs, 3, "resumed parent")

    # A third run is a no-op that still reports the collapse.
    assert_true(
        _compact_gen(inner, a, b, Slab[RecordBatch]()), "idempotent re-run"
    )
    _ = m^
    print("[test_parent_compaction_resumes_after_failed_advance] PASS")


def test_parent_compaction_failed_tombstone_then_resume() raises:
    """Step 5's advance lands, then the tombstone write for chunk 1 fails:
    the error is raised (not taken for an already-reaped chunk), and a re-run
    through the resume path marks the rest and the parent is reclaimed."""
    print("[test_parent_compaction_failed_tombstone_then_resume] starting...")
    var inner = _Inner()
    persist_create_if_absent[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        PartitionMap.auto_seed(),
    )
    _produce_chunks(inner, Int64(0), 3)
    var segs = _seg_keys(inner, Int64(0), 3)
    var split = split_topic[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        _manifest(inner, Int64(0)),
        0,
    )
    var a = split.child_a_pid
    var b = split.child_b_pid

    var tk = tombstone_key(_prefix(Int64(0)), Int64(1)).raw()
    _arm(inner, _FAIL_PUT, tk)
    var batches = Slab[RecordBatch]()
    batches.append(_batch(Int64(0), 30))
    var raised = False
    try:
        _ = _compact_gen(inner, a, b, batches^)
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the failed tombstone write is raised")
    var m = _manifest(inner, Int64(0))
    assert_equal(m.read_log_start_seq(), Int64(3), "the advance had landed")
    assert_equal(len(m.tombstone_seqs()), 1, "only chunk 0 was marked")
    _disarm(inner, _FAIL_PUT, tk)

    assert_true(
        _compact_gen(inner, a, b, Slab[RecordBatch]()), "the re-run resumes"
    )
    assert_equal(len(m.tombstone_seqs()), 3, "all 3 parent chunks marked")
    var r = _reap(inner, Int64(0), Int64(50_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(3), "the parent is reclaimed")
    _assert_reclaimed(inner, Int64(0), segs, 3, "resumed after a failed mark")
    _ = m^
    print("[test_parent_compaction_failed_tombstone_then_resume] PASS")


def test_parent_compaction_of_a_never_split_pid_raises() raises:
    print("[test_parent_compaction_of_a_never_split_pid_raises] starting...")
    var inner = _Inner()
    persist_create_if_absent[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        PartitionMap.auto_seed(),
    )
    var raised = False
    try:
        _ = _compact_gen(inner, 1, 2, Slab[RecordBatch]())
    except e:
        raised = True
        assert_true(String(e).find("is not a retired partition") >= 0, String(e))
    assert_true(raised, "a live, never-split pid is refused")
    print("[test_parent_compaction_of_a_never_split_pid_raises] PASS")


def test_parent_with_a_reaped_prefix_is_retired() raises:
    """Retention already reaped the parent's chunks 0 and 1: tombstoning
    from seq 0 skips the missing chunks instead of raising."""
    print("[test_parent_with_a_reaped_prefix_is_retired] starting...")
    var inner = _Inner()
    var pid = Int64(5)
    _produce_chunks(inner, pid, 4)
    var segs = _seg_keys(inner, pid, 4)
    var m = _manifest(inner, pid)
    var rp = RetentionPass[_FaultStore](RetentionPolicy.time_based(Int64(7500)))
    var res = rp.run(m, Int64(10_000))
    assert_equal(res.new_log_start_seq, Int64(2), "retention retired 0, 1")
    assert_equal(_reap(inner, pid, Int64(10_000) + _GRACE).reaped_count, Int64(2))
    _schedule_parent_chunks_for_delete[_FaultStore](m, Int64(50_000))
    assert_equal(m.read_log_start_seq(), Int64(4), "parent log start past top")
    assert_equal(len(m.tombstone_seqs()), 2, "chunks 2, 3 marked")
    var r = _reap(inner, pid, Int64(50_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(2), "chunks 2, 3 reclaimed")
    _assert_reclaimed(inner, pid, segs, 4, "parent with a reaped prefix")
    _ = m^
    _ = rp^
    print("[test_parent_with_a_reaped_prefix_is_retired] PASS")


# =============================================================================
# (5) advance_log_start_monotone: a lost CAS is retried; endless loss raises
# =============================================================================


def test_advance_retries_a_lost_cas_then_gives_up() raises:
    print("[test_advance_retries_a_lost_cas_then_gives_up] starting...")
    var inner = _Inner()
    var pid = Int64(6)
    _produce_chunks(inner, pid, 3)
    var m = _manifest(inner, pid)
    var lk = log_start_key(_prefix(pid)).raw()

    _arm(inner, _LOSE_CAS_ONCE, lk)
    assert_true(
        advance_log_start_monotone(m, Int64(1), Int64(10)), "won on the retry"
    )
    assert_false(_has(inner, _LOSE_CAS_ONCE + lk), "the first attempt lost")
    assert_equal(m.read_log_start_seq(), Int64(1), "advanced to 1")

    _arm(inner, _LOSE_CAS, lk)
    var raised = False
    try:
        _ = advance_log_start_monotone(m, Int64(2), Int64(20))
    except e:
        raised = True
        assert_true(String(e).find("exhausted retries") >= 0, String(e))
    assert_true(raised, "a CAS lost on every attempt gives up")
    _disarm(inner, _LOSE_CAS, lk)
    assert_equal(m.read_log_start_seq(), Int64(1), "still at 1")
    _ = m^
    print("[test_advance_retries_a_lost_cas_then_gives_up] PASS")


# =============================================================================
# (6) a read error on a LIVE chunk is never taken for a reaped one
# =============================================================================


def _assert_untouched(inner: _Inner, prefix: String, what: String) raises:
    var m = CasManifestStore[_FaultStore](
        store=_FaultStore(inner.clone()),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )
    assert_equal(len(m.tombstone_seqs()), 0, what + ": nothing tombstoned")
    var ls = m.read_log_start()
    assert_equal(ls.log_start_seq, Int64(0), what + ": log start seq unmoved")
    assert_equal(ls.log_start_offset, Int64(0), what + ": offset unmoved")
    _ = m^


def test_segment_fold_retire_raises_on_a_live_chunk_read_error() raises:
    """`SegmentBaseFold._retire_folded_source` walks a writer shard from its
    log start. A GET error on live chunk 1 must raise before any tombstone or
    advance; the old catch-all skipped it, tombstoned chunks 0 and 2 and
    advanced the log start to offset 30 with chunk 1's records uncounted."""
    print("[test_segment_fold_retire_raises_on_a_live_chunk_read_error] starting...")
    var inner = _Inner()
    var base_prefix = _prefix(Int64(7))
    var sp = sublineage_prefix(base_prefix, String("w01"))
    _produce_at(inner, sp, Int64(7), 3)
    var ck = chunk_key(sp, Int64(1)).raw()
    _arm(inner, _FAIL_GET_AFTER_ONE, ck)
    var fold = SegmentBaseFold[_FaultStore](_FaultStore(inner.clone()), base_prefix)
    var raised = False
    try:
        _ = fold._retire_folded_source(String("w01"), Int64(30), Int64(50_000))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the read error is raised")
    _disarm(inner, _FAIL_GET, ck)
    _assert_untouched(inner, sp, "segment fold")
    _ = fold^
    print("[test_segment_fold_retire_raises_on_a_live_chunk_read_error] PASS")


def test_migration_retire_raises_on_a_live_chunk_read_error() raises:
    """`SubLineageMigration._retire_migrated_legacy` walks the legacy
    manifest from its log start: the same rule."""
    print("[test_migration_retire_raises_on_a_live_chunk_read_error] starting...")
    var inner = _Inner()
    var pid = Int64(8)
    _produce_chunks(inner, pid, 3)
    var ck = chunk_key(_prefix(pid), Int64(1)).raw()
    _arm(inner, _FAIL_GET_AFTER_ONE, ck)
    var mig = SubLineageMigration[_FaultStore](
        _FaultStore(inner.clone()), _prefix(pid)
    )
    var legacy = mig._legacy_manifest()
    var raised = False
    try:
        _ = mig._retire_migrated_legacy(legacy, Int64(30), Int64(50_000))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the read error is raised")
    _disarm(inner, _FAIL_GET, ck)
    _assert_untouched(inner, _prefix(pid), "migration")
    _ = legacy^
    _ = mig^
    print("[test_migration_retire_raises_on_a_live_chunk_read_error] PASS")


def test_retire_walks_raise_on_a_live_chunk_reading_as_absent() raises:
    """The original bug's shape: live chunk 1 (at or above the floor) READS
    AS ABSENT. Neither retire walk may take that for a reaped chunk: both
    raise before any tombstone or advance. Catches a walk that skips only
    not_found and re-raises the rest."""
    print("[test_retire_walks_raise_on_a_live_chunk_reading_as_absent] starting...")
    var inner = _Inner()
    # Segment fold, writer shard w01 of partition 9.
    var base_prefix = _prefix(Int64(9))
    var sp = sublineage_prefix(base_prefix, String("w01"))
    _produce_at(inner, sp, Int64(9), 3)
    var ck = chunk_key(sp, Int64(1)).raw()
    _arm(inner, _ABSENT_GET_AFTER_ONE, ck)
    var fold = SegmentBaseFold[_FaultStore](_FaultStore(inner.clone()), base_prefix)
    var raised = False
    try:
        _ = fold._retire_folded_source(String("w01"), Int64(30), Int64(50_000))
    except e:
        raised = True
        assert_true(String(e).find("reads as absent") >= 0, String(e))
    assert_true(raised, "segment fold: a live chunk reading as absent raises")
    _disarm(inner, _ABSENT_GET, ck)
    _assert_untouched(inner, sp, "segment fold, absent")
    _ = fold^
    # Migration, legacy manifest of partition 10.
    var pid = Int64(10)
    _produce_chunks(inner, pid, 3)
    var lk = chunk_key(_prefix(pid), Int64(1)).raw()
    _arm(inner, _ABSENT_GET_AFTER_ONE, lk)
    var mig = SubLineageMigration[_FaultStore](
        _FaultStore(inner.clone()), _prefix(pid)
    )
    var legacy = mig._legacy_manifest()
    var raised2 = False
    try:
        _ = mig._retire_migrated_legacy(legacy, Int64(30), Int64(50_000))
    except e:
        raised2 = True
        assert_true(String(e).find("reads as absent") >= 0, String(e))
    assert_true(raised2, "migration: a live chunk reading as absent raises")
    _disarm(inner, _ABSENT_GET, lk)
    _assert_untouched(inner, _prefix(pid), "migration, absent")
    _ = legacy^
    _ = mig^
    print("[test_retire_walks_raise_on_a_live_chunk_reading_as_absent] PASS")


def test_retire_walks_rerun_after_a_failed_advance() raises:
    """The tombstones land and the swallowed advance fails (or the process
    stops in between): the tombstones sit on live chunks, which the reaper
    skips. A re-run counts no new tombstone (it re-stamps the stranded
    ones), and advances the log start."""
    print("[test_retire_walks_rerun_after_a_failed_advance] starting...")
    var inner = _Inner()
    # Segment fold.
    var base_prefix = _prefix(Int64(11))
    var sp = sublineage_prefix(base_prefix, String("w01"))
    _produce_at(inner, sp, Int64(11), 3)
    var sk = log_start_key(sp).raw()
    _arm(inner, _FAIL_PUT, sk)
    var fold = SegmentBaseFold[_FaultStore](_FaultStore(inner.clone()), base_prefix)
    var n1 = fold._retire_folded_source(String("w01"), Int64(30), Int64(50_000))
    assert_equal(n1, 3, "segment fold: 3 chunks tombstoned")
    var sm = CasManifestStore[_FaultStore](
        store=_FaultStore(inner.clone()), prefix=sp, retry=RetryPolicy.fast_test()
    )
    assert_equal(sm.read_log_start_seq(), Int64(0), "segment fold: advance failed")
    var sr = ReapWorker[_FaultStore](_GRACE)
    var seg_store = _FaultStore(inner.clone())
    var r = sr.run(seg_store, sm, Int64(50_000) + _GRACE)
    assert_equal(r.skipped_live_count, Int64(3), "segment fold: reaper skips all")
    assert_equal(r.reaped_count, Int64(0), "segment fold: nothing reaped")
    _disarm(inner, _FAIL_PUT, sk)
    var n2 = fold._retire_folded_source(String("w01"), Int64(30), Int64(60_000))
    assert_equal(n2, 0, "segment fold: the re-run tombstones nothing new")
    var sls = sm.read_log_start()
    assert_equal(sls.log_start_seq, Int64(3), "segment fold: log start seq 3")
    assert_equal(sls.log_start_offset, Int64(30), "segment fold: offset 30")
    _ = sm^
    _ = fold^
    # Migration.
    var pid = Int64(12)
    _produce_chunks(inner, pid, 3)
    var lk = log_start_key(_prefix(pid)).raw()
    _arm(inner, _FAIL_PUT, lk)
    var mig = SubLineageMigration[_FaultStore](
        _FaultStore(inner.clone()), _prefix(pid)
    )
    var legacy = mig._legacy_manifest()
    var m1 = mig._retire_migrated_legacy(legacy, Int64(30), Int64(50_000))
    assert_equal(m1, 3, "migration: 3 chunks tombstoned")
    assert_equal(legacy.read_log_start_seq(), Int64(0), "migration: advance failed")
    var r2 = _reap(inner, pid, Int64(50_000) + _GRACE)
    assert_equal(r2.skipped_live_count, Int64(3), "migration: reaper skips all")
    assert_equal(r2.reaped_count, Int64(0), "migration: nothing reaped")
    _disarm(inner, _FAIL_PUT, lk)
    var m2 = mig._retire_migrated_legacy(legacy, Int64(30), Int64(60_000))
    assert_equal(m2, 0, "migration: the re-run tombstones nothing new")
    var lls = legacy.read_log_start()
    assert_equal(lls.log_start_seq, Int64(3), "migration: log start seq 3")
    assert_equal(lls.log_start_offset, Int64(30), "migration: offset 30")
    _ = legacy^
    _ = mig^
    print("[test_retire_walks_rerun_after_a_failed_advance] PASS")


def main() raises:
    test_failed_advance_tombstones_are_skipped_then_reclaimed()
    test_unreadable_log_start_reaps_nothing()
    test_parent_compaction_advances_then_reaper_reclaims()
    test_parent_compaction_failed_advance_marks_nothing()
    test_parent_compaction_empty_parent_is_a_noop()
    test_parent_compaction_resumes_after_failed_advance()
    test_parent_compaction_failed_tombstone_then_resume()
    test_parent_compaction_of_a_never_split_pid_raises()
    test_parent_with_a_reaped_prefix_is_retired()
    test_advance_retries_a_lost_cas_then_gives_up()
    test_segment_fold_retire_raises_on_a_live_chunk_read_error()
    test_migration_retire_raises_on_a_live_chunk_read_error()
    test_retire_walks_raise_on_a_live_chunk_reading_as_absent()
    test_retire_walks_rerun_after_a_failed_advance()
    print("[OK] test_broker_reap_below_log_start_offline — 14 cases passed")
