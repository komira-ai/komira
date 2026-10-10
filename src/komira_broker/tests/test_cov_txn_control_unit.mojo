# =============================================================================
# tests/test_cov_txn_control_unit.mojo
#   The transaction control object: wire decode of every block, staged
#   consumer offsets, and the store-error arms of every CAS loop.
# =============================================================================
#
# Each test drives one TxnControlStore verb over a store that can fail a
# verb on demand (_FaultStore below):
#   1. The state names of every state, including the unknown one.
#   2. decode refuses each truncated block (topic, offset group, offset topic,
#      offset metadata, a short integer) with its own message.
#   3. stage_offset: last writer wins per key, offsets ride every state flip
#      up to Complete, and survive the round trip through the store.
#   4. Each verb refuses a missing transaction and a wrong state.
#   5. Each CAS loop retries a precondition failure, gives up after its
#      retry budget, and propagates any other store error unchanged.
#   6. stage_offset and add_partitions return what they wrote when the read
#      after the write finds nothing (komira-ai/komira#1075: add_partitions
#      returned an empty partition list there).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_broker.txn_control import (
    TXN_STATE_ABORT,
    TXN_STATE_COMPLETE,
    TXN_STATE_EMPTY,
    TXN_STATE_ONGOING,
    TXN_STATE_PREPARE_ABORT,
    TXN_STATE_PREPARE_COMMIT,
    TxnControl,
    TxnControlStore,
    TxnPartition,
    TxnPendingOffset,
    txn_state_name,
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


comptime _PRE = "precondition (412) injected"


def _store(fs: _FaultStore) -> TxnControlStore[_FaultStore]:
    return TxnControlStore[_FaultStore](fs.clone(), String("c"))


def _parts(topic: String, p: Int64) -> List[TxnPartition]:
    var out = List[TxnPartition]()
    out.append(TxnPartition(String(topic), p))
    return out^


def test_state_names() raises:
    # Runtime values, so no arm is folded away at compile time.
    var states = List[UInt8]()
    states.append(TXN_STATE_EMPTY)
    states.append(TXN_STATE_ONGOING)
    states.append(TXN_STATE_PREPARE_COMMIT)
    states.append(TXN_STATE_COMPLETE)
    states.append(TXN_STATE_PREPARE_ABORT)
    states.append(TXN_STATE_ABORT)
    states.append(UInt8(9))
    var names = List[String]()
    names.append("Empty")
    names.append("Ongoing")
    names.append("PrepareCommit")
    names.append("Complete")
    names.append("PrepareAbort")
    names.append("Abort")
    names.append("Unknown")
    for i in range(len(states)):
        assert_equal(txn_state_name(states[i]), names[i])


def _with_offset() -> TxnControl:
    var offs = List[TxnPendingOffset]()
    offs.append(
        TxnPendingOffset(String("g"), String("t"), Int64(3), Int64(7), String("m"))
    )
    return TxnControl(
        Int64(11), Int64(2), TXN_STATE_ONGOING, Int64(5),
        List[TxnPartition](), offs^, String(""),
    )


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return out^


def test_decode_round_trip_and_truncations() raises:
    var tc = _with_offset()
    var b = tc.encode()
    var back = TxnControl.decode(b, String("e1"))
    assert_equal(back.producer_id, Int64(11))
    assert_equal(back.epoch, Int64(2))
    assert_equal(back.complete_version, Int64(5))
    assert_equal(len(back.pending_offsets), 1)
    assert_equal(back.pending_offsets[0].group, "g")
    assert_equal(back.pending_offsets[0].topic, "t")
    assert_equal(back.pending_offsets[0].partition, Int64(3))
    assert_equal(back.pending_offsets[0].offset, Int64(7))
    assert_equal(back.pending_offsets[0].metadata, "m")
    assert_equal(back.etag, "e1")
    # copy() and copy_pending_offsets() carry the staged offsets.
    var c = back.copy()
    assert_equal(len(c.pending_offsets), 1)
    assert_equal(c.pending_offsets[0].offset, Int64(7))
    assert_equal(len(back.copy_pending_offsets()), 1)

    # Trailing block layout: glen g tlen t part off mlen m (1-byte strings).
    var n = len(b)
    with assert_raises(contains="truncated offset metadata"):
        _ = TxnControl.decode(_prefix(b, n - 1), String(""))
    with assert_raises(contains="truncated offset topic"):
        _ = TxnControl.decode(_prefix(b, n - 26), String(""))
    with assert_raises(contains="truncated offset group"):
        _ = TxnControl.decode(_prefix(b, n - 35), String(""))
    with assert_raises(contains="txn_control: truncated i64 at 0"):
        _ = TxnControl.decode(_prefix(b, 4), String(""))

    # A partition topic cut short.
    var tp = TxnControl(
        Int64(1), Int64(0), TXN_STATE_ONGOING, Int64(1),
        _parts("p", Int64(0)), List[TxnPendingOffset](), String(""),
    )
    var pb = tp.encode()
    assert_equal(len(pb), 65)
    with assert_raises(contains="truncated topic name"):
        _ = TxnControl.decode(_prefix(pb, 48), String(""))
    # An object that stops after the partitions block reads no offsets.
    var old = TxnControl.decode(_prefix(pb, 57), String(""))
    assert_equal(len(old.partitions), 1)
    assert_equal(len(old.pending_offsets), 0)


