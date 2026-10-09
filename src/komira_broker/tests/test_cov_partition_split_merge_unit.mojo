# =============================================================================
# tests/test_cov_partition_split_merge_unit.mojo
#   The split / merge orchestrations under map contention and concurrent
#   scale events, the lineage read order for prefix generations, merges and a
#   malformed cyclic lineage, the child-boundary recovery, and both lineage
#   compactions' refusals, races and lost CAS.
# =============================================================================
#
#   1. split_topic / merge_topic give up after max_cas_attempts lost CAS.
#   2. split_topic_if_live / merge_topic_if_eligible: a concurrent event that
#      retires the pid between the liveness read and the split is a clean
#      None; any other error propagates.
#   3. build_lineage_read_order: a prefix-generation step precedes its live
#      step; a merged child sorts after the deeper predecessor; a cyclic
#      lineage terminates.
#   4. _child_boundary: from child A, from child B when A re-split, from the
#      tombstone when both did, and a refusal when nothing is left.
#   5. compact_split_parent_gen: a merge predecessor is refused; a collapse
#      landed by someone else between the read and the CAS is reported as
#      collapsed at that map's version.
#   6. compact_split_parent: refusals, the rows split across the children,
#      a concurrent collapse, and a lost CAS reported as collapsed=False.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore
from komira_broker.partition_compaction import (
    _child_boundary,
    compact_split_parent,
    compact_split_parent_gen,
)
from komira_broker.partition_map import (
    HashRange,
    PARTITION_MODE_AUTO,
    PartitionMap,
    RetiredRange,
    persist_create_if_absent,
    prefix_gen_manifest_prefix,
    read_partition_map,
)
from komira_broker.partition_merge import merge_topic, merge_topic_if_eligible
from komira_broker.partition_split import (
    build_lineage_read_order,
    split_topic,
    split_topic_if_live,
)
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


comptime _PRE = "precondition (412) injected"
comptime _MAP = "partition_map.json"
comptime _STAGE = "stage/map"


def _prefix(pid: Int) -> String:
    return "c/_meta/topics/t/" + String(pid)


