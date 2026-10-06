# =============================================================================
# tests/test_broker_flush_refuse_before_put_offline.mojo
#   A stale writer's flush is refused before its segment PUT.
# =============================================================================
#
# A flush PUTs its `.seg` and then appends the manifest chunk that references
# it. Nothing deletes a `.seg` that no chunk references (issue #488), so a
# flush refused AFTER its PUT leaks one object for good. The four BrokerCore
# flush variants (at-least-once, with producer, exactly-once, transactional)
# must therefore refuse a displaced writer BEFORE the PUT:
#
#   (1) Refused at entry. `(writer, current) = (1, 2)` is refused as
#       `lease_fenced` and leaves the `.seg` count and the chunk count where
#       they were. Defect caught: the check after `_stage_segment` (or absent),
#       which leaves one more `.seg` per refused flush.
#   (2) Cached fence. A flush whose manifest append comes back `lease_fenced`
#       after its PUT records the fence; the next flush at the same stale epoch
#       is refused before its PUT, and a writer at the next epoch still
#       commits. The fault store below makes the manifest's chunk create raise
#       `lease_fenced` while the writer is not below `current`: that is the
#       shape of a fence the core did not know about. Defect caught: the fence
#       never recorded (the second flush PUTs again), or recorded so high that
#       the new owner is refused.
#   (3) Unknown outcome. An append that raises anything else is counted as an
#       unknown outcome and records no fence: the next flush at the same epoch
#       commits.
#   (4) Fenced auto-flush. Once fenced, `produce()`'s trigger flush (default
#       epochs 0, 0) raises `lease_fenced` before any PUT, drops the unacked
#       buffer and returns no ack. Defect caught: `produce` swallowing the
#       refusal (the producer would never learn it must move).
#
# Cases (1)-(3) run for all four variants. The counters on `flush_leak_stats()`
# are asserted on every path.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

from komira_broker.broker_core import (
    BrokerCore,
    EO_COMMITTED,
    EO_LEASE_FENCED,
    FLUSH_MS,
)

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    is_lease_fenced,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _CLUSTER = "c"
comptime _TOPIC = "t"
comptime _PID = Int64(0)
comptime _FAULT_KEY = "c/_fault/chunk"

# The variants, in the order the scope names them.
comptime _V_FLUSH = 0
comptime _V_PRODUCER = 1
comptime _V_EXACTLY_ONCE = 2
comptime _V_TXN = 3
comptime _N_VARIANTS = 4


# =============================================================================
# A store that fails manifest chunk creates on demand.
# =============================================================================


