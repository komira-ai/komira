# =============================================================================
# test_broker_scan_kind_budget — `komira.broker.topic` over SEVERAL partitions.
# =============================================================================
#
# The multi-partition half of `test_broker_scan_kind.mojo` (same
# shape: `build_binding` -> `resolve_for_execution` -> `open_scan` over the
# in-memory conditional store, NO `EngineContext`). Every byte budget here is
# a MEASURED multiple of real segment sizes, so the budget's own arithmetic
# can fail a test — a 1-byte budget only proves the first segment is exempt.
#
# Pinned here:
#   * a TOTAL budget fitting exactly N>1 segments ends the scan in the middle
#     of partition 0 and returns nothing from partition 1, even when
#     partition 1's segment alone would still fit (the scan is FULL);
#   * a PER-PARTITION budget returns k segments from EACH partition (the
#     partition's running count resets per partition);
#   * KIP-74 exempts the first NON-EMPTY partition's first segment, not
#     partition 0's;
#   * `start_offsets`: each partition starts at its own offset, re-ordered
#     with the canonical partition list, and both refusals are named;
#   * a MULTI-partition scan reads its own snapshot in `open_scan` (the stated
#     exception on `ScanRequest`): a produce between resolve and open IS
#     returned, and `high_watermark.<p>` is exactly what was read.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow.string_array import StringArray
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import resolve_for_execution

from komira_scan_resolver.scan_morsel_resolver import ScanOpened, ScanRequest

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    _manifest_prefix,
    _topic_config_key,
)
from komira_broker.broker_scan_binding import (
    BROKER_PARAM_MAX_BYTES,
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
)
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
    length of the segment's IPC stream, read the way `open_scan` reads it."""
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


def _run(rt: BrokerScanRuntime[_Store], params: ScanParams) raises -> ScanOpened:
    var cached = rt.build_binding(params)
    var exec_binding = resolve_for_execution(rt, cached)
    return rt.open_scan(ScanRequest(exec_binding^))


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
# 1. the TOTAL budget
# =============================================================================


def test_total_budget_ends_the_scan_mid_partition() raises:
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
    var rt = _runtime(store)

    # 2*S2 + S1: p0's third segment (3*S2) does not fit, which ends the SCAN.
    # p1's segment alone (2*S2 + S1) WOULD fit, so returning it would mean the
    # total budget only ended partition 0.
    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_MAX_BYTES), 2 * S2 + S1)
    var o = _run(rt, p)
    _eq(
        _col_i64(o, 0),
        [Int64(11), Int64(12), Int64(13), Int64(14)],
        String("two p0 segments, then the scan is full"),
    )
    assert_equal(_next(o, Int64(0)), Int64(4), "p0 resumes at its third segment")
    assert_equal(_next(o, Int64(1)), Int64(0), "p1 returned nothing")

    # EXACTLY 3*S2: all of p0 fits to the byte (the bound is inclusive), and
    # p1's segment does not.
    var q = _params(topic)
    q.put_i64(String(BROKER_PARAM_MAX_BYTES), 3 * S2)
    var o3 = _run(rt, q)
    _eq(
        _col_i64(o3, 0),
        [Int64(11), Int64(12), Int64(13), Int64(14), Int64(15), Int64(16)],
        String("an exact fit is returned"),
    )
    assert_equal(_next(o3, Int64(0)), Int64(6))
    assert_equal(_next(o3, Int64(1)), Int64(0))

    # 3*S2 + S1: everything.
    var r = _params(topic)
    r.put_i64(String(BROKER_PARAM_MAX_BYTES), 3 * S2 + S1)
    var everything = _run(rt, r)
    assert_equal(everything.num_rows(), 7)
    assert_equal(_next(everything, Int64(1)), Int64(1))


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

    # A total budget on top ends the scan inside p1: 2*S (p0) + S (p1).
    var q = _params(topic)
    q.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), 2 * S)
    q.put_i64(String(BROKER_PARAM_MAX_BYTES), 3 * S)
    var oq = _run(rt, q)
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

    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_MAX_BYTES), Int64(1))
    var o = _run(rt, p)
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
    r.put_i64(String(BROKER_PARAM_MAX_BYTES), Int64(1))
    var o2 = _run(_runtime(store2), r)
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
# 5. the multi-partition snapshot (the stated exception on ScanRequest)
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

    # A produce lands between resolve and open.
    _produce(store, topic, Int64(1), [Int64(22), Int64(23)])

    var o = rt.open_scan(ScanRequest(e^))
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
    suite.test[test_total_budget_ends_the_scan_mid_partition]()
    suite.test[test_partition_budget_returns_k_segments_from_each_partition]()
    suite.test[test_kip74_exempts_the_first_non_empty_partition]()
    suite.test[test_start_offsets_follow_their_partition]()
    suite.test[test_multi_partition_reads_its_own_snapshot_and_reports_it]()
    suite^.run()
