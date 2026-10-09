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
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor

from komira_broker.broker_coalescing_produce import (
    BPO_EOS_FENCED,
    BPO_EOS_LEASE_FENCED,
    BPO_EOS_RETRYABLE,
    BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
    BrokerBatchAppender,
    BrokerCoalescingProduce,
    BrokerHeadReader,
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
    FLUSH_REASON_LINGER,
    FLUSH_REASON_SHUTDOWN,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
    READ_ERR_TORN,
    STAGE_BLOB_ERR_FATAL,
    STAGE_BLOB_ERR_REKEY,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
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


def main() raises:
    test_txn_flush_tags_the_chunk()
    test_eos_outcomes_without_commit()
    test_linger_and_shutdown_flushes()
    test_classifiers_and_idle_polls()
    print("[OK] test_cov_coalescing_produce_unit")