def test_stage_offset_carried_to_complete() raises:
    var fs = _FaultStore()
    var s = _store(fs)
    _ = s.begin("x", Int64(4), Int64(1))
    _ = s.add_partitions("x", _parts("t", Int64(0)))
    var a = s.stage_offset("x", "g", "t", Int64(0), Int64(10), "first")
    assert_equal(len(a.pending_offsets), 1)
    # Same key: last writer wins, no second entry.
    var b = s.stage_offset("x", "g", "t", Int64(0), Int64(12), "second")
    assert_equal(len(b.pending_offsets), 1)
    assert_equal(b.pending_offsets[0].offset, Int64(12))
    assert_equal(b.pending_offsets[0].metadata, "second")
    # A different partition of the same group is its own key.
    var c = s.stage_offset("x", "g", "t", Int64(1), Int64(3), "")
    assert_equal(len(c.pending_offsets), 2)
    assert_true(c.has_partition("t", Int64(0)))
    var pc = s.prepare_commit("x")
    assert_equal(len(pc.pending_offsets), 2)
    var done = s.complete_commit("x")
    assert_equal(done.state, TXN_STATE_COMPLETE)
    assert_equal(len(done.pending_offsets), 2)
    var r = s.read("x").value().copy()
    assert_equal(len(r.pending_offsets), 2)
    assert_equal(r.pending_offsets[0].offset, Int64(12))
    assert_equal(r.pending_offsets[1].partition, Int64(1))
    # Staging onto a Complete txn is refused.
    with assert_raises(contains="is Complete (not Ongoing)"):
        _ = s.stage_offset("x", "g", "t", Int64(0), Int64(1), "")


def test_missing_and_wrong_state_refusals() raises:
    var fs = _FaultStore()
    var s = _store(fs)
    with assert_raises(contains="stage_offset: no open transaction for 'nope'"):
        _ = s.stage_offset("nope", "g", "t", Int64(0), Int64(1), "")
    with assert_raises(contains="add_partitions: no open transaction for 'nope'"):
        _ = s.add_partitions("nope", _parts("t", Int64(0)))
    with assert_raises(contains="abort: no transaction for 'nope'"):
        _ = s.abort("nope")
    with assert_raises(contains="no transaction for 'nope' (expected Ongoing)"):
        _ = s.prepare_commit("nope")
    # prepare_abort, then abort is the edge out of PrepareAbort.
    _ = s.begin("y", Int64(1), Int64(0))
    var pa = s.prepare_abort("y")
    assert_equal(pa.state, TXN_STATE_PREPARE_ABORT)
    with assert_raises(contains="'y' is PrepareAbort (not Ongoing)"):
        _ = s.add_partitions("y", _parts("t", Int64(0)))
    var ab = s.abort("y")
    assert_equal(ab.state, TXN_STATE_ABORT)
    # Abort on Abort returns the object unchanged (no new version).
    var again = s.abort("y")
    assert_equal(again.state, TXN_STATE_ABORT)
    assert_equal(again.complete_version, ab.complete_version)
    assert_equal(again.etag, s.read("y").value().etag)


def test_read_propagates_store_error() raises:
    var fs = _FaultStore()
    var s = _store(fs)
    _ = s.begin("x", Int64(1), Int64(0))
    fs.arm("get", "/_meta/txn/x", 0, 1, "boom: disk on fire")
    with assert_raises(contains="boom: disk on fire"):
        _ = s.read("x")


