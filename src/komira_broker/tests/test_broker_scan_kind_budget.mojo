# =============================================================================
# test_broker_scan_kind_budget — `komira.broker.topic` over SEVERAL partitions.
# =============================================================================
#
# The multi-partition half of `test_broker_scan_kind.mojo` (same
# shape: `build_binding` -> `resolve_for_execution` -> `drain_scan` over the
# in-memory conditional store, NO `EngineContext`). Every byte budget here is
# a MEASURED multiple of real segment sizes, so the budget's own arithmetic
# can fail a test — a 1-byte budget only proves the first segment is exempt.
#
# THE SCAN-WIDE BUDGET IS THE DRAIN'S. `drain_scan(max_bytes=)` cuts between
# polls, and a poll returns its first unit whole, so the cut overshoots by at
# most one segment: it is not Kafka's exact fetch cut, and these tests do not
# pin one. What they pin instead is that the cut is REPORTED exactly: the rows
# returned for each partition are exactly `[start, next_offset.<p>)`
# ("rows == cut"). The exact per-partition Kafka cut (`partition_max_bytes`)
# is the split reader's, and is pinned exactly.
#
# Pinned here:
#   * a drain budget that runs out inside partition 0 returns nothing from
#     partition 1 (never opened), and every partition's rows are exactly
#     `[start, next_offset.<p>)`. INVERTED from the single-pass scan, which
#     refused partition 0's third segment at `2*S2 + S1`; the drain returns
#     it (one segment of overshoot) and says so in `next_offset.0`;
#   * a PER-PARTITION budget returns k segments from EACH partition (the
#     partition's running count resets per partition), exactly;
#   * KIP-74 exempts the first NON-EMPTY partition's first segment, not
#     partition 0's;
#   * `start_offsets`: each partition starts at its own offset, re-ordered
#     with the canonical partition list, and both refusals are named;
#   * a MULTI-partition scan reads the snapshot its PLAN reads (the plan is
#     the authority; the token is freshness only): a produce between resolve
#     and plan IS returned, and `high_watermark.<p>` is exactly what was
#     read.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.string_array import StringArray
from komira_scan_source.scan_binding import ScanBinding
from komira_scan_source.scan_kind_registry import ScanKindDescriptor
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import (
    ScanOpened,
    ScanRequest,
    ScanSourceResolver,
)
from komira_scan_resolver.scan_split import (
    DrainedSplit,
    ScanSplit,
    ScanSplitPlan,
    SplitDelta,
)

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    _manifest_prefix,
    _topic_config_key,
)
from komira_broker.broker_scan_binding import (
    BROKER_PARAM_PARTITION_MAX_BYTES,
    BROKER_PARAM_PARTITIONS,
    BROKER_PARAM_START_OFFSETS,
    BROKER_PARAM_TOPIC,
)
from komira_broker.broker_scan_kind import (
    BROKER_RESOLVED_HIGH_WATERMARK,
    BROKER_RESOLVED_NEXT_OFFSET,
    BrokerScanRuntime,
    broker_resolved_key,
    broker_split_key,
)
from komira_broker.broker_split_reader import BrokerSplitReader
from komira_broker.consume_core import ConsumeCore

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _CLUSTER = "bskb"


# =============================================================================
# helpers
# =============================================================================


def _kv_schema() raises -> Schema:
    return Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.STRING.type_id],
        dtypes=[DType.int64, DType.uint8],
        nullables=[False, True],
    )


def _kv_keys(keys: List[Int64]) raises -> RecordBatch:
    """Keys are two-digit, so every value `v<k>` has the same length and two
    segments of the same row count have the same byte size."""
    var n = len(keys)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(n):
        karr.set(i, keys[i])
        vals.append(String("v") + String(keys[i]))
        valid.append(True)
    var kcol = Column.from_primitive[DType.int64](karr^)
    var vcol = Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    return RecordBatch.from_typed_columns_2(_kv_schema(), kcol^, vcol^)


