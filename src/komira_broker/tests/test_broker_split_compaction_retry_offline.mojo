# =============================================================================
# tests/test_broker_split_compaction_retry_offline.mojo
#   compact_split_parent_gen fails at each step, is re-run, and ends in the
#   state a run without a failure leaves — OFFLINE
# =============================================================================
#
# Every test builds the same topic twice in two fresh in-memory stores: an
# auto-seeded map, parent pid 0 with 3 chunks of 10 rows (values 0..29), the
# parent split into children 1 and 2. The REFERENCE store runs
# `compact_split_parent_gen` once with no fault. The FAULT store arms one
# failure, runs it (it raises, or returns `collapsed=False`), disarms, and
# runs it again until it reports the collapse. Both then reap the parent past
# grace, and `_state` must be byte-equal: the map (version, ranges, prefix-gen
# seqs, retired count), every manifest key (chunks, tombstones, `_LOG_START`),
# each manifest's authoritative tail and log start, and every `.seg` object
# named by the chunk that references it (an unreferenced one prints as
# ORPHAN). One more run must change nothing.
#
#   (1) step 3: child B's prefix-generation `.seg` PUT fails after child A's
#       append landed. Catches: a re-run that appends A's rows again (A's
#       prefix generation would hold 2 chunks and twice the rows).
#   (2) step 4: the collapse CAS is lost on every attempt (`collapsed=False`).
#       Catches: the same double append on the re-run the result invites.
#   (3) step 4: the map write fails with a transport error (raised). Catches:
#       the same double append, from a crash between steps 3 and 4.
#   (4) step 5: the parent's `_LOG_START` advance fails after the collapse.
#   (5) step 5: the tombstone of parent chunk 1 fails after the advance.
#       (4) and (5) catch a resume path that does not finish step 5: the
#       parent's chunks and `.seg`s would survive the reap.
#   (6) step 5 fails for a parent with no visible rows (both children get
#       none, so no live range carries a generation token). Catches: a resume
#       that recognises a collapsed parent by that token (the re-run raised
#       "is not a retired partition" and the parent leaked).
#   (7) step 5 fails and both children split again before the re-run (they
#       are no longer live ranges). Catches: the same token-based resume.
#
# A never-allocated pid and a live pid are still refused, with the exact
# message (8).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.manifest_body import ManifestBody
from komira_broker.partition_compaction import compact_split_parent_gen
from komira_broker.partition_map import (
    PartitionMap,
    partition_map_key,
    persist_create_if_absent,
    prefix_gen_manifest_prefix,
    read_partition_map_with_etag,
)
from komira_broker.partition_split import split_topic
from komira_broker.retention import ReapWorker

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
comptime _FAIL_PUT = "__fault__/put/"
comptime _FAIL_PUT_UNDER = "__fault__/put_under/"
comptime _LOSE_CAS = "__fault__/412/"
comptime _GRACE = Int64(60_000)
comptime _NOW = Int64(50_000)
comptime _CLUSTER = "splitretry"
comptime _TOPIC = "t"
comptime _FAULT_MSG = "injected fault: transport error status=503"


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
    """Delegates every verb to a shared in-memory store. Rules are marker
    objects in that store, so every clone sees them: `_FAIL_PUT + key` fails
    every write of `key`, `_FAIL_PUT_UNDER + prefix` every write of a key
    under `prefix` (raising `_FAULT_MSG`), `_LOSE_CAS + key` makes every
    conditional write of `key` lose its precondition."""

    var _inner: _Inner

    def __init__(out self, var inner: _Inner):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def _before_put(self, path: Path) raises:
        var raw = path.raw()
        if _has(self._inner, _FAIL_PUT + raw):
            raise Error(String(_FAULT_MSG))
        var rules = self._inner.list_with_delimiter(
            Path.parse(String(_FAIL_PUT_UNDER))
        )
        # A rule `_FAIL_PUT_UNDER + p` covers `raw` iff `raw` starts with `p`.
        var ruled = String(_FAIL_PUT_UNDER) + raw
        for i in range(len(rules.objects)):
            if ruled.startswith(rules.objects[i].location):
                raise Error(String(_FAULT_MSG))

    def _lost(self, path: Path) -> Bool:
        return _has(self._inner, _LOSE_CAS + path.raw())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._before_put(path)
        if self._lost(path):
            raise Error("injected: precondition (412) — a concurrent writer won")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._before_put(path)
        if self._lost(path):
            raise Error("injected: precondition (412) — a concurrent writer won")
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