def test_cas_loops_retry_give_up_and_propagate() raises:
    var fs = _FaultStore()
    var s = _store(fs)
    _ = s.begin("x", Int64(1), Int64(0))
    # One precondition failure: each verb retries and lands.
    fs.arm("cput", "/_meta/txn/x", 0, 1, _PRE)
    var ap = s.add_partitions("x", _parts("t", Int64(0)))
    assert_true(ap.has_partition("t", Int64(0)))
    fs.arm("cput", "/_meta/txn/x", 0, 1, _PRE)
    var so = s.stage_offset("x", "g", "t", Int64(0), Int64(5), "")
    assert_equal(len(so.pending_offsets), 1)
    fs.arm("cput", "/_meta/txn/x", 0, 1, _PRE)
    var pc = s.prepare_commit("x")
    assert_equal(pc.state, TXN_STATE_PREPARE_COMMIT)
    fs.arm("cput", "/_meta/txn/x", 0, 1, _PRE)
    var ab = s.abort("x")
    assert_equal(ab.state, TXN_STATE_ABORT)
    assert_equal(len(ab.pending_offsets), 1)

    # Every attempt refused: each loop gives up with its own message.
    _ = s.begin("x", Int64(1), Int64(1))
    fs.arm("cput", "/_meta/txn/x", 0, -1, _PRE)
    with assert_raises(contains="add_partitions: exhausted CAS retries"):
        _ = s.add_partitions("x", _parts("t", Int64(0)))
    with assert_raises(contains="stage_offset: exhausted CAS retries"):
        _ = s.stage_offset("x", "g", "t", Int64(0), Int64(5), "")
    with assert_raises(contains="_cas_transition: exhausted CAS retries"):
        _ = s.prepare_commit("x")
    with assert_raises(contains="abort: exhausted CAS retries"):
        _ = s.abort("x")

    # Any other store error propagates on the first attempt.
    fs.arm("cput", "/_meta/txn/x", 0, -1, "boom: io")
    with assert_raises(contains="boom: io"):
        _ = s.add_partitions("x", _parts("t", Int64(0)))
    with assert_raises(contains="boom: io"):
        _ = s.stage_offset("x", "g", "t", Int64(0), Int64(5), "")
    with assert_raises(contains="boom: io"):
        _ = s.prepare_commit("x")
    with assert_raises(contains="boom: io"):
        _ = s.abort("x")
    fs.disarm("cput")
    # Nothing was written by the refused attempts.
    var r = s.read("x").value().copy()
    assert_equal(r.state, TXN_STATE_ONGOING)
    assert_equal(len(r.partitions), 0)
    assert_equal(len(r.pending_offsets), 0)


def test_write_then_vanished_read_synthesizes() raises:
    var fs = _FaultStore()
    var s = _store(fs)
    _ = s.begin("x", Int64(9), Int64(5))
    _ = s.add_partitions("x", _parts("t", Int64(2)))
    # The first get (the read before the CAS) passes; the read after it
    # finds nothing.
    fs.arm("get", "/_meta/txn/x", 1, 1, "not_found (404) injected")
    var so = s.stage_offset("x", "g", "t", Int64(2), Int64(8), "md")
    # Every field comes from the staged update: producer 9, epoch 5 (distinct
    # from the producer id and the version), still Ongoing, version 3.
    assert_equal(so.producer_id, Int64(9))
    assert_equal(so.epoch, Int64(5))
    assert_equal(so.state, TXN_STATE_ONGOING)
    assert_equal(so.complete_version, Int64(3))
    assert_equal(len(so.partitions), 1)
    assert_equal(len(so.pending_offsets), 1)
    assert_equal(so.pending_offsets[0].offset, Int64(8))
    assert_equal(so.pending_offsets[0].metadata, "md")
    assert_equal(so.etag, s.read("x").value().etag)


def test_add_partitions_vanished_read_returns_written() raises:
    # komira-ai/komira#1075. One partition and one staged offset are already
    # on the txn; the call adds a second partition and re-adds the first.
    var fs = _FaultStore()
    var s = _store(fs)
    _ = s.begin("x", Int64(9), Int64(5))
    _ = s.add_partitions("x", _parts("t", Int64(2)))
    _ = s.stage_offset("x", "g", "t", Int64(2), Int64(8), "md")
    var more = _parts("t", Int64(2))
    more.append(TxnPartition(String("u"), Int64(4)))
    fs.arm("get", "/_meta/txn/x", 1, 1, "not_found (404) injected")
    var ap = s.add_partitions("x", more^)
    var stored = s.read("x").value().copy()
    assert_equal(len(stored.partitions), 2)
    assert_equal(ap.producer_id, Int64(9))
    assert_equal(ap.epoch, Int64(5))
    assert_equal(ap.state, TXN_STATE_ONGOING)
    assert_equal(ap.complete_version, stored.complete_version)
    assert_equal(len(ap.partitions), 2)
    assert_true(ap.has_partition("t", Int64(2)))
    assert_true(ap.has_partition("u", Int64(4)))
    assert_equal(len(ap.pending_offsets), 1)
    assert_equal(ap.pending_offsets[0].offset, Int64(8))
    assert_equal(ap.pending_offsets[0].metadata, "md")
    assert_equal(ap.etag, stored.etag)


def main() raises:
    test_state_names()
    test_decode_round_trip_and_truncations()
    test_stage_offset_carried_to_complete()
    test_missing_and_wrong_state_refusals()
    test_read_propagates_store_error()
    test_cas_loops_retry_give_up_and_propagate()
    test_write_then_vanished_read_synthesizes()
    test_add_partitions_vanished_read_returns_written()
    print("[OK] test_cov_txn_control_unit")