def _manifest(fs: _FaultStore, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _core(fs: _FaultStore, prefix: String, pid: Int) -> BrokerCore[_FaultStore]:
    return BrokerCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=_manifest(fs, prefix),
        cluster=String("c"),
        topic=String("t"),
        partition=Int64(pid),
        broker_id=String("b"),
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


def _stage(fs: _FaultStore, m: PartitionMap) raises:
    _ = fs.inner.put(Path.parse(_STAGE), m.encode())


def _map(fs: _FaultStore) raises -> PartitionMap:
    return read_partition_map(fs, "c", "t")


def _seeded(rows: Int) raises -> _FaultStore:
    """An auto topic; pid 0 holds `rows` rows (values 0..rows-1) in one
    chunk, then splits into 1 and 2."""
    var fs = _FaultStore()
    persist_create_if_absent(fs, "c", "t", PartitionMap.auto_seed())
    if rows > 0:
        var core = _core(fs, _prefix(0), 0)
        _ = core.produce(_batch(Int64(0), rows), Int64(1000))
        _ = core.flush_if_buffered(Int64(1001))
    _ = split_topic(fs, "c", "t", _manifest(fs, _prefix(0)), 0)
    return fs^


# ---- 1. lost CAS ----------------------------------------------------------------


def test_split_and_merge_give_up_on_lost_cas() raises:
    var fs = _FaultStore()
    persist_create_if_absent(fs, "c", "t", PartitionMap.auto_seed())
    fs.arm("cas", _MAP, 0, -1, _PRE)
    with assert_raises(contains="split_topic: CAS lost 3 times for pid 0"):
        _ = split_topic(fs, "c", "t", _manifest(fs, _prefix(0)), 0, 3)
    fs.disarm("cas")
    _ = split_topic(fs, "c", "t", _manifest(fs, _prefix(0)), 0)
    fs.arm("cas", _MAP, 0, -1, _PRE)
    with assert_raises(contains="merge_topic: CAS lost 2 times for pids 1+2"):
        _ = merge_topic(
            fs, "c", "t", _manifest(fs, _prefix(1)), _manifest(fs, _prefix(2)),
            1, 2, 2,
        )
    fs.disarm("cas")
    assert_equal(_map(fs).num_partitions(), 2)


# ---- 2. concurrent scale events ---------------------------------------------------


def test_split_if_live_race_and_errors() raises:
    var fs = _FaultStore()
    persist_create_if_absent(fs, "c", "t", PartitionMap.auto_seed())
    # Someone else's split lands between our liveness read and our split.
    _stage(fs, PartitionMap.auto_seed().split_at(0, Int64(0)))
    fs.arm("head", _MAP, 1, 1, "@copy:" + _STAGE)
    var r = split_topic_if_live(fs, "c", "t", _manifest(fs, _prefix(0)), 0)
    assert_false(r)
    assert_equal(_map(fs).num_partitions(), 2)
    # A store error is not a race: it propagates.
    fs.arm("cas", _MAP, 0, 1, "boom: map write")
    with assert_raises(contains="boom: map write"):
        _ = split_topic_if_live(fs, "c", "t", _manifest(fs, _prefix(1)), 1)
    assert_equal(_map(fs).num_partitions(), 2)


def test_merge_if_eligible_race_and_errors() raises:
    var fs = _FaultStore()
    persist_create_if_absent(fs, "c", "t", PartitionMap.auto_seed())
    _ = split_topic(fs, "c", "t", _manifest(fs, _prefix(0)), 0)
    _stage(fs, _map(fs).merge(1, 2))
    fs.arm("head", _MAP, 1, 1, "@copy:" + _STAGE)
    var r = merge_topic_if_eligible(
        fs, "c", "t", _manifest(fs, _prefix(1)), _manifest(fs, _prefix(2)), 1, 2
    )
    assert_false(r)
    assert_equal(_map(fs).num_partitions(), 1)
    # Split the merged child again, then fail the merge's map write.
    _ = split_topic(fs, "c", "t", _manifest(fs, _prefix(3)), 3)
    fs.arm("cas", _MAP, 0, 1, "boom: merge write")
    with assert_raises(contains="boom: merge write"):
        _ = merge_topic_if_eligible(
            fs, "c", "t", _manifest(fs, _prefix(4)), _manifest(fs, _prefix(5)),
            4, 5,
        )
    assert_equal(_map(fs).num_partitions(), 2)


# ---- 3. lineage read order --------------------------------------------------------


def test_lineage_read_order_shapes() raises:
    # Child 1 carries a prefix generation, child 2 none.
    var pg = PartitionMap.auto_seed().split_at(0, Int64(0))
    pg = pg.collapse_lineage_with_prefix_gen(0, Int64(7), Int64(-1))
    var s = build_lineage_read_order(pg)
    assert_equal(len(s), 3)
    assert_equal(s[0].pid, 1)
    assert_true(s[0].is_prefix_gen)
    assert_equal(s[0].prefix_gen_seq, Int64(7))
    assert_equal(s[1].pid, 1)
    assert_false(s[1].is_prefix_gen)
    assert_equal(s[2].pid, 2)
    assert_false(s[2].is_prefix_gen)
    # 0 -> (1, 2), 2 -> (3, 4), merge(1, 3) -> 5: 5 sorts after its deeper
    # predecessor 3 (depth 2), at depth 3.
    var m = PartitionMap.auto_seed().split_at(0, Int64(0)).split_at(2, Int64(0))
    m = m.merge(1, 3)
    var o = build_lineage_read_order(m)
    var last = len(o) - 1
    assert_equal(o[last].pid, 5)
    assert_equal(o[last].depth, 3)
    # A malformed cyclic lineage (1 and 2 each the other's child) terminates.
    var ranges = List[HashRange]()
    ranges.append(HashRange.original(UInt64(0), UInt64.MAX, 5))
    var retired = List[RetiredRange]()
    retired.append(RetiredRange.split_parent(1, UInt64(0), UInt64.MAX, Int64(0), 2, 3))
    retired.append(RetiredRange.split_parent(2, UInt64(0), UInt64.MAX, Int64(0), 1, 4))
    var cyc = PartitionMap(
        version=1, mode=PARTITION_MODE_AUTO, ranges=ranges^, next_pid=6,
        retired=retired^,
    )
    assert_equal(len(build_lineage_read_order(cyc)), 3)


# ---- 4. the child boundary -----------------------------------------------------------


def test_child_boundary_recovery() raises:
    var m = PartitionMap.auto_seed().split_at(0, Int64(0))
    var mid = _child_boundary(m, 0, 1, 2)
    assert_equal(mid, m.ranges[0].hash_hi)
    # Child A re-split: read child B's lower bound.
    var a_gone = m.split_at(1, Int64(0))
    assert_equal(_child_boundary(a_gone, 0, 1, 2), mid)
    # Both re-split: recover from the parent tombstone's midpoint.
    var both = a_gone.split_at(2, Int64(0))
    assert_equal(_child_boundary(both, 0, 1, 2), mid)
    with assert_raises(contains="cannot recover the child subrange boundary for parent 9"):
        _ = _child_boundary(both, 9, 10, 11)


# ---- 5. compact_split_parent_gen -------------------------------------------------------


def _gen_core(fs: _FaultStore, child: Int, parent: Int) -> BrokerCore[_FaultStore]:
    return _core(fs, prefix_gen_manifest_prefix("c", "t", child, Int64(parent)), child)


def test_gen_compaction_refusal_and_concurrent_collapse() raises:
    var fs = _seeded(20)
    # Merge the children: 1 and 2 become merge predecessors of 3.
    var fm = _FaultStore()
    persist_create_if_absent(fm, "c", "t", PartitionMap.auto_seed())
    _ = split_topic(fm, "c", "t", _manifest(fm, _prefix(0)), 0)
    _ = merge_topic(fm, "c", "t", _manifest(fm, _prefix(1)), _manifest(fm, _prefix(2)), 1, 2)
    with assert_raises(contains="compact_split_parent_gen: pid 1 is a MERGE predecessor"):
        _ = compact_split_parent_gen(
            fm, "c", "t", Slab[RecordBatch](), _gen_core(fm, 1, 1),
            _gen_core(fm, 2, 1), _manifest(fm, _prefix(1)), 1,
        )
    # Someone else's collapse lands between our first read and our CAS.
    var landed = _map(fs).collapse_lineage_with_prefix_gen(0, Int64(0), Int64(0))
    _stage(fs, landed)
    fs.arm("head", _MAP, 1, 1, "@copy:" + _STAGE)
    var batches = Slab[RecordBatch]()
    batches.append(_batch(Int64(0), 20))
    var res = compact_split_parent_gen(
        fs, "c", "t", batches^, _gen_core(fs, 1, 0), _gen_core(fs, 2, 0),
        _manifest(fs, _prefix(0)), 0, Int64(5),
    )
    assert_true(res.collapsed)
    assert_equal(res.new_version, landed.version)
    assert_equal(res.rows_to_a + res.rows_to_b, 20)
    assert_equal(len(_map(fs).retired), 0)


# ---- 6. compact_split_parent ------------------------------------------------------------


def _live_count(fs: _FaultStore, pid: Int) raises -> Int64:
    var c = ConsumeCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=_manifest(fs, _prefix(pid)),
        cluster=String("c"),
        topic=String("t"),
        partition=Int64(pid),
    )
    return c.next_offset()


