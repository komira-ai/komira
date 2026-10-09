# =============================================================================
# tests/test_cov_partition_map_unit.mojo
#   PartitionMap: routing and validation over malformed maps, the split and
#   merge refusals, collapsing one lineage level while keeping the others,
#   the JSON decoder's refusals and its pre-lineage next_pid derivation, and
#   the create-if-absent error arm.
# =============================================================================
#
#   1. range_containing_pid refuses an empty map and a hash below every
#      range; validate names each broken invariant.
#   2. split refuses a width-1 range; merge refuses a pid that is not live
#      (either side) and two ranges that do not touch.
#   3. collapse_lineage / collapse_lineage_with_prefix_gen on the inner of
#      two nested splits keep the outer split's range and tombstone as they
#      are; the prefix-gen variant refuses a pid that never split.
#   4. decode: a map written before next_pid existed derives it from every
#      pid it names; spaces before numbers; each missing field and each
#      non-number is refused; an unterminated ranges array still parses.
#   5. persist_create_if_absent swallows a 412 but not any other error.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_broker.partition_map import (
    HashRange,
    PARTITION_MODE_AUTO,
    PartitionMap,
    RetiredRange,
    _bytes_find,
    persist_create_if_absent,
    read_partition_map,
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


comptime _MAX = "18446744073709551615"


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _auto(var ranges: List[HashRange]) -> PartitionMap:
    return PartitionMap(version=1, mode=PARTITION_MODE_AUTO, ranges=ranges^)


# ---- 1. routing and validation over malformed maps --------------------------------


def test_routing_and_validate_refusals() raises:
    var empty = _auto(List[HashRange]())
    with assert_raises(contains="range_containing_pid: empty map (no ranges)"):
        _ = empty.range_containing_pid(UInt64(1))
    with assert_raises(contains="PartitionMap.validate: empty map (no ranges)"):
        empty.validate()
    var r1 = List[HashRange]()
    r1.append(HashRange.original(UInt64(10), UInt64.MAX, 0))
    var high = _auto(r1^)
    with assert_raises(contains="hash 5 fell outside the covered range space"):
        _ = high.range_containing_pid(UInt64(5))
    with assert_raises(contains="first range hash_lo != 0 (got 10)"):
        high.validate()
    var r2 = List[HashRange]()
    r2.append(HashRange.original(UInt64(0), UInt64(10), 0))
    r2.append(HashRange.original(UInt64(20), UInt64.MAX, 1))
    var gap = _auto(r2^)
    with assert_raises(contains="gap/overlap between range 0 (hi=10) and range 1 (lo=20)"):
        gap.validate()
    var r3 = List[HashRange]()
    r3.append(HashRange.original(UInt64(0), UInt64(0), 0))
    r3.append(HashRange.original(UInt64(0), UInt64.MAX, 1))
    with assert_raises(contains="non-positive-width range 0"):
        _auto(r3^).validate()
    var r4 = List[HashRange]()
    r4.append(HashRange.original(UInt64(0), UInt64(7), 0))
    with assert_raises(contains="last range hash_hi != UInt64.MAX"):
        _auto(r4^).validate()


# ---- 2. split and merge refusals ----------------------------------------------------


def test_split_and_merge_refusals() raises:
    var r = List[HashRange]()
    r.append(HashRange.original(UInt64(0), UInt64(1), 0))
    r.append(HashRange.original(UInt64(1), UInt64.MAX, 1))
    var narrow = _auto(r^)
    with assert_raises(contains="range [lo=0, hi=1) for pid 0 is too narrow to split"):
        _ = narrow.split(0)
    # Width 2 splits into two width-1 children.
    var r2 = List[HashRange]()
    r2.append(HashRange.original(UInt64(0), UInt64(2), 0))
    r2.append(HashRange.original(UInt64(2), UInt64.MAX, 1))
    var two = _auto(r2^).split(0)
    assert_equal(two.num_partitions(), 3)
    with assert_raises(contains="PartitionMap.merge: pid_a 5 is not a LIVE partition"):
        _ = narrow.merge(5, 1)
    with assert_raises(contains="PartitionMap.merge: pid_b 5 is not a LIVE partition"):
        _ = narrow.merge(0, 5)
    var g = List[HashRange]()
    g.append(HashRange.original(UInt64(0), UInt64(10), 0))
    g.append(HashRange.original(UInt64(20), UInt64.MAX, 1))
    with assert_raises(contains="ranges for pids 0 / 1 are not contiguous"):
        _ = _auto(g^).merge(0, 1)


# ---- 3. collapsing one of two nested lineages -----------------------------------------


def test_collapse_inner_lineage_keeps_outer() raises:
    # 0 -> (1, 2), then 1 -> (3, 4): retired [0, 1]; live 3, 4 (parent 1), 2
    # (parent 0).
    var m = PartitionMap.auto_seed().split_at(0, Int64(5)).split_at(1, Int64(2))
    assert_equal(len(m.retired), 2)
    var c = m.collapse_lineage(1)
    assert_equal(c.version, m.version + 1)
    assert_equal(len(c.retired), 1)
    assert_equal(c.retired[0].pid, 0)
    for i in range(len(c.ranges)):
        if c.ranges[i].pid == 2:
            assert_equal(c.ranges[i].parent_pid, 0)
            assert_equal(c.ranges[i].parent_split_offset, Int64(5))
        else:
            assert_equal(c.ranges[i].parent_pid, -1)
    var pg = m.collapse_lineage_with_prefix_gen(1, Int64(11), Int64(12))
    assert_equal(len(pg.retired), 1)
    assert_equal(pg.retired[0].pid, 0)
    for i in range(len(pg.ranges)):
        ref r = pg.ranges[i]
        if r.pid == 2:
            assert_equal(r.parent_pid, 0)
            assert_equal(r.prefix_gen_seq, Int64(-1))
        elif r.pid == 3:
            assert_equal(r.prefix_gen_seq, Int64(11))
        else:
            assert_equal(r.pid, 4)
            assert_equal(r.prefix_gen_seq, Int64(12))
    with assert_raises(contains="collapse_lineage_with_prefix_gen: pid 7 is not a SPLIT-parent"):
        _ = m.collapse_lineage_with_prefix_gen(7, Int64(1), Int64(1))


