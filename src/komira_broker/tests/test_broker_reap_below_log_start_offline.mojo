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

from komira_broker.broker_core import BrokerCore
from komira_broker.manifest_body import ManifestBody
from komira_broker.partition_compaction import _schedule_parent_chunks_for_delete
from komira_broker.retention import (
    ReapResult,
    ReapWorker,
    RetentionPass,
    RetentionPolicy,
)

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
    log_start_key,
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

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._fail_if(_FAIL_GET, path)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._fail_if(_FAIL_GET, path)
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._fail_if(_FAIL_PUT, path)
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
    var broker = BrokerCore[_FaultStore](
        segment_store=_FaultStore(inner.clone()),
        manifest=_manifest(inner, pid),
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


def main() raises:
    test_failed_advance_tombstones_are_skipped_then_reclaimed()
    test_unreadable_log_start_reaps_nothing()
    test_parent_compaction_advances_then_reaper_reclaims()
    test_parent_compaction_failed_advance_marks_nothing()
    print("[OK] test_broker_reap_below_log_start_offline — 4 cases passed")