def _write_config(store: _Store, topic: String, num_partitions: Int) raises:
    var cfg = BrokerTopicConfig(num_partitions, List[String](), _kv_schema())
    _ = store.put(
        Path.parse(_topic_config_key(String(_CLUSTER), topic)), cfg.encode()
    )


def _produce(store: _Store, topic: String, partition: Int64, keys: List[Int64]) raises:
    """One produce == one flushed segment == one manifest chunk."""
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_manifest_prefix(String(_CLUSTER), topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    var b = BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=String(_CLUSTER),
        topic=topic,
        partition=partition,
        broker_id=String("broker-A"),
    )
    _ = b.produce(_kv_keys(keys), Int64(1000))
    _ = b.flush_if_buffered(Int64(1000))


def _seg_sizes(store: _Store, topic: String, partition: Int64) raises -> List[Int64]:
    """The byte size the kind charges for each segment of a partition: the
    length of the segment's IPC stream, read the way the split reader reads
    it."""
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_manifest_prefix(String(_CLUSTER), topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    var core = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=String(_CLUSTER),
        topic=String(topic),
        partition=partition,
    )
    var index = core.resolve_index()
    var out = List[Int64]()
    for i in range(len(index)):
        var read = core.read_segment(index[i].copy())
        out.append(Int64(len(read^.take_stream_bytes())))
    return out^


def _runtime(store: _Store) -> BrokerScanRuntime[_Store]:
    return BrokerScanRuntime[_Store](store.clone(), String(_CLUSTER))


def _params(topic: String) -> ScanParams:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String(topic))
    return p^


def _run(
    rt: BrokerScanRuntime[_Store], params: ScanParams, max_bytes: Int64 = -1
) raises -> ScanOpened:
    var cached = rt.build_binding(params)
    var exec_binding = resolve_for_execution(rt, cached)
    return drain_scan(rt, ScanRequest(exec_binding^), max_bytes=max_bytes)


struct _CutWitness(ScanSourceResolver, Movable, Deinitable):
    """The broker kind, unchanged, plus `cut.<split_key>` in the drained side
    channel: what the drain itself reported for each split. The broker's own
    `resolve_drained` reports only `next_offset.<p>`, which is right whether
    or not the drain called the split cut, so it cannot witness the cut."""

    comptime Reader = BrokerSplitReader[_Store]

    var _rt: BrokerScanRuntime[_Store]

    def __init__(out self, var rt: BrokerScanRuntime[_Store]):
        self._rt = rt^

    def epoch(self) -> UInt64:
        return self._rt.epoch()

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return self._rt.is_bound(kind_id, handle)

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        return self._rt.resolve_snapshot(binding)

    def descriptor(self) -> ScanKindDescriptor:
        return self._rt.descriptor()

    def position_version(self) -> UInt8:
        return self._rt.position_version()

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        return self._rt.build_binding(params)

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        return self._rt.plan_splits(req)

    def discover_splits(
        self, req: ScanRequest, known: List[String]
    ) raises -> SplitDelta:
        return self._rt.discover_splits(req, known)

    def open_split(
        self, req: ScanRequest, split: ScanSplit
    ) raises -> BrokerSplitReader[_Store]:
        return self._rt.open_split(req, split)

    def resolve_drained(
        self,
        req: ScanRequest,
        var resolved: ScanParams,
        stopped: List[DrainedSplit],
    ) raises -> ScanParams:
        var out = self._rt.resolve_drained(req, resolved^, stopped)
        for i in range(len(stopped)):
            out.put_bool(String("cut.") + stopped[i].split_key, stopped[i].cut)
        return out^


def _run_witnessed(
    store: _Store, params: ScanParams, max_bytes: Int64 = -1
) raises -> ScanOpened:
    var w = _CutWitness(_runtime(store))
    var cached = w.build_binding(params)
    var exec_binding = resolve_for_execution(w, cached)
    return drain_scan(w, ScanRequest(exec_binding^), max_bytes=max_bytes)