# =============================================================================
# The topic, the compaction run, the reap
# =============================================================================


def _prefix(pid: Int) -> String:
    return String(_CLUSTER) + "/_meta/topics/" + String(_TOPIC) + "/" + String(pid)


def _gen_prefix(child: Int) -> String:
    return prefix_gen_manifest_prefix(
        String(_CLUSTER), String(_TOPIC), child, Int64(0)
    )


def _manifest_at(inner: _Inner, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=_FaultStore(inner.clone()),
        prefix=prefix,
        retry=RetryPolicy.fast_test(),
    )


def _core(inner: _Inner, prefix: String, pid: Int) -> BrokerCore[_FaultStore]:
    return BrokerCore[_FaultStore](
        segment_store=_FaultStore(inner.clone()),
        manifest=_manifest_at(inner, prefix),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(pid),
        broker_id=String("broker-A"),
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


def _split(inner: _Inner, pid: Int) raises:
    _ = split_topic[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        _manifest_at(inner, _prefix(pid)),
        pid,
    )


def _setup(inner: _Inner) raises:
    """Parent pid 0: 3 chunks of 10 rows (values 0..29), split into 1 and 2."""
    persist_create_if_absent[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        PartitionMap.auto_seed(),
    )
    var broker = _core(inner, _prefix(0), 0)
    for i in range(3):
        var ts = Int64(1000) + Int64(i) * Int64(1000)
        _ = broker.produce(_batch(Int64(i * 10), 10), ts)
        _ = broker.flush_if_buffered(ts)
    _ = broker^
    _split(inner, 0)


def _compact(inner: _Inner, pid: Int, visible_rows: Int) raises -> Bool:
    """One `compact_split_parent_gen` run of `pid` (children 1 and 2) over
    the parent's first `visible_rows` rows; its `collapsed`."""
    var batches = Slab[RecordBatch]()
    if visible_rows > 0:
        batches.append(_batch(Int64(0), visible_rows))
    var res = compact_split_parent_gen[_FaultStore](
        _FaultStore(inner.clone()),
        String(_CLUSTER),
        String(_TOPIC),
        batches^,
        _core(inner, _gen_prefix(1), 1),
        _core(inner, _gen_prefix(2), 2),
        _manifest_at(inner, _prefix(pid)),
        pid,
        _NOW,
    )
    return res.collapsed


def _compact_raises(inner: _Inner, visible_rows: Int) raises -> String:
    """A run of pid 0 that must raise; the error text."""
    try:
        _ = _compact(inner, 0, visible_rows)
    except e:
        return String(e)
    raise Error("compact_split_parent_gen did not raise")


def _reap_parent(inner: _Inner) raises:
    var seg_store = _FaultStore(inner.clone())
    var m = _manifest_at(inner, _prefix(0))
    var w = ReapWorker[_FaultStore](_GRACE)
    _ = w.run(seg_store, m, _NOW + _GRACE)
    _ = m^


# =============================================================================
# The compared state
# =============================================================================


def _sorted(var xs: List[String]) -> List[String]:
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j] < xs[j - 1]:
            xs.swap_elements(j, j - 1)
            j -= 1
    return xs^


def _state(inner: _Inner) raises -> String:
    var out = String()
    var cur = read_partition_map_with_etag[_FaultStore](
        _FaultStore(inner.clone()), String(_CLUSTER), String(_TOPIC)
    )
    out += "map v=" + String(cur.map.version) + " next=" + String(cur.map.next_pid)
    out += " retired=" + String(len(cur.map.retired)) + "\n"
    for i in range(len(cur.map.ranges)):
        ref r = cur.map.ranges[i]
        out += "  range pid=" + String(r.pid) + " parent=" + String(r.parent_pid)
        out += " gen=" + String(r.prefix_gen_seq) + "\n"

    # Every manifest the run writes or reads; which chunk names each `.seg`.
    var prefixes: List[String] = [
        _prefix(0), _gen_prefix(1), _gen_prefix(2), _prefix(1), _prefix(2)
    ]
    var seg_keys = List[String]()
    var seg_refs = List[String]()
    for pi in range(len(prefixes)):
        var m = _manifest_at(inner, prefixes[pi])
        var h = m.read_head_authoritative()
        var ls = m.read_log_start()
        out += "manifest " + prefixes[pi] + " top=" + String(h.chunk_seq)
        out += " next=" + String(h.next_offset)
        out += " log_start=" + String(ls.log_start_seq) + "@"
        out += String(ls.log_start_offset) + "\n"
        for s in range(16):
            if _has(inner, chunk_key(prefixes[pi], Int64(s)).raw()):
                var body = ManifestBody.decode(m.read_chunk(Int64(s)))
                seg_keys.append(String(body.object_key))
                seg_refs.append(prefixes[pi] + "#" + String(s))

    # Every object, `.seg`s by their referencing chunk. `_HEAD` is the
    # best-effort tail cache; the tail itself is compared above.
    var lines = List[String]()
    var all = inner.list_with_delimiter(Path.parse(String(_CLUSTER) + "/"))
    for i in range(len(all.objects)):
        var k = all.objects[i].location.copy()
        if k.endswith("/_HEAD"):
            continue
        if k.endswith(".seg"):
            var named = String("ORPHAN ") + k
            for j in range(len(seg_keys)):
                if seg_keys[j] == k:
                    named = "seg of " + seg_refs[j]
            lines.append(named^)
        else:
            lines.append(k^)
    var keys = _sorted(lines^)
    for i in range(len(keys)):
        out += "  " + keys[i] + "\n"
    return out^


