# =============================================================================
# test_broker_scan_plan_reaped_tag_offline — a chunk that vanishes between the
# plan's index walk and its tag walk is never planned as non-transactional.
# =============================================================================
#
# `BrokerScanRuntime.plan_splits` reads a partition's `_LOG_START`, its offset
# index (`ConsumeCore.resolve_index`) and its transaction tags
# (`ConsumeCore.chunk_txn_tags`) in three walks. The tag walk skips a chunk
# that reads `not_found`. If chunk 0 is deleted after the index walk read it
# and before the tag walk does, the index holds chunk 0 and the tags do not.
# Before the fix the plan treated that chunk as non-transactional: an ongoing
# transaction's chunk no longer lowered the last stable offset.
#
# `_DeletesChunk0Store` makes the interleaving deterministic. Once armed, the
# first walk GET of chunk 0 (the index walk) is served; the second (the tag
# walk) deletes chunk 0 first and reads `not_found`. In `reap` mode it lands
# a `_LOG_START` advance past chunk 0 before the delete, as retention does
# (it advances `_LOG_START` and only then deletes below it). In torn mode it
# deletes chunk 0 with `_LOG_START` still at 0.
#
#   1. Torn: chunk 0 is missing at or above `_LOG_START`. The plan raises by
#      name. Before the fix it returned last stable offset 3 (the high
#      watermark) although chunk 0's transaction is ongoing.
#   2. Reap: the plan restarts from the moved `_LOG_START` and equals the
#      plan made after the reap settled. Before the fix it reported log start
#      0 and a split starting at the reaped chunk.
#
# The `_LOG_START` advance is computed on a SHADOW store and copied raw: the
# hook runs inside `CasManifestStore.read_chunk`, under the process-wide CAS
# gate's read lock, so an in-place `advance_log_start` would self-deadlock.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_scan_resolver.scan_source_resolver import ScanRequest
from komira_scan_resolver.scan_split import ScanSplitPlan
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_broker.broker_core import BrokerCore, BrokerTopicConfig, _topic_config_key
from komira_broker.broker_scan_binding import (
    BROKER_ISOLATION_READ_COMMITTED,
    BROKER_PARAM_ISOLATION,
    BROKER_PARAM_TOPIC,
)
from komira_broker.broker_scan_kind import (
    BROKER_RESOLVED_ABORTED,
    BROKER_RESOLVED_HIGH_WATERMARK,
    BROKER_RESOLVED_LAST_STABLE_OFFSET,
    BROKER_RESOLVED_LOG_START_OFFSET,
    BrokerScanRuntime,
    broker_resolved_key,
)
from komira_broker.broker_split_reader import (
    broker_position_offset,
    broker_position_skip,
)
from komira_broker.txn_control import TxnControlStore
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
comptime _C = "bsrt"
comptime _T = "t"
comptime _ARMED = "reap-hook/armed"
comptime _SEEN = "reap-hook/seen"
comptime _FIRED = "reap-hook/fired"
comptime _LISTED = "reap-hook/listed"


def _prefix() -> String:
    return String(_C) + "/_meta/topics/" + String(_T) + "/0"


