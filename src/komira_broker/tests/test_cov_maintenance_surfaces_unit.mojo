# =============================================================================
# tests/test_cov_maintenance_surfaces_unit.mojo
#   Public surfaces no other welded test calls: the consumer source edge,
#   the merge maintenance scan, the rollout-audited retention pass, the
#   split / merge policy defaults, PartitionMap.copy and the segment codec's
#   size estimate.
# =============================================================================
#
#   1. MessageBrokerConsumer: schema, the row estimate (and its floor at 0
#      past the tail), a fingerprint that differs by topic / partition /
#      start, no filter pushdown, and the drain from the start offset.
#   2. run_merge_maintenance_scan: a fixed topic is a no-op; cold adjacent
#      ranges merge (a hot range does not), bounded by max_merges_per_scan;
#      a pair merged by someone else between the scan's read and its merge
#      is proposed but not landed.
#   3. run_with_rollout_audit: an empty manifest is a clean audit; a pass
#      with nothing out of policy audits and retires nothing; time-based
#      passes audit, tombstone and advance the log start to a surviving
#      snapshot chunk, then to the active chunk.
#   4. AutoSplitPolicy / AutoMergePolicy defaults, PartitionMap.copy, and
#      BrokerSegCodec.estimate_bytes (the encoded frame size).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_not_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr

from komira_broker.broker_coalescing_produce import BrokerProduceItem, BrokerSegCodec
from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore
from komira_broker.consumer_source import MessageBrokerConsumer
from komira_broker.partition_map import (
    HashRange,
    PARTITION_MODE_AUTO,
    PartitionMap,
    persist_create_if_absent,
    read_partition_map,
)
from komira_broker.partition_merge_driver import run_merge_maintenance_scan
from komira_broker.partition_trigger import (
    AutoMergePolicy,
    AutoSplitPolicy,
    DEFAULT_MAX_PARTITIONS,
    DEFAULT_MERGE_THRESHOLD_RECORDS,
    DEFAULT_SPLIT_THRESHOLD_RECORDS,
)
from komira_broker.retention import RetentionPass, RetentionPolicy
from komira_broker.sublineage_rollout_metrics import SubLineageRolloutMetrics
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
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

# =============================================================================
# _FaultStore: a shared in-memory store that fails one verb on demand.
# =============================================================================
#
# A rule per verb (get, head, put, cput, cas, range, list, delete) lives in the
# shared map under `__fault__/<verb>/...`: the path substring it matches, how
# many matching calls to let through first (skip), how many to fail after that
# (count; -1 fails every one) and the error message. A message
# `@copy:<key>` raises nothing: it copies the object at <key> over the path
# first, a concurrent writer landing just before this call. Clones share the
# map, so a test arms a rule through any handle.

comptime _FK = "__fault__/"


def _bytes_to_string(raw: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(raw)):
        s += chr(Int(raw[i]))
    return s^


struct _FaultStore(CloneableConditionalWriteStore, ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: SharedInMemoryConditionalStore

    def __init__(out self):
        self.inner = SharedInMemoryConditionalStore()

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self.inner = inner^

    def clone(self) -> Self:
        return Self(self.inner.clone())

    def _set(self, k: String, v: String) raises:
        var b = List[UInt8]()
        for x in v.as_bytes():
            b.append(x)
        _ = self.inner.put(Path.parse(_FK + k), b)

    def _get(self, k: String) -> Optional[String]:
        try:
            return Optional[String](
                _bytes_to_string(self.inner.get(Path.parse(_FK + k)))
            )
        except e:
            _ = e
            return Optional[String](None)

    def arm(
        self, verb: String, sub: String, skip: Int, count: Int, msg: String
    ) raises:
        self._set(verb + "/sub", sub)
        self._set(verb + "/skip", String(skip))
        self._set(verb + "/msg", msg)
        self._set(verb + "/count", String(count))

    def disarm(self, verb: String) raises:
        self._set(verb + "/count", "0")

    def _check(self, verb: String, path: Path) raises:
        var cnt = self._get(verb + "/count")
        if not cnt:
            return
        var c = Int(cnt.value())
        if c == 0:
            return
        var raw = path.raw()
        if raw.startswith(_FK):
            return
        if raw.find(self._get(verb + "/sub").value()) < 0:
            return
        var skip = Int(self._get(verb + "/skip").value())
        if skip > 0:
            self._set(verb + "/skip", String(skip - 1))
            return
        if c > 0:
            self._set(verb + "/count", String(c - 1))
        var msg = self._get(verb + "/msg").value()
        if msg.startswith("@copy:"):
            var src = String(msg[byte=6 : msg.byte_length()])
            _ = self.inner.put(path, self.inner.get(Path.parse(src)))
            return
        raise Error(msg)

    def head(self, path: Path) raises -> ObjectMeta:
        self._check("head", path)
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._check("list", prefix)
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._check("cput", path)
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._check("cas", path)
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._check("put", path)
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._check("range", path)
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._check("get", path)
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._check("delete", path)
        self.inner.delete(path)


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
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


def _prefix(topic: String, pid: Int) -> String:
    return "c/_meta/topics/" + topic + "/" + String(pid)


def _manifest(fs: _FaultStore, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _core(fs: _FaultStore, topic: String, pid: Int) -> BrokerCore[_FaultStore]:
    return BrokerCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=_manifest(fs, _prefix(topic, pid)),
        cluster=String("c"),
        topic=topic,
        partition=Int64(pid),
        broker_id=String("b"),
    )


def _consume(fs: _FaultStore, topic: String, pid: Int) -> ConsumeCore[_FaultStore]:
    return ConsumeCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=_manifest(fs, _prefix(topic, pid)),
        cluster=String("c"),
        topic=topic,
        partition=Int64(pid),
    )