def _cut(o: ScanOpened, topic: String, p: Int64) raises -> Bool:
    return o.resolved.get_bool(
        String("cut.") + broker_split_key(topic, p)
    )


def _col_i64(o: ScanOpened, col: Int) raises -> List[Int64]:
    var out = List[Int64]()
    for i in range(o.num_batches()):
        ref b = o.batches[][i]
        for r in range(b.num_rows()):
            out.append(Int64(b.column_value(col, r)))
    return out^


def _eq(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + String(" (row count)"))
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + String(" row ") + String(i))


def _next(o: ScanOpened, p: Int64) raises -> Int64:
    return o.resolved.get_i64(
        broker_resolved_key(String(BROKER_RESOLVED_NEXT_OFFSET), p)
    )


def _hwm(o: ScanOpened, p: Int64) raises -> Int64:
    return o.resolved.get_i64(
        broker_resolved_key(String(BROKER_RESOLVED_HIGH_WATERMARK), p)
    )


def _rows_in(o: ScanOpened, p: Int64) raises -> Int64:
    """Rows actually returned for partition `p` (the `__partition` column)."""
    var parts = _col_i64(o, 2)
    var n = Int64(0)
    for i in range(len(parts)):
        if parts[i] == p:
            n += 1
    return n


# =============================================================================
# 1. the DRAIN's budget: rows == cut
# =============================================================================


def _keys_in(o: ScanOpened, p: Int64) raises -> List[Int64]:
    """The keys returned for partition `p`, in order."""
    var keys = _col_i64(o, 0)
    var parts = _col_i64(o, 2)
    var out = List[Int64]()
    for i in range(len(keys)):
        if parts[i] == p:
            out.append(keys[i])
    return out^


def _assert_rows_are_the_cut(
    o: ScanOpened, p: Int64, start: Int64, keys_at: List[Int64], what: String
) raises:
    """The rows returned for partition `p` are EXACTLY offsets
    `[start, next_offset.<p>)`, whose keys are `keys_at[offset]`: a
    continuation from `next_offset.<p>` neither skips nor repeats a row."""
    var want = List[Int64]()
    for off in range(Int(start), Int(_next(o, p))):
        want.append(keys_at[off])
    _eq(_keys_in(o, p), want, what + String(" (partition ") + String(p) + String(")"))