def _has(store: _Inner, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


def _mark(store: _Inner, key: String) raises:
    _ = store.put(Path.parse(key), List[UInt8]())


struct _DeletesChunk0Store(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates every verb to a shared in-memory store. Once `_ARMED` is
    set, the second WALK GET of chunk 0 deletes chunk 0 (once) before it
    runs; in `reap` mode it first copies the shadow's `_LOG_START` in. The
    one-shot state lives in the shared inner store, so every clone sees it.

    A walk GET is one not preceded by a LIST since the last `_LOG_START`
    GET. Every authoritative head read (`read_head_authoritative`) also GETs
    chunk 0, but after a `_LOG_START` GET and a LIST of the manifest; the
    walks (`resolve_index`, `chunk_txn_tags`) GET `_LOG_START` and then the
    chunks, with no LIST between."""

    var _inner: _Inner
    var _shadow: _Inner
    var _reap: Bool

    def __init__(out self, var inner: _Inner, var shadow: _Inner, reap: Bool):
        self._inner = inner^
        self._shadow = shadow^
        self._reap = reap

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._shadow.clone(), self._reap)

    def _armed(self) -> Bool:
        return _has(self._inner, String(_ARMED)) and not _has(
            self._inner, String(_FIRED)
        )

    def _before_get(self, key: String) raises:
        if not self._armed():
            return
        if key == log_start_key(_prefix()).raw():
            if _has(self._inner, String(_LISTED)):
                self._inner.delete(Path.parse(String(_LISTED)))
            return
        if key != chunk_key(_prefix(), Int64(0)).raw():
            return
        if _has(self._inner, String(_LISTED)):
            return  # a head recovery's replay, not a walk
        if not _has(self._inner, String(_SEEN)):
            _mark(self._inner, String(_SEEN))
            return
        _mark(self._inner, String(_FIRED))
        if self._reap:
            var ls = log_start_key(_prefix())
            _ = self._inner.put(ls, self._shadow.get(ls))
        self._inner.delete(chunk_key(_prefix(), Int64(0)))

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        if self._armed():
            _mark(self._inner, String(_LISTED))
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._before_get(path.raw())
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._before_get(path.raw())
        return self._inner.get(path)

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

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _schema() -> Schema:
    return Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )


def _batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.unsafe_store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


def _manifest(store: _Inner) -> CasManifestStore[_Inner]:
    return CasManifestStore[_Inner](
        store=store.clone(), prefix=_prefix(), retry=RetryPolicy.fast_test()
    )


def _seed() raises -> _Inner:
    """Chunk 0: offsets 0-1 inside transaction `T`, left ongoing. Chunk 1:
    offset 2, non-transactional. High watermark 3."""
    var store = _Inner()
    var cfg = BrokerTopicConfig(1, List[String](), _schema())
    _ = store.put(Path.parse(_topic_config_key(String(_C), String(_T))), cfg.encode())
    var ctl = TxnControlStore[_Inner](store.clone(), String(_C))
    _ = ctl.begin("T", Int64(1), Int64(0))
    var core = BrokerCore[_Inner](
        segment_store=store.clone(),
        manifest=_manifest(store),
        cluster=String(_C),
        topic=String(_T),
        partition=Int64(0),
        broker_id=String("b"),
    )
    core.buffer_batch(_batch(Int64(0), 2), Int64(1))
    _ = core.flush_with_producer_txn(Int64(1), Int64(1), Int64(0), Int64(0), Int64(1), "T")
    core.buffer_batch(_batch(Int64(2), 1), Int64(2))
    _ = core.flush(Int64(2))
    return store^


def _shadow_log_start_past_chunk_0() raises -> _Inner:
    """A store whose only object is `_LOG_START` = (seq 1, offset 2)."""
    var shadow = _Inner()
    var m = _manifest(shadow)
    _ = m.advance_log_start(Int64(1), Int64(2), String(""))
    return shadow^


def _plan(rt: BrokerScanRuntime[_DeletesChunk0Store]) raises -> ScanSplitPlan:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String(_T))
    p.put_str(String(BROKER_PARAM_ISOLATION), String(BROKER_ISOLATION_READ_COMMITTED))
    return rt.plan_splits(ScanRequest(resolve_for_execution(rt, rt.build_binding(p))))


def _resolved(plan: ScanSplitPlan, key: String) -> Int64:
    return plan.resolved.get_i64(broker_resolved_key(key, Int64(0)), Int64(-1))


# ---- 1. torn: a missing chunk at or above _LOG_START is refused ---------------


def test_chunk_missing_above_log_start_between_walks_is_refused() raises:
    var inner = _seed()
    var rt = BrokerScanRuntime[_DeletesChunk0Store](
        _DeletesChunk0Store(inner.clone(), _Inner(), False), String(_C)
    )
    _mark(inner, String(_ARMED))
    with assert_raises(contains="has no transaction tag"):
        _ = _plan(rt)
    assert_true(_has(inner, String(_FIRED)), "fixture: chunk 0 was never deleted")


# ---- 2. reap: the plan restarts from the moved _LOG_START ---------------------


def test_chunk_reaped_between_walks_plans_like_the_settled_log() raises:
    var inner = _seed()
    var rt = BrokerScanRuntime[_DeletesChunk0Store](
        _DeletesChunk0Store(inner.clone(), _shadow_log_start_past_chunk_0(), True),
        String(_C),
    )
    _mark(inner, String(_ARMED))
    var raced = _plan(rt)
    assert_true(_has(inner, String(_FIRED)), "fixture: chunk 0 was never reaped")
    var settled = _plan(rt)

    assert_equal(_resolved(raced, BROKER_RESOLVED_LOG_START_OFFSET), Int64(2))
    assert_equal(len(raced.splits), 1)
    assert_equal(broker_position_offset(raced.splits[0].start, "start"), Int64(2))
    assert_equal(len(settled.splits), 1)
    assert_equal(
        _resolved(raced, BROKER_RESOLVED_HIGH_WATERMARK),
        _resolved(settled, BROKER_RESOLVED_HIGH_WATERMARK),
    )
    assert_equal(
        _resolved(raced, BROKER_RESOLVED_LAST_STABLE_OFFSET),
        _resolved(settled, BROKER_RESOLVED_LAST_STABLE_OFFSET),
    )
    assert_equal(
        _resolved(raced, BROKER_RESOLVED_LOG_START_OFFSET),
        _resolved(settled, BROKER_RESOLVED_LOG_START_OFFSET),
    )
    var ak = broker_resolved_key(String(BROKER_RESOLVED_ABORTED), Int64(0))
    assert_equal(raced.resolved.get_str(ak), settled.resolved.get_str(ak))
    assert_equal(
        broker_position_offset(raced.splits[0].start, "start"),
        broker_position_offset(settled.splits[0].start, "start"),
    )
    assert_equal(
        broker_position_offset(raced.splits[0].stop.value(), "stop"),
        broker_position_offset(settled.splits[0].stop.value(), "stop"),
    )
    assert_equal(
        len(broker_position_skip(raced.splits[0].start, "start")),
        len(broker_position_skip(settled.splits[0].start, "start")),
    )


def main() raises:
    test_chunk_missing_above_log_start_between_walks_is_refused()
    test_chunk_reaped_between_walks_plans_like_the_settled_log()
    print("[OK] test_broker_scan_plan_reaped_tag_offline")
