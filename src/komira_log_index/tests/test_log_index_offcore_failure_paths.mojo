# =============================================================================
# test_log_index_offcore_failure_paths.mojo
#   Publish ordering, failure handling, uuid stability and bounds of the
#   off-core flush pipeline (handoff, gate, consumer, flush thread).
# =============================================================================
#
# What each case pins:
#   * the consumer writes the split object (`put`) BEFORE it appends the summary
#     to the metastore (a recording store logs the order of its write verbs);
#   * a failing split PUT publishes nothing, counts a publish failure and still
#     releases the reserved bytes;
#   * a failing metastore append leaves only an unreferenced object, counts a
#     publish failure and still releases the reserved bytes;
#   * a transient PUT failure is retried and lands the records under the same
#     object key;
#   * two consumers with the same worker discriminant but different install
#     epochs never write the same object key (a restart cannot overwrite an
#     earlier process's split); the same epoch would, so the epoch is what keeps
#     them apart;
#   * the handoff is bounded by count and by bytes: when full it rejects the
#     offer (it never blocks and never grows), counts the rejection, gives the
#     reservation back, and accepts again once drained; it hands units back in
#     FIFO order;
#   * the in-flight gate admits an over-sized reservation only when the pool is
#     empty and clamps a release at zero;
#   * the flush thread's shutdown path publishes the last partial segment.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log import LogRecordView
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.drain import drain_to_views
from komira_log.engine.emit import emit_record
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.levels import LEVEL_INFO
from komira_log.log_arg import ArgI64, ArgStr

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_log_index.consumer import _BatchAcceptor, _drain_batches_into
from komira_log_index.transpose import log_views_to_record_batch
from komira_log_index import (
    FlushRetryPolicy,
    InFlightBytesGate,
    LogIndexConsumer,
    LogIndexHandoff,
    OffCoreFlushThread,
    offer_log_views,
)

from komira_objectstore import (
    CasManifestStore,
    CloneableConditionalWriteStore,
    CoalescePolicy,
    ConditionalWriteStore,
    ListResult,
    ObjectMeta,
    ObjectStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
)
from komira_objectstore.path import Path
from komira_search_catalog import (
    SearchMetastore,
    list_live_splits_across_shards,
    make_shard_id,
    shard_manifest_prefix,
)


# -----------------------------------------------------------------------------
# A store that records the order of its write verbs and can be told to fail.
# -----------------------------------------------------------------------------


struct _State(Movable):
    var log: List[String]
    var fail_put: Bool
    var fail_conditional: Bool
    # The next `fail_put_times` puts fail, then puts succeed again (a transient
    # failure).
    var fail_put_times: Int

    def __init__(out self):
        self.log = List[String]()
        self.fail_put = False
        self.fail_conditional = False
        self.fail_put_times = 0


struct RecordingStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _st: ArcPointer[_State]

    def __init__(out self):
        self._inner = SharedInMemoryConditionalStore()
        self._st = ArcPointer[_State](_State())

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var st: ArcPointer[_State],
    ):
        self._inner = inner^
        self._st = st^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._st.copy())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._st[].log.append(String("cond:") + path.raw())
        if self._st[].fail_conditional:
            raise Error("RecordingStore: injected conditional_put failure")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._st[].log.append(String("put:") + path.raw())
        if self._st[].fail_put:
            raise Error("RecordingStore: injected put failure")
        if self._st[].fail_put_times > 0:
            self._st[].fail_put_times -= 1
            raise Error("RecordingStore: injected transient put failure")
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    def log(self) -> List[String]:
        return self._st[].log.copy()


# -----------------------------------------------------------------------------
# Fixtures.
# -----------------------------------------------------------------------------

comptime _META_ROOT: String = "index/logs/meta"
comptime _INDEX: String = "logs"


def _anchor() -> CalibrationAnchor:
    return CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_788_220_800) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )


def _login_views(n: Int) raises -> List[LogRecordView]:
    var d = SiteDictionary()
    d.register["request {} status {}", "komira_http_login"]()
    var ring = LogRecordRing(capacity=n + 8, overflow_policy=OVERFLOW_BLOCK)
    for i in range(n):
        _ = emit_record["request {} status {}", "komira_http_login"](
            ring, LEVEL_INFO, UInt64(100 + i), ArgStr(String("login")), ArgI64(200)
        )
    return drain_to_views(ring, d, _anchor())


def _consumer(
    store: RecordingStore,
    retry: FlushRetryPolicy,
    worker_disc: UInt8 = UInt8(0),
    epoch_us: Int64 = Int64(-1),
    flush_bytes: Int64 = Int64(1),
) raises -> LogIndexConsumer[RecordingStore]:
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))
    var manifest = CasManifestStore[RecordingStore](
        store.clone(),
        shard_manifest_prefix(String(_META_ROOT), shard),
        RetryPolicy.fast_test(),
    )
    var metastore = SearchMetastore[RecordingStore](manifest^, String(_INDEX))
    return LogIndexConsumer[RecordingStore](
        store.clone(),
        metastore^,
        String("bucket"),
        String(_META_ROOT),
        String(_INDEX),
        worker_disc,
        flush_bytes,
        Int64(10_000_000),
        retry,
        epoch_us,
    )


def _live(store: RecordingStore) raises -> Int:
    return len(
        list_live_splits_across_shards(store, String(_META_ROOT), String(_INDEX))
    )


def _count_prefix(log: List[String], prefix: String) -> Int:
    var c = 0
    for i in range(len(log)):
        if log[i].startswith(prefix):
            c += 1
    return c


def _put_keys(log: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(log)):
        if log[i].startswith("put:"):
            out.append(String(log[i][byte=4 : log[i].byte_length()]))
    return out^


def _offer(
    mut handoff: LogIndexHandoff, mut gate: InFlightBytesGate, n: Int
) raises -> Bool:
    return offer_log_views(handoff, gate, _login_views(n))


# -----------------------------------------------------------------------------
# Consumer: ordering and failure.
# -----------------------------------------------------------------------------


def test_consumer_puts_the_split_before_it_publishes() raises:
    var store = RecordingStore()
    var consumer = _consumer(store, FlushRetryPolicy.single_attempt())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    assert_equal(consumer.drive_once(handoff, gate, Int64(0)), 1, "one unit")
    assert_equal(Int(consumer.stats().splits_published), 1, "published")
    var log = store.log()
    assert_true(len(log) >= 2, "a put and at least one conditional write")
    assert_true(
        log[0].startswith("put:") and "/splits/" in log[0],
        "the first write is the split PUT: " + log[0],
    )
    assert_equal(_count_prefix(log, "put:"), 1, "exactly one split PUT")
    assert_true(_count_prefix(log, "cond:") >= 1, "the manifest is written after")
    assert_equal(_live(store), 1, "the split is live")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the reservation is released")


def test_failed_put_publishes_nothing_and_releases_the_gate() raises:
    var store = RecordingStore()
    store._st[].fail_put = True
    var consumer = _consumer(store, FlushRetryPolicy.single_attempt())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    assert_true(gate.in_flight_bytes() > Int64(0), "bytes reserved")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(Int(consumer.stats().publish_failures), 1, "failure counted")
    assert_equal(Int(consumer.stats().splits_published), 0, "nothing published")
    assert_equal(Int(consumer.stats().docs_published), 0, "no docs published")
    assert_equal(
        _count_prefix(store.log(), "cond:"), 0, "no manifest write after a failed PUT"
    )
    assert_equal(_live(store), 0, "nothing is live")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the gate does not leak")


def test_failed_publish_leaves_only_an_unreferenced_object() raises:
    var store = RecordingStore()
    store._st[].fail_conditional = True
    var consumer = _consumer(store, FlushRetryPolicy.single_attempt())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(Int(consumer.stats().publish_failures), 1, "failure counted")
    assert_equal(Int(consumer.stats().splits_published), 0, "nothing published")
    var puts = _put_keys(store.log())
    assert_equal(len(puts), 1, "the object was written once")
    # The object exists but no summary names it.
    var bytes = store.get(Path.parse(puts[0]))
    assert_true(len(bytes) > 0, "the orphan object is in the store")
    assert_true(
        _count_prefix(store.log(), "cond:") >= 1,
        "the summary append was attempted after the PUT",
    )
    assert_equal(_live(store), 0, "nothing is live")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the gate does not leak")