def test_drain_budget_rows_are_exactly_the_reported_cut() raises:
    var store = _Store()
    var topic = String("tot")
    _write_config(store, topic, 2)
    _produce(store, topic, Int64(0), [Int64(11), Int64(12)])  # p0 0-1
    _produce(store, topic, Int64(0), [Int64(13), Int64(14)])  # p0 2-3
    _produce(store, topic, Int64(0), [Int64(15), Int64(16)])  # p0 4-5
    _produce(store, topic, Int64(1), [Int64(21)])  # p1 0
    var s0 = _seg_sizes(store, topic, Int64(0))
    var s1 = _seg_sizes(store, topic, Int64(1))
    assert_equal(len(s0), 3)
    assert_equal(s0[0], s0[1], "fixture: equal p0 segments")
    assert_equal(s0[1], s0[2], "fixture: equal p0 segments")
    var S2 = s0[0]
    var S1 = s1[0]
    assert_true(S1 < S2, "fixture: p1's one-row segment is smaller")
    var p0_keys: List[Int64] = [
        Int64(11), Int64(12), Int64(13), Int64(14), Int64(15), Int64(16)
    ]
    var p1_keys: List[Int64] = [Int64(21)]
    var rt = _runtime(store)

    # S2 + 1: the budget runs out INSIDE p0's second segment. The drain checks
    # between polls, so that segment is returned whole (one segment of
    # overshoot), p1 is never opened, and the cut says so.
    var o1 = _run(rt, _params(topic), S2 + 1)
    _eq(
        _col_i64(o1, 0),
        [Int64(11), Int64(12), Int64(13), Int64(14)],
        String("two p0 segments, then the drain is spent"),
    )
    assert_equal(_next(o1, Int64(0)), Int64(4), "p0 resumes at its third segment")
    assert_equal(_next(o1, Int64(1)), Int64(0), "p1 was never opened")
    _assert_rows_are_the_cut(o1, Int64(0), Int64(0), p0_keys, String("S2+1"))
    _assert_rows_are_the_cut(o1, Int64(1), Int64(0), p1_keys, String("S2+1"))

    # 2*S2 + S1: INVERTED. The single-pass scan refused p0's third segment
    # here (2*S2 left S1, less than S2); the drain is not spent after two
    # segments, so it polls p0 again and the third comes back whole. p1 is
    # never opened, and `next_offset` reports exactly that.
    var o2 = _run(rt, _params(topic), 2 * S2 + S1)
    _eq(
        _col_i64(o2, 0),
        [Int64(11), Int64(12), Int64(13), Int64(14), Int64(15), Int64(16)],
        String("p0 whole, then the drain is spent"),
    )
    assert_equal(_next(o2, Int64(0)), Int64(6))
    assert_equal(_next(o2, Int64(1)), Int64(0), "p1 returned nothing")
    _assert_rows_are_the_cut(o2, Int64(0), Int64(0), p0_keys, String("2*S2+S1"))
    _assert_rows_are_the_cut(o2, Int64(1), Int64(0), p1_keys, String("2*S2+S1"))

    # EXACTLY 3*S2: all of p0 fits to the byte, the drain is spent, and p1 is
    # not opened.
    var o3 = _run(rt, _params(topic), 3 * S2)
    _eq(
        _col_i64(o3, 0),
        [Int64(11), Int64(12), Int64(13), Int64(14), Int64(15), Int64(16)],
        String("an exact fit is returned"),
    )
    assert_equal(_next(o3, Int64(0)), Int64(6))
    assert_equal(_next(o3, Int64(1)), Int64(0))

    # 3*S2 + S1: everything.
    var everything = _run(rt, _params(topic), 3 * S2 + S1)
    assert_equal(everything.num_rows(), 7)
    assert_equal(_next(everything, Int64(1)), Int64(1))
    _assert_rows_are_the_cut(everything, Int64(0), Int64(0), p0_keys, String("all"))
    _assert_rows_are_the_cut(everything, Int64(1), Int64(0), p1_keys, String("all"))


# =============================================================================
# 2. the PER-PARTITION budget
# =============================================================================


def test_partition_budget_returns_k_segments_from_each_partition() raises:
    var store = _Store()
    var topic = String("per")
    _write_config(store, topic, 2)
    _produce(store, topic, Int64(0), [Int64(11), Int64(12)])
    _produce(store, topic, Int64(0), [Int64(13), Int64(14)])
    _produce(store, topic, Int64(0), [Int64(15), Int64(16)])
    _produce(store, topic, Int64(1), [Int64(21), Int64(22)])
    _produce(store, topic, Int64(1), [Int64(23), Int64(24)])
    _produce(store, topic, Int64(1), [Int64(25), Int64(26)])
    var s0 = _seg_sizes(store, topic, Int64(0))
    var s1 = _seg_sizes(store, topic, Int64(1))
    var S = s0[0]
    for i in range(3):
        assert_equal(s0[i], S, "fixture: equal segments")
        assert_equal(s1[i], S, "fixture: equal segments")
    var rt = _runtime(store)

    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), 2 * S)
    var o = _run(rt, p)
    _eq(
        _col_i64(o, 0),
        [
            Int64(11), Int64(12), Int64(13), Int64(14),
            Int64(21), Int64(22), Int64(23), Int64(24),
        ],
        String("k=2 segments from each partition"),
    )
    assert_equal(_next(o, Int64(0)), Int64(4))
    assert_equal(_next(o, Int64(1)), Int64(4))
    # The partition budget ENDED each split short of its stop (offset 6), so
    # the drain reports both cut: offsets 4..5 are still there to read.
    var ow = _run_witnessed(store, p)
    assert_equal(_next(ow, Int64(0)), Int64(4))
    assert_true(_cut(ow, topic, Int64(0)), "p0, budget-cut at 4 of 6, is cut")
    assert_true(_cut(ow, topic, Int64(1)), "p1, budget-cut at 4 of 6, is cut")
    # A budget the partitions fit in reads each to its stop: not cut.
    var r = _params(topic)
    r.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), 3 * S)
    var whole = _run_witnessed(store, r)
    assert_equal(_next(whole, Int64(0)), Int64(6))
    assert_true(not _cut(whole, topic, Int64(0)), "p0 read to its stop")
    assert_true(not _cut(whole, topic, Int64(1)), "p1 read to its stop")

    # A drain budget on top ends the read inside p1: 2*S (p0) + S (p1). The
    # segment p0's partition budget refused is not charged to the drain.
    var q = _params(topic)
    q.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), 2 * S)
    var oq = _run(rt, q, 3 * S)
    _eq(
        _col_i64(oq, 0),
        [Int64(11), Int64(12), Int64(13), Int64(14), Int64(21), Int64(22)],
        String("partition budget, then the total"),
    )
    assert_equal(_next(oq, Int64(0)), Int64(4))
    assert_equal(_next(oq, Int64(1)), Int64(2))