def _consumer(
    fs: _FaultStore, topic: String, pid: Int, start: Int64
) -> MessageBrokerConsumer[_FaultStore]:
    return MessageBrokerConsumer[_FaultStore](
        _consume(fs, topic, pid), String("c"), topic, Int64(pid), start, _schema()
    )


# ---- 1. the consumer source edge ----------------------------------------------------------


def test_consumer_source_edge() raises:
    var fs = _FaultStore()
    var core = _core(fs, "t", 0)
    for i in range(3):
        core.buffer_batch(_batch(Int64(4 * i), 4), Int64(i))
        _ = core.flush(Int64(i))
    var c = _consumer(fs, "t", 0, Int64(5))
    assert_equal(c.schema().num_columns(), 1)
    assert_equal(c.estimate_rows(), -1)
    c.resolve_estimate()
    assert_equal(c.estimate_rows(), 7)
    var past = _consumer(fs, "t", 0, Int64(40))
    past.resolve_estimate()
    assert_equal(past.estimate_rows(), 0)
    assert_false(c.supports_filter_pushdown(Expr.col_ref("val")))
    var fp = c.fingerprint()
    assert_equal(fp, _consumer(fs, "t", 0, Int64(5)).fingerprint())
    assert_not_equal(fp, _consumer(fs, "u", 0, Int64(5)).fingerprint())
    assert_not_equal(fp, _consumer(fs, "t", 1, Int64(5)).fingerprint())
    assert_not_equal(fp, _consumer(fs, "t", 0, Int64(6)).fingerprint())
    var segs = c.drain_streams()
    assert_equal(len(segs), 2)
    assert_equal(segs[0].base_offset, Int64(4))


# ---- 2. the merge maintenance scan ------------------------------------------------------------


def _originals(n: Int) -> PartitionMap:
    var ranges = List[HashRange]()
    var step = UInt64.MAX / UInt64(n)
    for i in range(n):
        var lo = step * UInt64(i)
        var hi = UInt64.MAX if i == n - 1 else step * UInt64(i + 1)
        ranges.append(HashRange.original(lo, hi, i))
    return PartitionMap(version=1, mode=PARTITION_MODE_AUTO, ranges=ranges^)


def test_merge_maintenance_scan() raises:
    var fs = _FaultStore()
    persist_create_if_absent(fs, "c", "f", PartitionMap.fixed(3))
    var fixed = run_merge_maintenance_scan(fs, "c", "f", AutoMergePolicy.default())
    assert_equal(fixed.pairs_examined, 0)
    assert_equal(fixed.final_live_count, 3)
    # Four cold originals, pid 1 hot: (0,1) and (1,2) stay, (2,3) merges
    # into 4; the rescan sees (0,1), (1,4) and merges nothing more.
    persist_create_if_absent(fs, "c", "a", _originals(4))
    var hot = _core(fs, "a", 1)
    hot.buffer_batch(_batch(Int64(0), Int(DEFAULT_MERGE_THRESHOLD_RECORDS) + 1), Int64(1))
    _ = hot.flush(Int64(1))
    var r = run_merge_maintenance_scan(fs, "c", "a", AutoMergePolicy.default())
    assert_equal(r.merges_landed, 1)
    assert_equal(r.merges_proposed, 1)
    assert_equal(r.pairs_examined, 5)
    assert_equal(r.final_live_count, 3)
    assert_equal(r.final_version, 2)
    # All cold, at most one merge per scan.
    persist_create_if_absent(fs, "c", "b", _originals(4))
    var one = run_merge_maintenance_scan(fs, "c", "b", AutoMergePolicy.default(), 1)
    assert_equal(one.merges_landed, 1)
    assert_equal(read_partition_map(fs, "c", "b").num_partitions(), 3)
    # The pair is merged by someone else between the scan's read and its
    # merge: proposed, not landed.
    persist_create_if_absent(fs, "c", "r", _originals(2))
    _ = fs.inner.put(Path.parse("stage/map"), _originals(2).merge(0, 1).encode())
    fs.arm("head", "/r/partition_map.json", 0, 1, "@copy:stage/map")
    var raced = run_merge_maintenance_scan(fs, "c", "r", AutoMergePolicy.default())
    assert_equal(raced.merges_proposed, 1)
    assert_equal(raced.merges_landed, 0)
    assert_equal(read_partition_map(fs, "c", "r").num_partitions(), 1)