def test_transient_put_failure_is_retried_under_the_same_key() raises:
    var store = RecordingStore()
    store._st[].fail_put_times = 1
    var consumer = _consumer(store, FlushRetryPolicy.fast_test())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(Int(consumer.stats().splits_published), 1, "the retry landed")
    assert_equal(Int(consumer.stats().publish_failures), 0, "no failure counted")
    var puts = _put_keys(store.log())
    assert_equal(len(puts), 2, "a failed put and a successful put")
    assert_equal(puts[0], puts[1], "the retry writes the same object key")
    assert_equal(_live(store), 1, "the split is live once")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the gate is released")


# -----------------------------------------------------------------------------
# Split uuids: stable across a restart.
# -----------------------------------------------------------------------------


def _first_put_key(
    store: RecordingStore, disc: UInt8, epoch_us: Int64
) raises -> String:
    var before = len(_put_keys(store.log()))
    var consumer = _consumer(
        store, FlushRetryPolicy.single_attempt(), disc, epoch_us
    )
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 3), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    var puts = _put_keys(store.log())
    assert_equal(len(puts), before + 1, "one new object")
    return puts[before]


def test_a_restarted_consumer_does_not_reuse_split_keys() raises:
    var store = RecordingStore()
    var first = _first_put_key(store, UInt8(0), Int64(1_000_000))
    # A restarted process: the sequence starts at 0 again, the epoch is later.
    var second = _first_put_key(store, UInt8(0), Int64(2_000_000))
    assert_true(first != second, "different install epochs, different keys")
    # The same epoch and discriminant would overwrite: the epoch is what keeps
    # the two keys apart.
    var third = _first_put_key(store, UInt8(0), Int64(2_000_000))
    assert_equal(second, third, "the key depends on (disc, epoch, sequence)")
    var other_worker = _first_put_key(store, UInt8(1), Int64(2_000_000))
    assert_true(second != other_worker, "a different worker, a different key")


def test_a_restart_over_the_same_store_keeps_earlier_splits() raises:
    var store = RecordingStore()
    for epoch in range(2):
        var consumer = _consumer(
            store,
            FlushRetryPolicy.single_attempt(),
            UInt8(0),
            Int64(1_000_000 * (epoch + 1)),
        )
        var gate = InFlightBytesGate(Int64(1_000_000))
        var handoff = LogIndexHandoff(8)
        assert_true(_offer(handoff, gate, 3), "offer accepted")
        _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(_live(store), 2, "both consumers' splits are live")
    var keys = _put_keys(store.log())
    assert_equal(len(keys), 2, "two objects")
    assert_true(keys[0] != keys[1], "the second did not overwrite the first")


# -----------------------------------------------------------------------------
# Retry: exhaustion and the budget cutoff.
# -----------------------------------------------------------------------------


def test_retry_exhaustion_counts_one_failure_after_every_attempt() raises:
    var store = RecordingStore()
    store._st[].fail_put_times = 3
    var consumer = _consumer(store, FlushRetryPolicy.fast_test())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(len(_put_keys(store.log())), 3, "all three attempts ran")
    assert_equal(Int(consumer.stats().publish_failures), 1, "one failure counted")
    assert_equal(Int(consumer.stats().splits_published), 0, "nothing published")
    assert_equal(_count_prefix(store.log(), "cond:"), 0, "no summary appended")
    assert_equal(_live(store), 0, "nothing is live")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the gate does not leak")