struct _ChunkFaultStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """Delegates every verb to a shared in-memory store. While the object at
    `_FAULT_KEY` exists, a conditional PUT of a manifest chunk
    (`.../manifest/<seq>.chunk`) raises an error whose message is that object's
    bytes. Clones share the map, so the test arms and disarms the fault through
    any handle. Segment, `_HEAD` and dedup-sentinel writes are never failed."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self):
        self._inner = SharedInMemoryConditionalStore()

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def arm(self, message: String) raises:
        var bytes = List[UInt8]()
        for b in message.as_bytes():
            bytes.append(b)
        _ = self._inner.put(Path.parse(_FAULT_KEY), bytes)

    def disarm(self) raises:
        self._inner.delete(Path.parse(_FAULT_KEY))

    def _armed(self) -> Optional[String]:
        try:
            var raw = self._inner.get(Path.parse(_FAULT_KEY))
            return Optional[String](String(unsafe_from_utf8=Span(raw)))
        except e:
            _ = e  # absent: the fault is disarmed
            return Optional[String](None)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        var raw = path.raw()
        if raw.find("/manifest/") >= 0 and raw.endswith(".chunk"):
            var armed = self._armed()
            if armed:
                raise Error(armed.value())
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


comptime _Store = _ChunkFaultStore


# =============================================================================
# Fixture helpers.
# =============================================================================


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


def _core(store: _Store) raises -> BrokerCore[_Store]:
    var prefix = String(_CLUSTER) + "/_meta/topics/" + _TOPIC + "/" + String(_PID)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=_PID,
        broker_id=String("b0"),
    )


def _count_under(store: _Store, prefix: String, suffix: String) raises -> Int:
    var res = store.list_with_delimiter(Path.parse(prefix))
    var n = 0
    for i in range(len(res.objects)):
        if res.objects[i].location.endswith(suffix):
            n += 1
    return n


def _segs(store: _Store) raises -> Int:
    return _count_under(
        store,
        String(_CLUSTER) + "/topics/" + _TOPIC + "/" + String(_PID) + "/segments/",
        ".seg",
    )


def _chunks(store: _Store) raises -> Int:
    return _count_under(
        store,
        String(_CLUSTER) + "/_meta/topics/" + _TOPIC + "/" + String(_PID) + "/manifest/",
        ".chunk",
    )


def _assert_stats(
    core: BrokerCore[_Store],
    refused: Int,
    fenced_after: Int,
    unknown: Int,
    label: String,
) raises:
    var st = core.flush_leak_stats()
    assert_equal(st.refused_before_put, Int64(refused), label + "refused_before_put")
    assert_equal(st.fenced_after_put, Int64(fenced_after), label + "fenced_after_put")
    assert_equal(st.unknown_outcome, Int64(unknown), label + "unknown_outcome")


def _variant_name(v: Int) -> String:
    if v == _V_FLUSH:
        return "flush"
    if v == _V_PRODUCER:
        return "flush_with_producer"
    if v == _V_EXACTLY_ONCE:
        return "flush_with_producer_exactly_once"
    return "flush_with_producer_txn"


def _attempt(
    mut core: BrokerCore[_Store],
    v: Int,
    seq: Int64,
    writer: Int64,
    current: Int64,
) raises -> String:
    """Buffer one 2-record batch and flush it through variant `v` at
    `(writer, current)`. Returns "ok" for a commit, "lease_fenced" for a
    refusal (a raise classified by `is_lease_fenced`, or `EO_LEASE_FENCED`),
    and "error: <msg>" / "eo: <outcome>" for anything else. `seq` keeps every
    exactly-once batch identity distinct, so no attempt is a DUPLICATE."""
    var now = Int64(1_000) + seq
    core.buffer_batch(_batch(seq * Int64(10), 2), now)
    var first = seq * Int64(2)
    try:
        if v == _V_FLUSH:
            _ = core.flush(now, writer, current)
        elif v == _V_PRODUCER:
            _ = core.flush_with_producer(
                now, Int64(7), Int64(0), first, first + Int64(1), writer, current
            )
        elif v == _V_EXACTLY_ONCE:
            var r = core.flush_with_producer_exactly_once(
                now,
                Int64(7),
                Int64(0),
                first,
                first + Int64(1),
                Int64(0),
                writer,
                current,
            )
            if r.outcome == EO_LEASE_FENCED:
                return String("lease_fenced")
            if r.outcome != EO_COMMITTED:
                return String("eo: ") + String(r.outcome)
        else:
            _ = core.flush_with_producer_txn(
                now,
                Int64(7),
                Int64(0),
                first,
                first + Int64(1),
                String("txn-1"),
                writer,
                current,
            )
    except e:
        var msg = String(e)
        if is_lease_fenced(msg):
            return String("lease_fenced")
        return String("error: ") + msg
    return String("ok")


# =============================================================================
# (1) Refused at entry: (old, live) PUTs no `.seg`.
# =============================================================================


def test_refused_at_entry_puts_no_segment() raises:
    print("[test_refused_at_entry_puts_no_segment] starting...")
    for v in range(_N_VARIANTS):
        var label = _variant_name(v) + ": "
        var store = _Store()
        var core = _core(store)
        assert_true(not core.is_fenced(), label + "a fresh core is not fenced")
        _assert_stats(core, 0, 0, 0, label + "fresh: ")
        var got = _attempt(core, v, Int64(1), Int64(1), Int64(2))
        assert_equal(got, String("lease_fenced"), label + "(1, 2) is refused")
        assert_equal(_segs(store), 0, label + "a refused flush PUTs no .seg")
        assert_equal(_chunks(store), 0, label + "a refused flush commits no chunk")
        assert_equal(core.buffered_batches(), 0, label + "the refused batch is dropped")
        _assert_stats(core, 1, 0, 0, label + "after the refusal: ")
        assert_true(core.is_fenced(), label + "the refusal fences the core")
        assert_equal(core.fence_epoch(), Int64(2), label + "the fence is `current`")

        # The live epoch commits; the fence does not refuse it.
        got = _attempt(core, v, Int64(2), Int64(2), Int64(2))
        assert_equal(got, String("ok"), label + "(2, 2) commits")
        assert_equal(_segs(store), 1, label + "its .seg landed")
        assert_equal(_chunks(store), 1, label + "its chunk landed")
        _assert_stats(core, 1, 0, 0, label + "after the commit: ")
    print("[test_refused_at_entry_puts_no_segment] PASS")


# =============================================================================
# (2) Cached fence: lease_fenced after the PUT refuses the next stale flush.
# =============================================================================


def test_fence_after_put_is_cached() raises:
    print("[test_fence_after_put_is_cached] starting...")
    for v in range(_N_VARIANTS):
        var label = _variant_name(v) + ": "
        var store = _Store()
        var core = _core(store)

        # The manifest refuses the append after the segment PUT landed.
        store.arm(String("injected: lease_fenced by a fence the core did not know"))
        var got = _attempt(core, v, Int64(1), Int64(5), Int64(5))
        assert_equal(got, String("lease_fenced"), label + "the append is fenced")
        assert_equal(_segs(store), 1, label + "the fenced append leaked its .seg")
        assert_equal(_chunks(store), 0, label + "no chunk committed")
        _assert_stats(core, 0, 1, 0, label + "after the fenced append: ")
        assert_true(core.is_fenced(), label + "the fenced append fences the core")
        assert_equal(core.fence_epoch(), Int64(6), label + "the fence is writer + 1")
        store.disarm()

        # The same stale epoch again: refused before the PUT.
        got = _attempt(core, v, Int64(2), Int64(5), Int64(5))
        assert_equal(got, String("lease_fenced"), label + "the cached fence refuses")
        assert_equal(_segs(store), 1, label + "the cached refusal PUTs no .seg")
        assert_equal(_chunks(store), 0, label + "still no chunk")
        _assert_stats(core, 1, 1, 0, label + "after the cached refusal: ")

        # A refusal at a lower `current` does not lower the cached fence.
        got = _attempt(core, v, Int64(4), Int64(1), Int64(2))
        assert_equal(got, String("lease_fenced"), label + "(1, 2) is refused")
        assert_equal(core.fence_epoch(), Int64(6), label + "the fence never goes down")
        assert_equal(_segs(store), 1, label + "no .seg for (1, 2)")
        _assert_stats(core, 2, 1, 0, label + "after the second refusal: ")

        # The next epoch is not refused: the cache holds writer + 1, no more.
        got = _attempt(core, v, Int64(5), Int64(6), Int64(6))
        assert_equal(got, String("ok"), label + "a writer at the next epoch commits")
        assert_equal(_segs(store), 2, label + "its .seg landed")
        assert_equal(_chunks(store), 1, label + "its chunk landed")
        _assert_stats(core, 2, 1, 0, label + "after the commit: ")
    print("[test_fence_after_put_is_cached] PASS")


# =============================================================================
# (3) Unknown outcome: any other append error is counted and caches no fence.
# =============================================================================


def test_unknown_outcome_is_counted_not_fenced() raises:
    print("[test_unknown_outcome_is_counted_not_fenced] starting...")
    for v in range(_N_VARIANTS):
        var label = _variant_name(v) + ": "
        var store = _Store()
        var core = _core(store)

        store.arm(String("injected: transport error, connection reset"))
        var got = _attempt(core, v, Int64(1), Int64(5), Int64(5))
        assert_true(got.startswith("error: "), label + "the error propagates, got " + got)
        assert_equal(_segs(store), 1, label + "the .seg is possibly leaked")
        assert_equal(_chunks(store), 0, label + "no chunk committed")
        _assert_stats(core, 0, 0, 1, label + "after the unknown outcome: ")
        assert_true(not core.is_fenced(), label + "an unknown outcome is not a fence")
        store.disarm()

        # The same epoch is not refused: the producer's retry goes through.
        got = _attempt(core, v, Int64(2), Int64(5), Int64(5))
        assert_equal(got, String("ok"), label + "the retry commits")
        assert_equal(_segs(store), 2, label + "the retry's .seg landed")
        assert_equal(_chunks(store), 1, label + "the retry's chunk landed")
        _assert_stats(core, 0, 0, 1, label + "after the retry: ")
    print("[test_unknown_outcome_is_counted_not_fenced] PASS")


# =============================================================================
# (4) A fenced core's produce() auto-flush raises, PUTs nothing, acks nothing.
# =============================================================================


def test_fenced_produce_auto_flush_raises() raises:
    print("[test_fenced_produce_auto_flush_raises] starting...")
    var store = _Store()
    var core = _core(store)
    # Fence the core with an epoch-aware flush refused at entry.
    var got = _attempt(core, _V_FLUSH, Int64(1), Int64(1), Int64(2))
    assert_equal(got, String("lease_fenced"), "the epoch-aware flush is refused")
    assert_true(core.is_fenced(), "the core is fenced")
    _assert_stats(core, 1, 0, 0, "after fencing: ")

    # A produce that does not trigger the flush buffers and returns no ack.
    var t0 = Int64(10_000)
    var first = core.produce(_batch(Int64(100), 2), t0)
    assert_true(not first, "a buffered produce is not acked")
    assert_equal(core.buffered_batches(), 1, "one batch buffered")

    # The time trigger fires: the default-epoch flush is below the fence.
    var acked = False
    var refused = False
    try:
        var r = core.produce(_batch(Int64(200), 2), t0 + FLUSH_MS)
        acked = Bool(r)
    except e:
        var msg = String(e)
        assert_true(is_lease_fenced(msg), "the auto-flush raises lease_fenced, got: " + msg)
        refused = True
    assert_true(refused, "the fenced auto-flush raised")
    assert_true(not acked, "the fenced auto-flush returned no ack")
    assert_equal(_segs(store), 0, "the fenced auto-flush PUT no .seg")
    assert_equal(_chunks(store), 0, "the fenced auto-flush committed no chunk")
    assert_equal(core.buffered_batches(), 0, "the unacked buffer was dropped")
    _assert_stats(core, 2, 0, 0, "after the auto-flush: ")
    print("[test_fenced_produce_auto_flush_raises] PASS")


def main() raises:
    test_refused_at_entry_puts_no_segment()
    test_fence_after_put_is_cached()
    test_unknown_outcome_is_counted_not_fenced()
    test_fenced_produce_auto_flush_raises()
    print("test_broker_flush_refuse_before_put_offline: ALL PASS")