# ---- 3. the rollout-audited retention pass -----------------------------------------------------


def test_retention_with_rollout_audit(mut m: SubLineageRolloutMetrics) raises:
    var fs = _FaultStore()
    var empty = _manifest(fs, _prefix("e", 0))
    var p0 = RetentionPass[_FaultStore](RetentionPolicy.time_based(Int64(10)))
    var r0 = p0.run_with_rollout_audit(empty, Int64(100), m)
    assert_equal(r0.tombstoned_count, Int64(0))
    assert_equal(m.contiguity_clean_runs(), Int64(1))
    var core = _core(fs, "t", 0)
    for i in range(3):
        core.buffer_batch(_batch(Int64(2 * i), 2), Int64(1000 * (i + 1)))
        _ = core.flush(Int64(1000 * (i + 1)))
    var man = _manifest(fs, _prefix("t", 0))
    var quiet = RetentionPass[_FaultStore](RetentionPolicy.disabled())
    var r1 = quiet.run_with_rollout_audit(man, Int64(9000), m)
    assert_equal(r1.tombstoned_count, Int64(0))
    assert_false(r1.advanced_log_start)
    assert_equal(m.contiguity_clean_runs(), Int64(2))
    # At t=2100 only chunk 0 (t=1000) is past 500 ms: chunk 1 is the new
    # first live chunk.
    var timed = RetentionPass[_FaultStore](RetentionPolicy.time_based(Int64(500)))
    var r2 = timed.run_with_rollout_audit(man, Int64(2100), m)
    assert_equal(r2.tombstoned_count, Int64(1))
    assert_equal(r2.new_log_start_seq, Int64(1))
    assert_equal(r2.new_log_start_offset, Int64(2))
    assert_true(r2.advanced_log_start)
    # At t=2600 chunk 1 goes too: the active chunk 2 is the first live one.
    var r3 = timed.run_with_rollout_audit(man, Int64(2600), m)
    assert_equal(r3.tombstoned_count, Int64(1))
    assert_equal(r3.new_log_start_seq, Int64(2))
    assert_equal(r3.new_log_start_offset, Int64(4))
    assert_true(r3.advanced_log_start)
    assert_equal(m.contiguity_clean_runs(), Int64(4))
    assert_equal(m.contiguity_violations(), Int64(0))


# ---- 4. defaults, copy, estimate ----------------------------------------------------------------


def test_defaults_copy_and_estimate() raises:
    var sp = AutoSplitPolicy.default()
    assert_equal(sp.split_threshold_records, DEFAULT_SPLIT_THRESHOLD_RECORDS)
    assert_equal(sp.max_partitions, DEFAULT_MAX_PARTITIONS)
    var mp = AutoMergePolicy.default()
    assert_equal(mp.merge_threshold_records, DEFAULT_MERGE_THRESHOLD_RECORDS)
    assert_equal(mp.min_partitions, 1)
    assert_false(mp.allow_recently_split)
    var m = PartitionMap.auto_seed().split_at(0, Int64(3))
    var c = m.copy()
    assert_equal(c.version, m.version)
    assert_equal(c.next_pid, m.next_pid)
    assert_equal(len(c.ranges), 2)
    assert_equal(len(c.retired), 1)
    assert_equal(c.retired[0].frozen_at_offset, Int64(3))
    var it = BrokerProduceItem(_batch(Int64(0), 5), Int64(7))
    var codec = BrokerSegCodec("c", "t", Int64(0), "b", Int64(1), Int64(7))
    assert_equal(codec.estimate_bytes(it), len(it.frame_bytes))
    assert_true(codec.estimate_bytes(it) > 5 * 8)


def main() raises:
    # The metrics set is built before anything else allocates: building one
    # in a reused heap block hangs (komira-ai/komira#1072).
    var m = SubLineageRolloutMetrics()
    test_retention_with_rollout_audit(m)
    test_consumer_source_edge()
    test_merge_maintenance_scan()
    test_defaults_copy_and_estimate()
    print("[OK] test_cov_maintenance_surfaces_unit")