def _reference(visible_rows: Int, resplit: Bool) raises -> String:
    var inner = _Inner()
    _setup(inner)
    assert_true(_compact(inner, 0, visible_rows), "the reference collapses")
    if resplit:
        _split(inner, 1)
        _split(inner, 2)
    _reap_parent(inner)
    return _state(inner)


def _finish_and_compare(
    inner: _Inner, visible_rows: Int, expected: String, what: String
) raises:
    assert_true(_compact(inner, 0, visible_rows), what + ": the re-run collapses")
    _reap_parent(inner)
    var got = _state(inner)
    assert_equal(got, expected, what + ": the state of a run without a fault")
    assert_true(_compact(inner, 0, visible_rows), what + ": a further run")
    _reap_parent(inner)
    assert_equal(_state(inner), expected, what + ": a further run changes nothing")


# =============================================================================
# (1)-(3) a failure in steps 3-4: the re-run writes each row once
# =============================================================================


def test_step3_child_b_segment_put_fails() raises:
    print("[test_step3_child_b_segment_put_fails] starting...")
    var expected = _reference(30, False)
    var inner = _Inner()
    _setup(inner)
    var under = String(_CLUSTER) + "/topics/" + String(_TOPIC) + "/2/segments/"
    _arm(inner, _FAIL_PUT_UNDER, under)
    assert_equal(_compact_raises(inner, 30), String(_FAULT_MSG))
    _disarm(inner, _FAIL_PUT_UNDER, under)
    var a = _manifest_at(inner, _gen_prefix(1))
    var a_rows = a.read_head_authoritative().next_offset
    assert_true(a_rows > Int64(0), "child A's prefix generation had landed")
    _finish_and_compare(inner, 30, expected, "step 3")
    assert_equal(
        a.read_head_authoritative().next_offset, a_rows, "A's rows written once"
    )
    _ = a^
    print("[test_step3_child_b_segment_put_fails] PASS")


def test_step4_collapse_cas_lost_on_every_attempt() raises:
    print("[test_step4_collapse_cas_lost_on_every_attempt] starting...")
    var expected = _reference(30, False)
    var inner = _Inner()
    _setup(inner)
    var mk = partition_map_key(String(_CLUSTER), String(_TOPIC))
    _arm(inner, _LOSE_CAS, mk)
    assert_false(_compact(inner, 0, 30), "every collapse CAS lost")
    _disarm(inner, _LOSE_CAS, mk)
    _finish_and_compare(inner, 30, expected, "step 4 lost CAS")
    print("[test_step4_collapse_cas_lost_on_every_attempt] PASS")


def test_step4_map_write_fails() raises:
    print("[test_step4_map_write_fails] starting...")
    var expected = _reference(30, False)
    var inner = _Inner()
    _setup(inner)
    var mk = partition_map_key(String(_CLUSTER), String(_TOPIC))
    _arm(inner, _FAIL_PUT, mk)
    assert_equal(_compact_raises(inner, 30), String(_FAULT_MSG))
    _disarm(inner, _FAIL_PUT, mk)
    _finish_and_compare(inner, 30, expected, "step 4 map write")
    print("[test_step4_map_write_fails] PASS")


# =============================================================================
# (4)-(7) a failure in step 5, after the collapse: the re-run retires the parent
# =============================================================================


