# =============================================================================
# tests/test_cov_coalescing_produce_unit.mojo
#   The parkable coalescing produce driver: the txn-open flush, the three
#   non-committing exactly-once outcomes, the linger-timer and shutdown
#   flushes, and the conformers' error classifiers.
# =============================================================================
#
#   1. reconfigure_txn: the committed chunk carries the txn id, the producer
#      trailer and MARKER_NONE.
#   2. EOS singleton: a zombie producer epoch is FENCED, a stale writer lease
#      is LEASE_FENCED, and a claim another writer staged but never committed
#      is RETRYABLE; none of them writes a chunk.
#   3. on_deadline with the armed linger timer starts a LINGER flush;
#      force_shutdown starts a SHUTDOWN flush.
#   4. The head reader's and stage-blob error classifiers, the elided head
#      poll, and the singleton appender's poll.
#   5. A store that defers the create-CAS 412 to cas_put_take: the escalating
#      appender reports LOST_SLOT and writes no chunk. The spine factory's
#      flush_ts for an empty buffer is 0.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor

from komira_broker.broker_coalescing_produce import (
    BPO_EOS_FENCED,
    BPO_EOS_LEASE_FENCED,
    BPO_EOS_RETRYABLE,
    BROKER_APPEND_MODE_ESCALATING,
    BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
    BrokerBatchAppender,
    BrokerCoalescingProduce,
    BrokerHeadReader,
    BrokerProduceItem,
    BrokerProduceSpineFactory,
    _EosResultCell,
)
from komira_broker.manifest_body import MARKER_NONE, ManifestBody
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    DedupSentinel,
    dedup_sentinel_key,
    encode_dedup_sentinel,
)
from komira_objectstore.coalescing_window import (
    APPEND_LOST_SLOT,
    APPEND_WON,
    FLUSH_REASON_LINGER,
    FLUSH_REASON_SHUTDOWN,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
    READ_ERR_TORN,
    STAGE_BLOB_ERR_FATAL,
    STAGE_BLOB_ERR_REKEY,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
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


comptime _Slow = SharedInMemorySlowCasStore
comptime _Shared = SharedInMemoryConditionalStore
comptime _PREFIX = "c/_meta/topics/t/0"


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


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


def _batch_body() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(16):
        out.append(UInt8(i))
    return out^


def _driver(slow: _Slow) raises -> BrokerCoalescingProduce[_Slow]:
    return BrokerCoalescingProduce[_Slow](
        slow.clone(), String("c"), String("t"), Int64(0), String("b")
    )


def _drive(mut win: BrokerCoalescingProduce[_Slow], mut reactor: Reactor[NoopSink]) raises:
    var guard = 0
    while win.is_inflight() and guard < 256:
        var ready = reactor.poll_completions(-1)
        for k in range(len(ready)):
            if ready[k].op_id == win.parked_op_id():
                _ = win.poll[NoopSink](reactor)
        guard += 1


def _meta(slow: _Slow) -> CasManifestStore[_Shared]:
    return CasManifestStore[_Shared](slow.inner_ref().clone(), String(_PREFIX))


def _chunks(slow: _Slow) raises -> Int64:
    var m = _meta(slow)
    return m.num_chunks()


# ---- 1. txn-open flush ------------------------------------------------------------


def test_txn_flush_tags_the_chunk() raises:
    var reactor = _reactor()
    var slow = _Slow(slow_ticks=0)
    var win = _driver(slow)
    win.buffer[NoopSink](_batch(Int64(0), 3), Int64(10), reactor)
    win.reconfigure_txn(Int64(7), Int64(2), Int64(0), Int64(2), String("tx1"))
    _ = win.force[NoopSink](Int64(20), reactor)
    _drive(win, reactor)
    assert_false(win.has_error(), win.err_text())
    assert_equal(len(win.take_outcomes()), 1)
    var m = _meta(slow)
    var body = ManifestBody.decode(m.read_chunk(Int64(0)))
    assert_equal(body.txn_id, "tx1")
    assert_equal(body.marker_type, MARKER_NONE)
    assert_equal(body.producer_id, Int64(7))
    assert_equal(body.producer_epoch, Int64(2))
    assert_equal(body.last_seq, Int64(2))
    assert_equal(body.creation_ts_ms, Int64(10))


# ---- 2. exactly-once outcomes that commit nothing -----------------------------------


def _eos(
    slow: _Slow, epoch: Int64, registered: Int64, writer: Int64, current: Int64
) raises -> BrokerCoalescingProduce[_Slow]:
    var reactor = _reactor()
    var win = _driver(slow)
    win.buffer[NoopSink](_batch(Int64(0), 3), Int64(0), reactor)
    win.reconfigure_eos_singleton(
        Int64(5), epoch, Int64(0), Int64(2), registered, writer, current
    )
    _ = win.force[NoopSink](Int64(1), reactor)
    _drive(win, reactor)
    return win^


def test_eos_outcomes_without_commit() raises:
    var s1 = _Slow(slow_ticks=0)
    var fenced = _eos(s1, Int64(0), Int64(1), Int64(0), Int64(0))
    assert_equal(Int(fenced.last_eos_kind()), Int(BPO_EOS_FENCED))
    assert_true(fenced.has_error())
    assert_true(fenced.err_text().find("FENCED (stale producer-epoch zombie)") >= 0)
    assert_equal(fenced.last_eos_base_offset(), Int64(-1))
    assert_equal(_chunks(s1), Int64(0))

    var s2 = _Slow(slow_ticks=0)
    var lease = _eos(s2, Int64(1), Int64(1), Int64(3), Int64(4))
    assert_equal(Int(lease.last_eos_kind()), Int(BPO_EOS_LEASE_FENCED))
    assert_true(lease.err_text().find("LEASE_FENCED (stale partition-ownership writer)") >= 0)
    assert_equal(_chunks(s2), Int64(0))

    # Another writer's claim on (5, 0) is staged and never committed.
    var s3 = _Slow(slow_ticks=0)
    _ = s3.inner_ref().put(
        dedup_sentinel_key(_PREFIX, Int64(5), Int64(0)),
        encode_dedup_sentinel(
            DedupSentinel.staged(Int64(5), Int64(1), Int64(0), Int64(2))
        ),
    )
    var retry = _eos(s3, Int64(1), Int64(1), Int64(0), Int64(0))
    assert_equal(Int(retry.last_eos_kind()), Int(BPO_EOS_RETRYABLE))
    assert_true(retry.err_text().find("RETRYABLE (in-flight winner / no commit)") >= 0)
    assert_equal(retry.last_eos_last_offset(), Int64(-1))
    assert_equal(_chunks(s3), Int64(0))


# ---- 3. linger and shutdown flushes ---------------------------------------------------


def test_linger_and_shutdown_flushes() raises:
    var reactor = _reactor()
    var slow = _Slow(slow_ticks=0)
    var win = _driver(slow)
    _ = win.produce[NoopSink](_batch(Int64(0), 2), Int64(0), reactor)
    assert_false(win.is_inflight())
    var timer = win.timer_op_id()
    assert_true(timer != Int64(0))
    # A fire that is not the armed timer starts nothing.
    assert_equal(win.on_deadline[NoopSink](timer + 1, Int64(300), reactor), Int64(0))
    assert_equal(win.pending_count(), 1)
    _ = win.on_deadline[NoopSink](timer, Int64(300), reactor)
    _drive(win, reactor)
    assert_equal(Int(win.last_flush_reason()), Int(FLUSH_REASON_LINGER))
    assert_equal(len(win.take_outcomes()), 1)
    assert_equal(_chunks(slow), Int64(1))
    win.buffer[NoopSink](_batch(Int64(2), 2), Int64(400), reactor)
    _ = win.force_shutdown[NoopSink](reactor)
    _drive(win, reactor)
    assert_equal(Int(win.last_flush_reason()), Int(FLUSH_REASON_SHUTDOWN))
    var oc = win.take_outcomes()
    assert_equal(len(oc), 1)
    assert_equal(oc[0][1].base_offset, Int64(2))
    assert_equal(_chunks(slow), Int64(2))


# ---- 4. classifiers and the never-in-flight polls ----------------------------------------


def test_classifiers_and_idle_polls() raises:
    var reactor = _reactor()
    var slow = _Slow(slow_ticks=0)
    var reader = BrokerHeadReader[_Slow](slow.clone())
    assert_equal(reader.classify_read_error("connect failed: refused"), READ_ERR_FATAL)
    assert_equal(reader.classify_read_error("read: errno 104"), READ_ERR_FATAL)
    assert_equal(reader.classify_read_error("precondition (412)"), READ_ERR_CONFLICT)
    assert_equal(reader.classify_read_error("short body"), READ_ERR_TORN)
    assert_true(reader.read_head_poll[NoopSink](reactor).is_ready())
    assert_equal(reader.classify_stage_blob_error("precondition (412)"), STAGE_BLOB_ERR_REKEY)
    assert_equal(reader.classify_stage_blob_error("503 slow down"), STAGE_BLOB_ERR_FATAL)
    var app = BrokerBatchAppender[_Slow](
        CasManifestStore[_Slow](slow.clone(), String(_PREFIX)),
        BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
        ArcPointer[_EosResultCell](_EosResultCell()),
    )
    assert_true(app.append_poll[NoopSink](reactor).is_ready())



# ---- 5. a create-CAS whose 412 surfaces only at take -------------------------------


struct _TakeDefers412(
    AsyncCasStore,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates to the slow store, except that while `defer_412` is set a
    create-CAS reports READY from `cas_put_start` and raises the 412 from
    `cas_put_take` (a conformer that defers the lost slot to the take)."""

    var inner: _Slow
    var defer_412: Bool
    var _lost: Bool

    def __init__(out self, var inner: _Slow, defer_412: Bool):
        self.inner = inner^
        self.defer_412 = defer_412
        self._lost = False

    def clone(self) -> Self:
        return Self(self.inner.clone(), self.defer_412)

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_start[S](path, reactor)

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_poll[S](reactor)

    def read_take(mut self) raises -> CasReadResult:
        return self.inner.read_take()

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        if self.defer_412:
            self._lost = True
            return CasOpProgress.ready()
        return self.inner.cas_put_start[S](path, bytes^, expected_etag, reactor)

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        if self._lost:
            self._lost = False
            raise Error("conditional create: precondition failed (412)")
        return self.inner.cas_put_take()


def test_deferred_412_is_a_lost_slot() raises:
    var reactor = _reactor()
    var slow = _Slow(slow_ticks=0)
    var app = BrokerBatchAppender[_TakeDefers412](
        CasManifestStore[_TakeDefers412](
            _TakeDefers412(slow.clone(), True), String(_PREFIX)
        ),
        BROKER_APPEND_MODE_ESCALATING,
        ArcPointer[_EosResultCell](_EosResultCell()),
    )
    var p = app.append_start[NoopSink](
        _batch_body(), Int64(1), Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(p.is_ready())
    var lost = app.append_take()
    assert_equal(Int(lost.kind), Int(APPEND_LOST_SLOT))
    assert_equal(_chunks(slow), Int64(0))
    # The re-drive runs on a fresh op and wins slot 0.
    app._wal.store_mut().defer_412 = False
    var p2 = app.append_start[NoopSink](
        _batch_body(), Int64(1), Int64(0), Int64(0), Int64(0), reactor
    )
    assert_true(p2.is_ready())
    var won = app.append_take()
    assert_equal(Int(won.kind), Int(APPEND_WON))
    assert_equal(won.result.chunk_seq, Int64(0))
    assert_equal(_chunks(slow), Int64(1))


def test_spine_factory_empty_buffer_flush_ts() raises:
    var slow = _Slow(slow_ticks=0)
    var factory = BrokerProduceSpineFactory[_Slow](
        slow.clone(),
        String("c"),
        String("t"),
        Int64(0),
        String("b"),
        ArcPointer[_EosResultCell](_EosResultCell()),
    )
    # With no buffered item the segment key's flush_ts falls back to 0.
    assert_equal(factory._flush_ts_for(Slab[BrokerProduceItem]()), Int64(0))
    _ = factory.make_spine(Slab[BrokerProduceItem](), FLUSH_REASON_LINGER)


def main() raises:
    test_txn_flush_tags_the_chunk()
    test_eos_outcomes_without_commit()
    test_linger_and_shutdown_flushes()
    test_classifiers_and_idle_polls()
    test_deferred_412_is_a_lost_slot()
    test_spine_factory_empty_buffer_flush_ts()
    print("[OK] test_cov_coalescing_produce_unit")