# =============================================================================
# 3. KIP-74: the first NON-EMPTY partition
# =============================================================================


def test_kip74_exempts_the_first_non_empty_partition() raises:
    var store = _Store()
    var topic = String("kip")
    _write_config(store, topic, 2)
    # p0 has NO data; p1 has two segments.
    _produce(store, topic, Int64(1), [Int64(21), Int64(22)])
    _produce(store, topic, Int64(1), [Int64(23), Int64(24)])
    var rt = _runtime(store)

    var o = _run(rt, _params(topic), Int64(1))
    _eq(_col_i64(o, 0), [Int64(21), Int64(22)], String("p1's first segment, whole"))
    assert_equal(_next(o, Int64(0)), Int64(0))
    assert_equal(_next(o, Int64(1)), Int64(2))

    var q = _params(topic)
    q.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), Int64(1))
    _eq(
        _col_i64(_run(rt, q), 0),
        [Int64(21), Int64(22)],
        String("per-partition budget, p0 empty"),
    )

    # p0 HAS data but its start is AT its high-watermark: still empty.
    var store2 = _Store()
    _write_config(store2, topic, 2)
    _produce(store2, topic, Int64(0), [Int64(11), Int64(12)])
    _produce(store2, topic, Int64(1), [Int64(21), Int64(22)])
    _produce(store2, topic, Int64(1), [Int64(23), Int64(24)])
    var r = _params(topic)
    r.put_str(String(BROKER_PARAM_PARTITIONS), String("0,1"))
    r.put_str(String(BROKER_PARAM_START_OFFSETS), String("2,0"))
    var o2 = _run(_runtime(store2), r, Int64(1))
    _eq(_col_i64(o2, 0), [Int64(21), Int64(22)], String("p0 at its HWM"))
    assert_equal(_next(o2, Int64(0)), Int64(2))
    assert_equal(_next(o2, Int64(1)), Int64(2))


# =============================================================================
# 4. start_offsets
# =============================================================================


