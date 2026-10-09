# =============================================================================
# tests/test_cov_producer_registry_unit.mojo
#   The idempotent-producer registry and dedupe rule, the transactional-id
#   binding, the read_committed snapshot, the manifest body decoder and the
#   assignment store: their pure rules and every store-error arm.
# =============================================================================
#
#   1. decide_sequence: each outcome of the dedupe rule, and the outcome names.
#   2. ProducerRegistry: ids are allocated in order, epochs bump by one, a
#      lost CAS is retried, the retry budget runs out with its message, and
#      any other store error (or a truncated body) propagates.
#   3. TxnIdRegistry: bind, re-bind reads back the first id, the reverse
#      binding, a truncated binding, a binding gone after a lost create.
#   4. TxnSnapshot: a re-put overwrites, an absent id has epoch -1.
#   5. ManifestBody.decode refuses each truncation with its own message.
#   6. ClusterAssignmentStore: the public key, the shared store handles, a
#      non-404 read error.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_broker.cluster_assignment_store import ClusterAssignmentStore
from komira_broker.manifest_body import ManifestBody, encode_manifest_body
from komira_broker.producer_dedupe import (
    DEDUPE_ACCEPT,
    DEDUPE_DUPLICATE,
    DEDUPE_FENCED,
    DEDUPE_LEASE_FENCED,
    DEDUPE_OUT_OF_ORDER,
    decide_sequence,
    dedupe_outcome_name,
)
from komira_broker.producer_registry import (
    ProducerEntry,
    ProducerRegistry,
    producer_id_counter_key,
    producer_key,
)
from komira_broker.read_committed import TxnSnapshot
from komira_broker.txn_control import TXN_STATE_ABORT, TXN_STATE_COMPLETE
from komira_broker.txn_registry import TxnIdRegistry, txn_id_bind_key
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


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(v)
    return out^


def test_decide_sequence_each_outcome() raises:
    # Zombie: epoch below the registered one, whatever the sequence.
    var f = decide_sequence(Int64(1), Int64(5), Int64(6), Int64(2), Int64(4))
    assert_equal(f.outcome, DEDUPE_FENCED)
    assert_equal(f.new_last_committed, Int64(4))
    # At or below the tail: duplicate, tail unchanged.
    var d = decide_sequence(Int64(2), Int64(4), Int64(4), Int64(2), Int64(4))
    assert_equal(d.outcome, DEDUPE_DUPLICATE)
    assert_equal(d.new_last_committed, Int64(4))
    # Exactly the next: accept, tail moves to last_seq.
    var a = decide_sequence(Int64(2), Int64(5), Int64(9), Int64(2), Int64(4))
    assert_equal(a.outcome, DEDUPE_ACCEPT)
    assert_equal(a.new_last_committed, Int64(9))
    # First-ever produce at 0 is accepted; at 1 it is a gap.
    var first = decide_sequence(Int64(0), Int64(0), Int64(0), Int64(0), Int64(-1))
    assert_equal(first.outcome, DEDUPE_ACCEPT)
    var gap = decide_sequence(Int64(0), Int64(6), Int64(7), Int64(0), Int64(4))
    assert_equal(gap.outcome, DEDUPE_OUT_OF_ORDER)
    assert_equal(gap.new_last_committed, Int64(4))
    # A higher epoch is not fenced here.
    var hi = decide_sequence(Int64(3), Int64(5), Int64(5), Int64(2), Int64(4))
    assert_equal(hi.outcome, DEDUPE_ACCEPT)
    assert_equal(dedupe_outcome_name(DEDUPE_ACCEPT), "ACCEPT")
    assert_equal(dedupe_outcome_name(DEDUPE_DUPLICATE), "DUPLICATE")
    assert_equal(dedupe_outcome_name(DEDUPE_OUT_OF_ORDER), "OUT_OF_ORDER")
    assert_equal(dedupe_outcome_name(DEDUPE_FENCED), "FENCED")
    assert_equal(dedupe_outcome_name(DEDUPE_LEASE_FENCED), "LEASE_FENCED")
    assert_equal(dedupe_outcome_name(7), "UNKNOWN")