def test_the_third_attempt_can_still_land() raises:
    var store = RecordingStore()
    store._st[].fail_put_times = 2
    var consumer = _consumer(store, FlushRetryPolicy.fast_test())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(len(_put_keys(store.log())), 3, "two failures then a success")
    assert_equal(Int(consumer.stats().splits_published), 1, "the last attempt landed")
    assert_equal(Int(consumer.stats().publish_failures), 0, "no failure counted")
    assert_equal(_live(store), 1, "the split is live")


def test_the_budget_stops_the_retry_before_a_backoff() raises:
    var store = RecordingStore()
    store._st[].fail_put = True
    # A 1 s backoff against a 1 us budget: the budget check fires after the first
    # failure, before any sleep, so exactly one attempt runs.
    var consumer = _consumer(
        store, FlushRetryPolicy(3, Int64(1_000_000), Int64(1))
    )
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(len(_put_keys(store.log())), 1, "the budget cut the retry short")
    assert_equal(Int(consumer.stats().publish_failures), 1, "one failure counted")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the gate does not leak")


def test_a_zero_budget_means_attempts_only() raises:
    var store = RecordingStore()
    store._st[].fail_put = True
    var consumer = _consumer(store, FlushRetryPolicy(3, Int64(1), Int64(0)))
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    assert_true(_offer(handoff, gate, 8), "offer accepted")
    _ = consumer.drive_once(handoff, gate, Int64(0))
    assert_equal(len(_put_keys(store.log())), 3, "all attempts ran with no budget")


# -----------------------------------------------------------------------------
# Sequence: two flushes of one consumer never share a key.
# -----------------------------------------------------------------------------


def test_consecutive_flushes_of_one_consumer_write_distinct_keys() raises:
    var store = RecordingStore()
    var consumer = _consumer(store, FlushRetryPolicy.single_attempt())
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    for _ in range(2):
        assert_true(_offer(handoff, gate, 3), "offer accepted")
        assert_equal(consumer.drive_once(handoff, gate, Int64(0)), 1, "one unit")
    var keys = _put_keys(store.log())
    assert_equal(len(keys), 2, "two objects")
    assert_true(keys[0] != keys[1], "the second flush did not overwrite the first")
    assert_equal(_live(store), 2, "both splits are live")


def test_every_epoch_byte_changes_the_split_key() raises:
    var store = RecordingStore()
    var base = _first_put_key(store, UInt8(0), Int64(0))
    # One epoch bit in each of the seven epoch bytes, and a low-byte-only step.
    for i in range(7):
        var key = _first_put_key(store, UInt8(0), Int64(1) << Int64(i * 8))
        assert_true(key != base, "epoch byte " + String(i) + " is in the key")
    var low = _first_put_key(store, UInt8(0), Int64(1_000_000))
    var low_next = _first_put_key(store, UInt8(0), Int64(1_000_001))
    assert_true(low != low_next, "a one-microsecond epoch step is in the key")
    # Distinct high bytes with identical low bytes.
    var hi_a = _first_put_key(store, UInt8(0), Int64(1) << Int64(48))
    var hi_b = _first_put_key(store, UInt8(0), Int64(2) << Int64(48))
    assert_true(hi_a != hi_b, "epochs that differ only in a high byte differ")


# -----------------------------------------------------------------------------
# The batch drain survives a raise from the sink.
# -----------------------------------------------------------------------------


struct _FailOnNth(_BatchAcceptor):
    var calls: Int
    var fail_on: Int
    var rows_seen: Int

    def __init__(out self, fail_on: Int):
        self.calls = 0
        self.fail_on = fail_on
        self.rows_seen = 0

    def accept(mut self, var rb: RecordBatch) raises:
        self.calls += 1
        if self.calls == self.fail_on:
            raise Error("injected accept failure")
        self.rows_seen += rb.num_rows()


def _three_batches() raises -> Slab[RecordBatch]:
    var batches = Slab[RecordBatch]()
    for n in range(1, 4):
        batches.append(log_views_to_record_batch(_login_views(n)))
    return batches^