def test_compact_split_parent() raises:
    var fs = _seeded(30)
    with assert_raises(contains="compact_split_parent: pid 7 is not a retired partition"):
        _ = compact_split_parent(
            fs, "c", "t", Slab[RecordBatch](), _core(fs, _prefix(1), 1),
            _core(fs, _prefix(2), 2), 7,
        )
    var fm = _FaultStore()
    persist_create_if_absent(fm, "c", "t", PartitionMap.auto_seed())
    _ = split_topic(fm, "c", "t", _manifest(fm, _prefix(0)), 0)
    _ = merge_topic(fm, "c", "t", _manifest(fm, _prefix(1)), _manifest(fm, _prefix(2)), 1, 2)
    with assert_raises(contains="compact_split_parent: pid 2 is a MERGE predecessor"):
        _ = compact_split_parent(
            fm, "c", "t", Slab[RecordBatch](), _core(fm, _prefix(1), 1),
            _core(fm, _prefix(2), 2), 2,
        )
    # A lost CAS on every attempt: rows land, the lineage stays.
    fs.arm("cas", _MAP, 0, -1, _PRE)
    var batches = Slab[RecordBatch]()
    batches.append(_batch(Int64(0), 30))
    var lost = compact_split_parent(
        fs, "c", "t", batches^, _core(fs, _prefix(1), 1), _core(fs, _prefix(2), 2),
        0, Int64(5), 2,
    )
    fs.disarm("cas")
    assert_false(lost.collapsed)
    assert_equal(lost.rows_to_a + lost.rows_to_b, 30)
    assert_true(lost.rows_to_a > 0)
    assert_true(lost.rows_to_b > 0)
    assert_equal(lost.new_version, _map(fs).version)
    assert_equal(_live_count(fs, 1), Int64(lost.rows_to_a))
    assert_equal(_live_count(fs, 2), Int64(lost.rows_to_b))
    assert_equal(len(_map(fs).retired), 1)
    # Nothing to move, and the collapse lands.
    var done = compact_split_parent(
        fs, "c", "t", Slab[RecordBatch](), _core(fs, _prefix(1), 1),
        _core(fs, _prefix(2), 2), 0,
    )
    assert_true(done.collapsed)
    assert_equal(done.rows_to_a, 0)
    assert_equal(done.new_version, _map(fs).version)
    assert_equal(len(_map(fs).retired), 0)
    assert_equal(_live_count(fs, 1), Int64(lost.rows_to_a))
    # A collapse someone else landed between the two reads.
    var fs2 = _seeded(4)
    var landed = _map(fs2).collapse_lineage(0)
    _stage(fs2, landed)
    fs2.arm("head", _MAP, 1, 1, "@copy:" + _STAGE)
    var b2 = Slab[RecordBatch]()
    b2.append(_batch(Int64(0), 4))
    var raced = compact_split_parent(
        fs2, "c", "t", b2^, _core(fs2, _prefix(1), 1), _core(fs2, _prefix(2), 2), 0
    )
    assert_true(raced.collapsed)
    assert_equal(raced.new_version, landed.version)


def main() raises:
    test_split_and_merge_give_up_on_lost_cas()
    test_split_if_live_race_and_errors()
    test_merge_if_eligible_race_and_errors()
    test_lineage_read_order_shapes()
    test_child_boundary_recovery()
    test_gen_compaction_refusal_and_concurrent_collapse()
    test_compact_split_parent()
    print("[OK] test_cov_partition_split_merge_unit")