def test_producer_registry_lifecycle() raises:
    var fs = _FaultStore()
    var r = ProducerRegistry[_FaultStore](fs.clone(), String("c"))
    assert_equal(r.cluster(), "c")
    assert_equal(producer_key("c", Int64(3)).raw(), "c/_meta/producers/3.json")
    assert_equal(
        producer_id_counter_key("c").raw(), "c/_meta/producers/_id_counter"
    )
    assert_equal(r.registered_epoch(Int64(0)), Int64(-1))
    var e0 = r.init_producer_id()
    var e1 = r.init_producer_id()
    assert_equal(e0.producer_id, Int64(0))
    assert_equal(e1.producer_id, Int64(1))
    assert_equal(e0.epoch, Int64(0))
    assert_true(e0.etag.byte_length() > 0)
    var b = r.bump_epoch(Int64(1))
    assert_equal(b.epoch, Int64(1))
    var b2 = r.bump_epoch(Int64(1))
    assert_equal(b2.epoch, Int64(2))
    assert_equal(r.registered_epoch(Int64(1)), Int64(2))
    assert_equal(r.registered_epoch(Int64(0)), Int64(0))
    var full = r.read_entry(Int64(1))
    assert_equal(full.epoch, Int64(2))
    assert_equal(full.etag, b2.etag)
    var enc = ProducerEntry(Int64(7), Int64(3), String("")).encode()
    assert_equal(len(enc), 16)
    var dec = ProducerEntry.decode(enc, String("x"))
    assert_equal(dec.producer_id, Int64(7))
    assert_equal(dec.epoch, Int64(3))


def test_producer_registry_contention_and_errors() raises:
    var fs = _FaultStore()
    var r = ProducerRegistry[_FaultStore](fs.clone(), String("c"))
    # A lost create of the counter, then a lost If-Match: both retried.
    fs.arm("cput", "_id_counter", 0, 1, _PRE)
    assert_equal(r.init_producer_id().producer_id, Int64(0))
    fs.arm("cput", "_id_counter", 0, 1, _PRE)
    assert_equal(r.init_producer_id().producer_id, Int64(1))
    fs.arm("cput", "_id_counter", 0, -1, _PRE)
    with assert_raises(contains="_alloc_producer_id: exhausted 64"):
        _ = r.init_producer_id()
    fs.arm("cput", "_id_counter", 0, -1, "boom: alloc")
    with assert_raises(contains="boom: alloc"):
        _ = r.init_producer_id()
    fs.disarm("cput")
    fs.arm("get", "_id_counter", 0, 1, "boom: read")
    with assert_raises(contains="boom: read"):
        _ = r.init_producer_id()
    # The counter did not move under the refused attempts.
    assert_equal(r.init_producer_id().producer_id, Int64(2))

    fs.arm("cput", "producers/1.json", 0, 1, _PRE)
    assert_equal(r.bump_epoch(Int64(1)).epoch, Int64(1))
    fs.arm("cput", "producers/1.json", 0, -1, _PRE)
    with assert_raises(contains="bump_epoch: exhausted 64 CAS"):
        _ = r.bump_epoch(Int64(1))
    fs.arm("cput", "producers/1.json", 0, -1, "boom: bump")
    with assert_raises(contains="boom: bump"):
        _ = r.bump_epoch(Int64(1))
    fs.disarm("cput")
    assert_equal(r.registered_epoch(Int64(1)), Int64(1))

    fs.arm("get", "producers/1.json", 0, 1, "boom: epoch")
    with assert_raises(contains="boom: epoch"):
        _ = r.registered_epoch(Int64(1))
    # A truncated entry is an error, not "never registered".
    _ = fs.inner.put(producer_key("c", Int64(9)), _bytes(4, 1))
    with assert_raises(contains="producer_registry: truncated i64 at 0"):
        _ = r.registered_epoch(Int64(9))