def test_a_raising_accept_leaves_the_slab_empty_and_reraises() raises:
    var batches = _three_batches()
    assert_equal(len(batches), 3, "three buffered batches")
    var acceptor = _FailOnNth(2)
    var raised = False
    try:
        _drain_batches_into(acceptor, batches)
    except e:
        raised = True
        assert_true("injected accept failure" in String(e), "the error is the sink's")
    assert_true(raised, "the failure propagates")
    assert_equal(acceptor.calls, 2, "the third batch never reached the sink")
    assert_equal(acceptor.rows_seen, 1, "only the first batch was accepted")
    # The slab claims no slot: its destructor has nothing left to destroy.
    assert_equal(len(batches), 0, "every slot was taken or dropped")


def test_a_clean_drain_feeds_every_batch_in_order() raises:
    var batches = _three_batches()
    var acceptor = _FailOnNth(99)
    _drain_batches_into(acceptor, batches)
    assert_equal(acceptor.calls, 3, "all three batches were fed")
    assert_equal(acceptor.rows_seen, 6, "1 + 2 + 3 rows")
    assert_equal(len(batches), 0, "the slab is empty")


# -----------------------------------------------------------------------------
# Handoff: the bound.
# -----------------------------------------------------------------------------


def test_handoff_rejects_when_the_depth_cap_is_reached() raises:
    var gate = InFlightBytesGate(Int64(10_000_000))
    var handoff = LogIndexHandoff(2)
    assert_true(_offer(handoff, gate, 1), "first fits")
    assert_true(_offer(handoff, gate, 2), "second fits")
    var held = gate.in_flight_bytes()
    assert_equal(handoff.depth(), 2, "two queued")
    assert_false(_offer(handoff, gate, 3), "third is rejected, not blocked")
    assert_equal(handoff.depth(), 2, "the queue did not grow")
    assert_equal(Int(handoff.depth_rejection_count()), 1, "rejection counted")
    assert_equal(Int(gate.rejection_count()), 0, "not a byte rejection")
    assert_equal(
        gate.in_flight_bytes(), held, "the rejected offer gave its bytes back"
    )
    assert_equal(Int(handoff.offered_count()), 2, "two offered")

    # The queue comes back in FIFO order and is empty afterwards.
    var units = handoff.drain_all()
    assert_equal(len(units), 2, "drained both")
    assert_equal(Int(units[0].row_count), 1, "first in, first out")
    assert_equal(Int(units[1].row_count), 2, "second after it")
    units.set_len_unchecked(0)
    assert_equal(Int(handoff.polled_count()), 2, "two polled")
    assert_equal(handoff.depth(), 0, "empty after the drain")
    assert_true(_offer(handoff, gate, 3), "accepts again once drained")


def test_handoff_rejects_when_the_byte_cap_is_reached() raises:
    # 5 rows reserve about 1000 bytes each; a 1500-byte cap admits one.
    var gate = InFlightBytesGate(Int64(1500))
    var handoff = LogIndexHandoff(64)
    assert_true(_offer(handoff, gate, 5), "first fits under the cap")
    assert_false(_offer(handoff, gate, 5), "second would exceed the cap")
    assert_equal(Int(gate.rejection_count()), 1, "byte rejection counted")
    assert_equal(Int(handoff.depth_rejection_count()), 0, "not a depth rejection")
    assert_equal(handoff.depth(), 1, "only the first is queued")
    assert_true(
        gate.in_flight_bytes() <= gate.cap_bytes(), "never above the cap"
    )


def test_a_drain_of_an_idle_queue_is_empty_and_the_queue_keeps_working() raises:
    var gate = InFlightBytesGate(Int64(10_000_000))
    var handoff = LogIndexHandoff(4)
    var none = handoff.drain_all()
    assert_equal(len(none), 0, "nothing queued, nothing drained")
    for i in range(1, 4):
        assert_true(_offer(handoff, gate, i), "offer accepted")
        var units = handoff.drain_all()
        assert_equal(len(units), 1, "the unit offered since the last drain")
        assert_equal(Int(units[0].row_count), i, "the right unit")
        units.set_len_unchecked(0)
    assert_equal(handoff.depth(), 0, "empty at the end")