def test_start_offsets_follow_their_partition() raises:
    var store = _Store()
    var topic = String("so")
    _write_config(store, topic, 2)
    _produce(store, topic, Int64(0), [Int64(11), Int64(12)])  # p0 0-1
    _produce(store, topic, Int64(0), [Int64(13), Int64(14)])  # p0 2-3
    _produce(store, topic, Int64(1), [Int64(21), Int64(22)])  # p1 0-1
    _produce(store, topic, Int64(1), [Int64(23), Int64(24)])  # p1 2-3
    var rt = _runtime(store)

    # Written as "1,0" / "3,1": p1 starts at 3, p0 at 1.
    var p = _params(topic)
    p.put_str(String(BROKER_PARAM_PARTITIONS), String("1,0"))
    p.put_str(String(BROKER_PARAM_START_OFFSETS), String("3,1"))
    var b = rt.build_binding(p)
    assert_equal(b.params.get_str(String(BROKER_PARAM_PARTITIONS)), String("0,1"))
    assert_equal(
        b.params.get_str(String(BROKER_PARAM_START_OFFSETS)),
        String("1,3"),
        "re-ordered with the canonical partition list",
    )
    var o = _run(rt, p)
    _eq(
        _col_i64(o, 0),
        [Int64(12), Int64(13), Int64(14), Int64(24)],
        String("p0 from 1, p1 from 3"),
    )
    _eq(_col_i64(o, 2), [Int64(0), Int64(0), Int64(0), Int64(1)], String("__partition"))

    # Named twice with the SAME offset is one partition.
    var same = _params(topic)
    same.put_str(String(BROKER_PARAM_PARTITIONS), String("0,1,0"))
    same.put_str(String(BROKER_PARAM_START_OFFSETS), String("1,3,1"))
    assert_equal(
        rt.build_binding(same).params.get_str(String(BROKER_PARAM_START_OFFSETS)),
        String("1,3"),
    )

    var twice = _params(topic)
    twice.put_str(String(BROKER_PARAM_PARTITIONS), String("0,1,0"))
    twice.put_str(String(BROKER_PARAM_START_OFFSETS), String("1,3,2"))
    with assert_raises(contains="partition 0 is named twice with different start offsets"):
        _ = rt.build_binding(twice)

    var short = _params(topic)
    short.put_str(String(BROKER_PARAM_PARTITIONS), String("0,1"))
    short.put_str(String(BROKER_PARAM_START_OFFSETS), String("1"))
    with assert_raises(contains="'start_offsets' has 1 elements for 2 partitions"):
        _ = rt.build_binding(short)


# =============================================================================
# 5. the multi-partition snapshot: the plan is the authority
# =============================================================================


def test_multi_partition_reads_its_own_snapshot_and_reports_it() raises:
    var store = _Store()
    var topic = String("mp")
    _write_config(store, topic, 2)
    _produce(store, topic, Int64(0), [Int64(11), Int64(12)])
    _produce(store, topic, Int64(1), [Int64(21)])
    var rt = _runtime(store)
    var cached = rt.build_binding(_params(topic))
    assert_equal(cached.params.get_str(String(BROKER_PARAM_PARTITIONS)), String("0,1"))
    var e = resolve_for_execution(rt, cached)
    assert_equal(e.snapshot_token, UInt64(3), "the token is the SUM of HWMs")

    # A produce lands between resolve and plan.
    _produce(store, topic, Int64(1), [Int64(22), Int64(23)])

    var o = drain_scan(rt, ScanRequest(e^))
    _eq(
        _col_i64(o, 0),
        [Int64(11), Int64(12), Int64(21), Int64(22), Int64(23)],
        String("the new rows ARE returned"),
    )
    # The side channel, not the token, is the authority: it names exactly the
    # rows read, per partition.
    assert_equal(_hwm(o, Int64(0)), Int64(2))
    assert_equal(_hwm(o, Int64(1)), Int64(3))
    assert_equal(_rows_in(o, Int64(0)), _hwm(o, Int64(0)))
    assert_equal(_rows_in(o, Int64(1)), _hwm(o, Int64(1)))


def main() raises:
    var suite = TestSuite()
    suite.test[test_drain_budget_rows_are_exactly_the_reported_cut]()
    suite.test[test_partition_budget_returns_k_segments_from_each_partition]()
    suite.test[test_kip74_exempts_the_first_non_empty_partition]()
    suite.test[test_start_offsets_follow_their_partition]()
    suite.test[test_multi_partition_reads_its_own_snapshot_and_reports_it]()
    suite^.run()