def test_txn_id_registry() raises:
    var fs = _FaultStore()
    var t = TxnIdRegistry[_FaultStore](fs.clone(), String("c"))
    assert_equal(t.lookup("a"), Int64(-1))
    assert_equal(t.reverse_lookup(Int64(5)), "")
    assert_equal(t.bind_or_read("a", Int64(5)), Int64(5))
    # A second candidate loses to the first binding.
    assert_equal(t.bind_or_read("a", Int64(6)), Int64(5))
    assert_equal(t.lookup("a"), Int64(5))
    assert_equal(t.reverse_lookup(Int64(5)), "a")
    assert_equal(t.reverse_lookup(Int64(6)), "")
    fs.arm("get", "txn-pid/5.bind", 0, 1, "boom: rev")
    with assert_raises(contains="boom: rev"):
        _ = t.reverse_lookup(Int64(5))
    fs.arm("get", "txn-id/a.bind", 0, 1, "boom: look")
    with assert_raises(contains="boom: look"):
        _ = t.lookup("a")
    fs.arm("cput", "txn-id/b.bind", 0, 1, "boom: bind")
    with assert_raises(contains="boom: bind"):
        _ = t.bind_or_read("b", Int64(8))
    # A lost create whose winner is gone when read back.
    fs.arm("cput", "txn-id/b.bind", 0, 1, _PRE)
    with assert_raises(contains="binding for 'b' vanished"):
        _ = t.bind_or_read("b", Int64(8))
    assert_equal(t.lookup("b"), Int64(-1))
    _ = fs.inner.put(txn_id_bind_key("c", "z"), _bytes(3, 0))
    with assert_raises(contains="txn_registry: truncated i64 at 0"):
        _ = t.lookup("z")


def test_txn_snapshot_overwrite_and_absent() raises:
    var s = TxnSnapshot()
    s.put("a", TXN_STATE_ABORT, Int64(1))
    s.put("b", TXN_STATE_ABORT, Int64(4))
    s.put("a", TXN_STATE_COMPLETE, Int64(3))
    assert_equal(s.size(), 2)
    assert_true(s.contains("a"))
    assert_false(s.contains("c"))
    assert_equal(s.state_of("a"), TXN_STATE_COMPLETE)
    assert_equal(s.epoch_of("a"), Int64(3))
    assert_equal(s.epoch_of("b"), Int64(4))
    assert_equal(s.epoch_of("c"), Int64(-1))


def test_manifest_body_truncations() raises:
    var full = encode_manifest_body("k1", Int64(3), UInt32(9))
    var ok = ManifestBody.decode(full)
    assert_equal(ok.object_key, "k1")
    assert_equal(ok.record_count, Int64(3))
    with assert_raises(contains="manifest body: truncated i64 at 0"):
        _ = ManifestBody.decode(_bytes(7, 0))
    with assert_raises(contains="manifest body: truncated u32 at 8"):
        _ = ManifestBody.decode(_bytes(11, 0))
    # key_len 255 with 2 key bytes present.
    var b = _bytes(12, 0)
    b.append(255)
    for _ in range(9):
        b.append(0)
    with assert_raises(contains="ManifestBody.decode: truncated object_key"):
        _ = ManifestBody.decode(b)


def test_assignment_store_handles_and_errors() raises:
    var fs = _FaultStore()
    var a = ClusterAssignmentStore[_FaultStore](fs.clone(), String("c"))
    assert_equal(a.key_for("t"), "c/_meta/cluster/t/assignment.bin")
    # A write through the borrowed store is what the layer reads back.
    _ = a.store_ref().put(Path.parse(a.key_for("t")), _bytes(2, 7))
    var got = a.read_assignment("t")
    assert_true(got)
    assert_equal(len(got.value().body), 2)
    # A write through a cloned handle is visible too (one shared map).
    var other = a.clone_store()
    _ = other.put(Path.parse(a.key_for("u")), _bytes(3, 1))
    assert_equal(len(a.read_assignment("u").value().body), 3)
    assert_false(a.read_assignment("v"))
    fs.arm("head", "/t/assignment.bin", 0, 1, "boom: head")
    with assert_raises(contains="boom: head"):
        _ = a.read_assignment("t")


def main() raises:
    test_decide_sequence_each_outcome()
    test_producer_registry_lifecycle()
    test_producer_registry_contention_and_errors()
    test_txn_id_registry()
    test_txn_snapshot_overwrite_and_absent()
    test_manifest_body_truncations()
    test_assignment_store_handles_and_errors()
    print("[OK] test_cov_producer_registry_unit")