def test_an_empty_offer_reserves_nothing() raises:
    var gate = InFlightBytesGate(Int64(1500))
    var handoff = LogIndexHandoff(1)
    assert_true(offer_log_views(handoff, gate, List[LogRecordView]()), "no-op")
    assert_equal(gate.in_flight_bytes(), Int64(0), "nothing reserved")
    assert_equal(handoff.depth(), 0, "nothing queued")


def test_gate_admits_an_oversize_reservation_only_when_empty() raises:
    var gate = InFlightBytesGate(Int64(100))
    assert_true(gate.try_reserve(Int64(500)), "oversize runs alone on an empty pool")
    assert_false(gate.try_reserve(Int64(1)), "nothing else while it is held")
    assert_equal(Int(gate.rejection_count()), 1, "rejection counted")
    gate.release(Int64(10_000))
    assert_equal(gate.in_flight_bytes(), Int64(0), "a release clamps at zero")
    assert_true(gate.try_reserve(Int64(60)), "fits")
    assert_false(gate.try_reserve(Int64(60)), "would exceed")


# -----------------------------------------------------------------------------
# Flush thread: shutdown publishes the last partial segment.
# -----------------------------------------------------------------------------


def test_flush_thread_shutdown_publishes_the_partial_segment() raises:
    var store = RecordingStore()
    # Ceilings far away: nothing flushes until shutdown.
    var consumer = _consumer(
        store,
        FlushRetryPolicy.single_attempt(),
        UInt8(0),
        Int64(-1),
        Int64(1_000_000_000),
    )
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    var thread = OffCoreFlushThread[RecordingStore](consumer^)
    assert_true(_offer(handoff, gate, 4), "offer accepted")
    assert_equal(thread.drive_step(handoff, gate, Int64(0)), 1, "one unit")
    assert_equal(Int(thread.consumer_stats_splits()), 0, "held under the ceilings")
    assert_equal(_live(store), 0, "nothing published yet")
    # With the flag already set the loop body does not run; the final flush does.
    thread.request_shutdown()
    thread.run_until_shutdown(handoff, gate)
    assert_equal(Int(thread.consumer_stats_splits()), 1, "the final flush published")
    assert_equal(Int(thread.consumer_stats_failures()), 0, "no failures")
    assert_equal(_live(store), 1, "the split is live")
    assert_equal(gate.in_flight_bytes(), Int64(0), "the gate is released")
    thread.final_flush(gate)
    assert_equal(Int(thread.consumer_stats_splits()), 1, "a second flush is a no-op")


def test_shutdown_drains_units_the_producer_offered_last() raises:
    var store = RecordingStore()
    var consumer = _consumer(
        store,
        FlushRetryPolicy.single_attempt(),
        UInt8(0),
        Int64(-1),
        Int64(1_000_000_000),
    )
    var gate = InFlightBytesGate(Int64(1_000_000))
    var handoff = LogIndexHandoff(8)
    var thread = OffCoreFlushThread[RecordingStore](consumer^)
    # The unit is still in the handoff when the flag is set: the loop body never
    # runs, so only the shutdown path can pick it up.
    assert_true(_offer(handoff, gate, 4), "offer accepted")
    assert_equal(handoff.depth(), 1, "the unit is queued")
    thread.request_shutdown()
    thread.request_shutdown()  # idempotent
    thread.run_until_shutdown(handoff, gate)
    assert_equal(handoff.depth(), 0, "the handoff was drained")
    assert_equal(Int(thread.consumer_stats_splits()), 1, "the queued unit was published")
    assert_equal(_live(store), 1, "the split is live")
    assert_equal(gate.in_flight_bytes(), Int64(0), "its reservation was released")


def test_the_thread_handle_is_recorded() raises:
    var store = RecordingStore()
    var consumer = _consumer(store, FlushRetryPolicy.single_attempt())
    var thread = OffCoreFlushThread[RecordingStore](consumer^)
    assert_equal(Int(thread.thread_id()), 0, "no thread yet")
    thread.set_thread_id(Int64(42))
    assert_equal(Int(thread.thread_id()), 42, "the owner's handle")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