def test_step5_advance_fails() raises:
    print("[test_step5_advance_fails] starting...")
    var expected = _reference(30, False)
    var inner = _Inner()
    _setup(inner)
    var lk = log_start_key(_prefix(0)).raw()
    _arm(inner, _FAIL_PUT, lk)
    assert_equal(_compact_raises(inner, 30), String(_FAULT_MSG))
    _disarm(inner, _FAIL_PUT, lk)
    _finish_and_compare(inner, 30, expected, "step 5 advance")
    print("[test_step5_advance_fails] PASS")


def test_step5_tombstone_fails() raises:
    print("[test_step5_tombstone_fails] starting...")
    var expected = _reference(30, False)
    var inner = _Inner()
    _setup(inner)
    var tk = tombstone_key(_prefix(0), Int64(1)).raw()
    _arm(inner, _FAIL_PUT, tk)
    assert_equal(_compact_raises(inner, 30), String(_FAULT_MSG))
    _disarm(inner, _FAIL_PUT, tk)
    _finish_and_compare(inner, 30, expected, "step 5 tombstone")
    print("[test_step5_tombstone_fails] PASS")


def test_step5_fails_for_a_parent_with_no_visible_rows() raises:
    print("[test_step5_fails_for_a_parent_with_no_visible_rows] starting...")
    var expected = _reference(0, False)
    var inner = _Inner()
    _setup(inner)
    var lk = log_start_key(_prefix(0)).raw()
    _arm(inner, _FAIL_PUT, lk)
    assert_equal(_compact_raises(inner, 0), String(_FAULT_MSG))
    _disarm(inner, _FAIL_PUT, lk)
    _finish_and_compare(inner, 0, expected, "no visible rows")
    print("[test_step5_fails_for_a_parent_with_no_visible_rows] PASS")


def test_step5_fails_then_both_children_split() raises:
    print("[test_step5_fails_then_both_children_split] starting...")
    var expected = _reference(30, True)
    var inner = _Inner()
    _setup(inner)
    var lk = log_start_key(_prefix(0)).raw()
    _arm(inner, _FAIL_PUT, lk)
    assert_equal(_compact_raises(inner, 30), String(_FAULT_MSG))
    _disarm(inner, _FAIL_PUT, lk)
    _split(inner, 1)
    _split(inner, 2)
    _finish_and_compare(inner, 30, expected, "children split again")
    print("[test_step5_fails_then_both_children_split] PASS")


# =============================================================================
# (8) a pid that was never a split parent is refused
# =============================================================================


def test_unallocated_and_live_pids_are_refused() raises:
    print("[test_unallocated_and_live_pids_are_refused] starting...")
    var inner = _Inner()
    _setup(inner)
    var refused: List[Int] = [1, 3]
    for pid in refused:
        var msg = String()
        try:
            _ = _compact(inner, pid, 0)
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "compact_split_parent_gen: pid "
            + String(pid)
            + " is not a retired partition (nothing to compact)",
        )
    print("[test_unallocated_and_live_pids_are_refused] PASS")


def _run(name: String, test: def () raises thin -> None, mut failed: List[String]):
    try:
        test()
    except e:
        print("[" + name + "] FAIL: " + String(e))
        failed.append(name)


def main() raises:
    # Every test runs; the failures are listed together.
    var failed = List[String]()
    _run("step3_child_b_segment_put_fails", test_step3_child_b_segment_put_fails, failed)
    _run(
        "step4_collapse_cas_lost_on_every_attempt",
        test_step4_collapse_cas_lost_on_every_attempt,
        failed,
    )
    _run("step4_map_write_fails", test_step4_map_write_fails, failed)
    _run("step5_advance_fails", test_step5_advance_fails, failed)
    _run("step5_tombstone_fails", test_step5_tombstone_fails, failed)
    _run(
        "step5_fails_for_a_parent_with_no_visible_rows",
        test_step5_fails_for_a_parent_with_no_visible_rows,
        failed,
    )
    _run(
        "step5_fails_then_both_children_split",
        test_step5_fails_then_both_children_split,
        failed,
    )
    _run(
        "unallocated_and_live_pids_are_refused",
        test_unallocated_and_live_pids_are_refused,
        failed,
    )
    if len(failed) > 0:
        var names = String()
        for i in range(len(failed)):
            names += " " + failed[i]
        raise Error(String(len(failed)) + " failed:" + names)