# ---- 4. decode ------------------------------------------------------------------------


def test_decode_pre_lineage_and_refusals() raises:
    # No next_pid: derived as one past the largest pid named anywhere (a
    # range pid, a split child, a merge target).
    var legacy = (
        '{"version": 3,"mode":"auto","ranges":[{"lo": 0,"hi":100,"pid":3},'
        + '{"lo":100,"hi":' + _MAX + ',"pid":4}],"retired":['
        + '{"rpid":0,"rlo":0,"rhi":' + _MAX + ',"rfoff":5,"rca":7,"rcb":8,"rmi":-1},'
        + '{"rpid":1,"rlo":0,"rhi":9,"rfoff":1,"rca":2,"rcb":2,"rmi":9}]}'
    )
    var m = PartitionMap.decode(_bytes_of(legacy))
    assert_equal(m.version, 3)
    assert_equal(m.next_pid, 10)
    assert_equal(len(m.retired), 2)
    assert_equal(m.ranges[1].hash_hi, UInt64.MAX)
    var only_ranges = PartitionMap.decode(
        _bytes_of(
            '{"version":1,"mode":"auto","ranges":[{"lo":0,"hi":' + _MAX
            + ',"pid":6}]}'
        )
    )
    assert_equal(only_ranges.next_pid, 7)
    # An unterminated ranges array runs to the end of the text.
    var open = PartitionMap.decode(
        _bytes_of('{"version":1,"mode":"auto","ranges":[{"lo":0,"hi":' + _MAX + ',"pid":0}')
    )
    assert_equal(open.num_partitions(), 1)
    with assert_raises(contains="PartitionMap.decode: missing 'version' field"):
        _ = PartitionMap.decode(_bytes_of('{"mode":"auto","ranges":[]}'))
    with assert_raises(contains="PartitionMap.decode: missing 'mode' field"):
        _ = PartitionMap.decode(_bytes_of('{"version":1,"ranges":[]}'))
    with assert_raises(contains="PartitionMap.decode: missing 'ranges' field"):
        _ = PartitionMap.decode(_bytes_of('{"version":1,"mode":"auto"}'))
    with assert_raises(contains="PartitionMap.decode: no ranges parsed"):
        _ = PartitionMap.decode(_bytes_of('{"version":1,"mode":"auto","ranges":[]}'))
    with assert_raises(contains="PartitionMap.decode: range missing 'hi'"):
        _ = PartitionMap.decode(
            _bytes_of('{"version":1,"mode":"auto","ranges":[{"lo":0,"pid":0}]}')
        )
    with assert_raises(contains="PartitionMap.decode: range missing 'pid'"):
        _ = PartitionMap.decode(
            _bytes_of('{"version":1,"mode":"auto","ranges":[{"lo":0,"hi":1}]}')
        )
    with assert_raises(contains="PartitionMap.decode: retired entry missing a field"):
        _ = PartitionMap.decode(
            _bytes_of(
                '{"version":1,"mode":"auto","ranges":[{"lo":0,"hi":' + _MAX
                + ',"pid":0}],"retired":[{"rpid":4}]}'
            )
        )
    with assert_raises(contains="PartitionMap.decode: expected integer at 11"):
        _ = PartitionMap.decode(_bytes_of('{"version":x,"mode":"auto","ranges":[]}'))
    with assert_raises(contains="PartitionMap.decode: expected unsigned integer at"):
        _ = PartitionMap.decode(
            _bytes_of('{"version":1,"mode":"auto","ranges":[{"lo":-1,"hi":1,"pid":0}]}')
        )
    assert_equal(_bytes_find(_bytes_of("abc"), List[UInt8](), 1), 1)


# ---- 5. create-if-absent ---------------------------------------------------------------


def test_persist_create_if_absent_errors() raises:
    var fs = _FaultStore()
    persist_create_if_absent(fs, "c", "t", PartitionMap.fixed(2))
    # A second create loses with 412: swallowed, the first map stays.
    persist_create_if_absent(fs, "c", "t", PartitionMap.fixed(3))
    assert_equal(read_partition_map(fs, "c", "t").num_partitions(), 2)
    fs.arm("cput", "partition_map", 0, 1, "boom: create")
    with assert_raises(contains="boom: create"):
        persist_create_if_absent(fs, "c", "u", PartitionMap.fixed(2))


def main() raises:
    test_routing_and_validate_refusals()
    test_split_and_merge_refusals()
    test_collapse_inner_lineage_keeps_outer()
    test_decode_pre_lineage_and_refusals()
    test_persist_create_if_absent_errors()
    print("[OK] test_cov_partition_map_unit")
