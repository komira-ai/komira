# =============================================================================
# test_broker_scan_kind — `komira.broker.topic` EXECUTES, with no engine.
# =============================================================================
#
# `BrokerScanRuntime` is the tier-2 conformer the execution-time
# resolve pass calls. Every test here drives it exactly the way that pass
# does — `build_binding` -> `resolve_for_execution` (core) -> `open_scan` —
# over the in-memory conditional store, with NO `EngineContext` and no
# executor, so this file stays a light welded test of `komira_broker`.
#
# Pinned here, one test each:
#   * the live tier AND a log-compacted chunk are both read, a start offset
#     inside a compacted chunk skipping exactly the survivors below it;
#   * a produce between two executions is visible, while the plan's
#     `structural_hash` and the cached binding's token stay put — and an
#     execution resolved BEFORE the produce still reads its own snapshot;
#   * KIP-74: the first segment is returned whole even over budget;
#   * the last stable offset under an open transaction, then after commit and
#     after abort;
#   * a client-supplied LIVE token is always overwritten;
#   * the byte budget is NOT in the fingerprint (and isolation IS);
#   * a range reaching the COMPACTED (Parquet) tier is refused by name, never
#     clamped to the advanced `log_start`;
#   * a binding whose topic columns disagree with the topic config (same
#     arity, different type; or same type id, different nullability) is
#     refused by name before any byte is decoded;
#   * a zero-survivor log-compacted chunk contributes no rows and moves no
#     later offset, and one whose body was swapped over the dense `.seg` is
#     refused.
# Budget arithmetic, KIP-74 over an empty partition 0, `start_offsets` and
# the multi-partition snapshot are in `test_broker_scan_kind_budget.mojo`.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_raises,
    assert_true,
)

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow.string_array import StringArray
from komira_core.collections.slab import Slab
from komira_core.plan.logical_plan import LogicalPlan
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import resolve_for_execution
from komira_core.source.source_variant import SourceVariant

from komira_scan_resolver.scan_morsel_resolver import (
    ScanMorselResolvers,
    ScanOpened,
    ScanRequest,
)

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    SegmentFooter,
    _topic_config_key,
    encode_segment,
)
from komira_broker.broker_scan_binding import (
    BROKER_ISOLATION_READ_COMMITTED,
    BROKER_PARAM_ISOLATION,
    BROKER_PARAM_MAX_BYTES,
    BROKER_PARAM_PARTITION_MAX_BYTES,
    BROKER_PARAM_PARTITIONS,
    BROKER_PARAM_START_OFFSET,
    BROKER_PARAM_TOPIC,
    BROKER_PARTITION_COLUMN,
    BROKER_SCAN_KIND_NAME,
    broker_scan_kind_id,
)
from komira_broker.broker_scan_kind import (
    BROKER_RESOLVED_ABORTED,
    BROKER_RESOLVED_HIGH_WATERMARK,
    BROKER_RESOLVED_LAST_STABLE_OFFSET,
    BROKER_RESOLVED_LOG_START_OFFSET,
    BROKER_RESOLVED_NEXT_OFFSET,
    BrokerScanRuntime,
    broker_resolved_key,
    broker_scan_runtime,
)
from komira_broker.compacted_index import CompactionIndex
from komira_broker.log_compaction import (
    CompactionConfig,
    LogCleaner,
    encode_compacted_chunk_body,
)
from komira_broker.manifest_body import ManifestBody
from komira_broker.txn_control import TxnControlStore

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _CLUSTER = "bsk"


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


def _kv(keys: List[Int64], values: List[String], valids: List[Bool]) raises -> RecordBatch:
    var n = len(keys)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        karr.set(i, keys[i])
    var kcol = Column.from_primitive[DType.int64](karr^)
    var varr = StringArray.from_strings_with_validity(values, valids)
    var vcol = Column.from_string(varr^)
    return RecordBatch.from_typed_columns_2(_kv_schema(), kcol^, vcol^)


def _kv_keys(keys: List[Int64]) raises -> RecordBatch:
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(len(keys)):
        vals.append(String("v") + String(keys[i]))
        valid.append(True)
    return _kv(keys, vals, valid)


def _write_config(store: _Store, topic: String, num_partitions: Int) raises:
    var cfg = BrokerTopicConfig(num_partitions, List[String](), _kv_schema())
    _ = store.put(
        Path.parse(_topic_config_key(String(_CLUSTER), topic)), cfg.encode()
    )


def _broker(store: _Store, topic: String, partition: Int64) raises -> BrokerCore[_Store]:
    var prefix = (
        String(_CLUSTER) + "/_meta/topics/" + topic + "/" + String(partition)
    )
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=String(_CLUSTER),
        topic=topic,
        partition=partition,
        broker_id=String("broker-A"),
    )


def _produce(store: _Store, topic: String, partition: Int64, keys: List[Int64]) raises:
    """One produce == one flushed segment == one manifest chunk."""
    var b = _broker(store, topic, partition)
    _ = b.produce(_kv_keys(keys), Int64(1000))
    _ = b.flush_if_buffered(Int64(1000))


def _manifest(store: _Store, topic: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(),
        prefix=String(_CLUSTER) + "/_meta/topics/" + topic + "/0",
        retry=RetryPolicy.fast_test(),
    )


def _compact_chunk(
    store: _Store,
    topic: String,
    chunk_seq: Int64,
    base_offset: Int64,
    var survivors: RecordBatch,
    offsets: List[Int64],
) raises:
    """The PRODUCTION compacted shape (`ProductionLogCleaner`): a NEW sparse
    `.seg` holding only the survivor rows, and the chunk body CAS-swapped to
    point at it with the survivor-offset sidecar (record_count preserved)."""
    var manifest = _manifest(store, topic)
    var orig = ManifestBody.decode(manifest.read_chunk(chunk_seq))
    var buf = Slab[RecordBatch]()
    buf.append(survivors^)
    var seg = encode_segment(buf^, base_offset)
    var crc = SegmentFooter.decode(seg).crc32
    var key = (
        String(_CLUSTER) + "/topics/" + topic + "/compacted-" + String(chunk_seq)
    )
    _ = store.put(Path.parse(key), seg^)
    manifest.rewrite_chunk_body(
        chunk_seq, encode_compacted_chunk_body(orig, key, crc, offsets)
    )


def _runtime(store: _Store) -> BrokerScanRuntime[_Store]:
    return BrokerScanRuntime[_Store](store.clone(), String(_CLUSTER))


def _params(topic: String) -> ScanParams:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String(topic))
    return p^


def _run(rt: BrokerScanRuntime[_Store], params: ScanParams) raises -> ScanOpened:
    """What the resolve pass does, minus the plan walk."""
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


# =============================================================================
# 1. both tiers of the log
# =============================================================================


def test_live_and_compacted_tiers_are_both_read() raises:
    var store = _Store()
    var topic = String("compactT")
    _write_config(store, topic, 1)
    # CHUNK 0: k1@0, k2@1, k1@2, k1(tomb)@3, k3@4.  CHUNK 1: k2@5, k4@6.
    var b = _broker(store, topic, Int64(0))
    _ = b.produce(
        _kv(
            [Int64(1), Int64(2), Int64(1), Int64(1), Int64(3)],
            [String("v1"), String("v2"), String("v3"), String(""), String("v4")],
            [True, True, True, False, True],
        ),
        Int64(1000),
    )
    _ = b.flush_if_buffered(Int64(1000))
    _ = b.produce(
        _kv([Int64(2), Int64(4)], [String("v5"), String("v6")], [True, True]),
        Int64(2000),
    )
    _ = b.flush_if_buffered(Int64(2000))
    # CHUNK 2 (live, never compacted): k1@7, k5@8.
    _ = b.produce(_kv_keys([Int64(1), Int64(5)]), Int64(3000))
    _ = b.flush_if_buffered(Int64(3000))
    _ = b^

    # Compact chunks 0 and 1 the way the production cleaner leaves them
    # (latest per key; the tombstone is in grace): survivors k1(tomb)@3, k3@4 |
    # k2@5, k4@6.
    _compact_chunk(
        store,
        topic,
        Int64(0),
        Int64(0),
        _kv([Int64(1), Int64(3)], [String(""), String("v4")], [False, True]),
        [Int64(3), Int64(4)],
    )
    _compact_chunk(
        store,
        topic,
        Int64(1),
        Int64(5),
        _kv([Int64(2), Int64(4)], [String("v5"), String("v6")], [True, True]),
        [Int64(5), Int64(6)],
    )

    var rt = _runtime(store)
    var whole = _run(rt, _params(topic))
    # Offsets preserved: HWM is still 9 though only 6 rows survive.
    assert_equal(
        whole.resolved.get_i64(
            broker_resolved_key(String(BROKER_RESOLVED_HIGH_WATERMARK), Int64(0))
        ),
        Int64(9),
    )
    _eq(
        _col_i64(whole, 0),
        [Int64(1), Int64(3), Int64(2), Int64(4), Int64(1), Int64(5)],
        String("keys, compacted then live"),
    )
    _eq(
        _col_i64(whole, 2),
        [Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0)],
        String("__partition"),
    )
    ref first = whole.batches[][0]
    assert_equal(first.schema.field_name(2), String(BROKER_PARTITION_COLUMN))

    # A start offset INSIDE a compacted chunk: survivor @3 is below it, @4 is
    # not. The row cut follows the preserved offsets, not the row index.
    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(4))
    _eq(
        _col_i64(_run(rt, p), 0),
        [Int64(3), Int64(2), Int64(4), Int64(1), Int64(5)],
        String("keys from offset 4"),
    )


def test_a_body_swapped_without_its_segment_is_refused_by_name() raises:
    """The leaf `LogCleaner.run` swaps the chunk BODY (survivor sidecar) but
    keeps the original, dense `.seg` — only the production driver rewrites the
    segment. A reader cannot number that chunk's rows, so it refuses."""
    var store = _Store()
    var topic = String("halfT")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(1), Int64(2), Int64(1)])  # 0-2
    _produce(store, topic, Int64(0), [Int64(9)])  # 3, the active head
    var manifest = _manifest(store, topic)
    var cleanable = Slab[RecordBatch]()
    cleanable.append(_kv_keys([Int64(1), Int64(2), Int64(1)]))
    var cleaner = LogCleaner[_Store](
        CompactionConfig.compact(Int64(86_400_000)), key_col=0, value_col=1
    )
    var res = cleaner.run(manifest, cleanable^, [Int64(0)], [Int64(0)], Int64(10_000))
    assert_equal(res.survivors, Int64(2), "fixture: k2@1, k1@2")
    with assert_raises(contains="BROKER_SCAN_COMPACTED_CHUNK_MISMATCH"):
        _ = _run(_runtime(store), _params(topic))


# =============================================================================
# 2. a produce between executions; the plan key does not move
# =============================================================================


def test_produce_between_executions_is_visible_and_the_key_does_not_move() raises:
    var store = _Store()
    var topic = String("orders")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(10), Int64(11)])

    var rt = _runtime(store)
    var cached = rt.build_binding(_params(topic))
    assert_equal(cached.snapshot_token, UInt64(0), "a plan carries token 0")
    var h_before = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(cached.copy()), cached.schema.copy()
    ).structural_hash()

    var e1 = resolve_for_execution(rt, cached)
    assert_equal(e1.snapshot_token, UInt64(2), "token = HWM")
    assert_equal(rt.open_scan(ScanRequest(e1.copy())).num_rows(), 2)

    _produce(store, topic, Int64(0), [Int64(12), Int64(13), Int64(14)])

    var e2 = resolve_for_execution(rt, cached)
    assert_equal(e2.snapshot_token, UInt64(5), "the next execution sees the produce")
    _eq(
        _col_i64(rt.open_scan(ScanRequest(e2.copy())), 0),
        [Int64(10), Int64(11), Int64(12), Int64(13), Int64(14)],
        String("second execution"),
    )
    # The execution resolved BEFORE the produce still reads ITS snapshot.
    assert_equal(rt.open_scan(ScanRequest(e1.copy())).num_rows(), 2)

    # The cached binding never moved, and neither did the plan-cache key.
    assert_equal(cached.snapshot_token, UInt64(0))
    var h_after = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(cached.copy()), cached.schema.copy()
    ).structural_hash()
    assert_equal(h_before, h_after)
    var h_exec = LogicalPlan.scan_from_source(
        SourceVariant.from_binding(e2.copy()), e2.schema.copy()
    ).structural_hash()
    assert_equal(h_before, h_exec, "a resolved LIVE token is not in the key")


# =============================================================================
# 3. KIP-74 and the byte budget
# =============================================================================


def test_kip74_first_segment_is_returned_whole_over_budget() raises:
    var store = _Store()
    var topic = String("budget")
    _write_config(store, topic, 2)
    _produce(store, topic, Int64(0), [Int64(1), Int64(2)])  # offsets 0-1
    _produce(store, topic, Int64(0), [Int64(3), Int64(4)])  # offsets 2-3
    _produce(store, topic, Int64(0), [Int64(5), Int64(6)])  # offsets 4-5
    _produce(store, topic, Int64(1), [Int64(7), Int64(8)])  # p1 offsets 0-1
    var rt = _runtime(store)

    # A 1-byte total budget: the first segment still comes back, whole.
    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_MAX_BYTES), Int64(1))
    var one = _run(rt, p)
    _eq(_col_i64(one, 0), [Int64(1), Int64(2)], String("KIP-74 first batch"))
    assert_equal(
        one.resolved.get_i64(
            broker_resolved_key(String(BROKER_RESOLVED_NEXT_OFFSET), Int64(0))
        ),
        Int64(2),
        "p0 resumes at the first segment not returned",
    )
    assert_equal(
        one.resolved.get_i64(
            broker_resolved_key(String(BROKER_RESOLVED_NEXT_OFFSET), Int64(1))
        ),
        Int64(0),
        "p1 returned nothing and resumes at its start",
    )

    # A 1-byte PER-PARTITION budget: p0's first segment is the scan's first
    # (exempt); p1's first segment is not, so p1 returns nothing.
    var q = _params(topic)
    q.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), Int64(1))
    var per = _run(rt, q)
    _eq(_col_i64(per, 0), [Int64(1), Int64(2)], String("per-partition budget"))

    # No budget: everything, p0 then p1.
    var whole = _run(rt, _params(topic))
    _eq(
        _col_i64(whole, 0),
        [Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6), Int64(7), Int64(8)],
        String("unbudgeted"),
    )
    _eq(
        _col_i64(whole, 2),
        [Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(1), Int64(1)],
        String("__partition across two partitions"),
    )


# =============================================================================
# 4. the last stable offset under an open transaction
# =============================================================================


def test_lso_under_an_open_transaction_then_commit_and_abort() raises:
    var store = _Store()
    var topic = String("txnT")
    _write_config(store, topic, 1)
    var ctl = TxnControlStore[_Store](store.clone(), String(_CLUSTER))
    _produce(store, topic, Int64(0), [Int64(1), Int64(2)])  # 0-1, plain
    _ = ctl.begin(String("tx1"), Int64(7), Int64(0))
    var b = _broker(store, topic, Int64(0))
    b.buffer_batch(_kv_keys([Int64(3), Int64(4)]), Int64(1000))  # 2-3, tx1
    _ = b.flush_with_producer_txn(
        Int64(1000), Int64(7), Int64(0), Int64(0), Int64(1), String("tx1")
    )
    _ = b^
    _produce(store, topic, Int64(0), [Int64(5), Int64(6)])  # 4-5, plain

    var rt = _runtime(store)
    var rc = _params(topic)
    rc.put_str(String(BROKER_PARAM_ISOLATION), String(BROKER_ISOLATION_READ_COMMITTED))
    var lso_key = broker_resolved_key(
        String(BROKER_RESOLVED_LAST_STABLE_OFFSET), Int64(0)
    )

    # OPEN: read_committed stops at the LSO (the open txn's first offset).
    var open_rc = _run(rt, rc)
    assert_equal(open_rc.resolved.get_i64(lso_key), Int64(2), "LSO = tx1's first offset")
    _eq(_col_i64(open_rc, 0), [Int64(1), Int64(2)], String("read_committed, open txn"))
    # read_uncommitted reads to the HWM, and reports the same LSO.
    var open_ru = _run(rt, _params(topic))
    assert_equal(open_ru.resolved.get_i64(lso_key), Int64(2))
    assert_equal(open_ru.num_rows(), 6, "read_uncommitted reads to the HWM")

    # COMMITTED: the LSO catches up with the HWM.
    _ = ctl.prepare_commit(String("tx1"))
    _ = ctl.complete_commit(String("tx1"))
    var done = _run(rt, rc)
    assert_equal(done.resolved.get_i64(lso_key), Int64(6))
    _eq(
        _col_i64(done, 0),
        [Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6)],
        String("read_committed, committed"),
    )

    # ABORTED: tx2's chunk is removed and named.
    _ = ctl.begin(String("tx2"), Int64(8), Int64(0))
    var b2 = _broker(store, topic, Int64(0))
    b2.buffer_batch(_kv_keys([Int64(9), Int64(9)]), Int64(2000))  # 6-7, tx2
    _ = b2.flush_with_producer_txn(
        Int64(2000), Int64(8), Int64(0), Int64(0), Int64(1), String("tx2")
    )
    _ = b2^
    _ = ctl.abort(String("tx2"))
    var ab = _run(rt, rc)
    assert_equal(ab.resolved.get_i64(lso_key), Int64(8), "nothing undecided")
    assert_equal(
        ab.resolved.get_str(
            broker_resolved_key(String(BROKER_RESOLVED_ABORTED), Int64(0))
        ),
        String("tx2@6"),
    )
    assert_equal(ab.num_rows(), 6, "the aborted chunk is not returned")
    assert_equal(_run(rt, _params(topic)).num_rows(), 8, "read_uncommitted keeps it")


# =============================================================================
# 5. identity: the LIVE token and the byte budget
# =============================================================================


def test_a_client_supplied_live_token_is_always_overwritten() raises:
    var store = _Store()
    var topic = String("tok")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(1), Int64(2), Int64(3)])
    var rt = _runtime(store)
    var cached = rt.build_binding(_params(topic))
    # A client (a wire plan, a replayed cache entry) supplies a LIVE token.
    var forged = cached.with_snapshot_token(UInt64(999999))
    var e = resolve_for_execution(rt, forged)
    assert_equal(e.snapshot_token, UInt64(3), "resolved from the log, not the client")
    assert_equal(rt.open_scan(ScanRequest(e^)).num_rows(), 3)
    # And one that under-states the HWM is overwritten too.
    var low = resolve_for_execution(rt, cached.with_snapshot_token(UInt64(1)))
    assert_equal(low.snapshot_token, UInt64(3))


def test_the_byte_budget_is_not_in_the_fingerprint() raises:
    var store = _Store()
    var topic = String("fp")
    _write_config(store, topic, 2)
    var rt = _runtime(store)
    var base = rt.build_binding(_params(topic))
    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_MAX_BYTES), Int64(4096))
    p.put_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES), Int64(1024))
    p.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(77))
    var budgeted = rt.build_binding(p)
    assert_equal(base.fingerprint, budgeted.fingerprint)
    assert_equal(base.structural_id, budgeted.structural_id)
    # Isolation changes the rows, so it IS identity.
    var q = _params(topic)
    q.put_str(String(BROKER_PARAM_ISOLATION), String(BROKER_ISOLATION_READ_COMMITTED))
    assert_not_equal(base.fingerprint, rt.build_binding(q).fingerprint)
    # The partition list is canonical: "1,0,1" is "0,1", which is the default.
    var r = _params(topic)
    r.put_str(String(BROKER_PARAM_PARTITIONS), String("1,0,1"))
    var canon = rt.build_binding(r)
    assert_equal(canon.params.get_str(String(BROKER_PARAM_PARTITIONS)), String("0,1"))
    assert_equal(canon.fingerprint, base.fingerprint)


# =============================================================================
# 6. refusals, and the erased product resolver
# =============================================================================


def test_refusals_are_named() raises:
    var store = _Store()
    var topic = String("ref")
    _write_config(store, topic, 2)
    var rt = _runtime(store)
    var typo = _params(topic)
    typo.put_i64(String("partiton_max_bytes"), Int64(1))
    with assert_raises(contains="BROKER_SCAN_UNKNOWN_PARAM"):
        _ = rt.build_binding(typo)
    var bad = _params(topic)
    bad.put_str(String(BROKER_PARAM_PARTITIONS), String("0,5"))
    with assert_raises(contains="there is no partition 5"):
        _ = rt.build_binding(bad)
    var iso = _params(topic)
    iso.put_str(String(BROKER_PARAM_ISOLATION), String("snapshot"))
    with assert_raises(contains="'isolation' must be"):
        _ = rt.build_binding(iso)
    var foreign = rt.build_binding(_params(topic))
    foreign.kind_id = UInt32(12345)
    foreign.kind_name = String("someone.elses.kind")
    with assert_raises(contains="refusing to resolve foreign kind"):
        _ = rt.resolve_snapshot(foreign)


def test_the_erased_runtime_registers_under_its_kind() raises:
    var store = _Store()
    var topic = String("erased")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(4), Int64(2)])
    var kinds = ScanMorselResolvers()
    kinds.register(broker_scan_runtime(store.clone(), String(_CLUSTER)))
    assert_true(kinds.contains(broker_scan_kind_id()))
    ref r = kinds.get(broker_scan_kind_id())
    assert_equal(r.kind_name(), String(BROKER_SCAN_KIND_NAME))
    var cached = r.build_binding(_params(topic))
    var e = resolve_for_execution(r, cached)
    _eq(_col_i64(r.open_scan(ScanRequest(e^)), 0), [Int64(4), Int64(2)], String("erased"))


# =============================================================================
# 7. the COMPACTED (Parquet) tier is refused, never clamped away
# =============================================================================


def test_a_compacted_parquet_prefix_is_refused_by_name() raises:
    """`compaction_worker.mojo` commits a `CompactedEntry` for a Parquet
    object, then ADVANCES the live `log_start` past that prefix. A scan that
    clamped its start to `log_start` would return only the live suffix, with
    no error, and report the prefix as retention. This kind does not read the
    Parquet tier, so a range reaching it is refused by name."""
    var store = _Store()
    var topic = String("parq")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(1), Int64(2)])  # chunk 0: 0-1
    _produce(store, topic, Int64(0), [Int64(3), Int64(4)])  # chunk 1: 2-3
    _produce(store, topic, Int64(0), [Int64(5), Int64(6)])  # chunk 2: 4-5
    var rt = _runtime(store)
    assert_equal(_run(rt, _params(topic)).num_rows(), 6, "fixture: before compaction")

    # Steps 7-8 of the compaction worker: chunks 0..1 (offsets 0..3) become
    # one Parquet object, then the live log_start moves to (seq 2, offset 4).
    var cidx = CompactionIndex[_Store].build(
        store.clone(), String(_CLUSTER) + "/_meta/topics/" + topic + "/0"
    )
    _ = cidx.append_compacted(
        String(_CLUSTER) + "/compacted/parq-0.parquet",
        Int64(0),
        Int64(3),
        Int64(4),
        Int64(0),
        Int64(1),
    )
    var m = _manifest(store, topic)
    var cur = m.read_log_start()
    _ = m.advance_log_start(Int64(2), Int64(4), cur.etag)

    with assert_raises(contains="BROKER_SCAN_COMPACTED_TIER_UNREAD"):
        _ = _run(rt, _params(topic))
    # A start INSIDE the compacted prefix is refused too.
    var inside = _params(topic)
    inside.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(3))
    with assert_raises(contains="BROKER_SCAN_COMPACTED_TIER_UNREAD"):
        _ = _run(rt, inside)
    # A start at the compacted tail reads the live tier, and log_start is the
    # compacted tail.
    var tail = _params(topic)
    tail.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(4))
    var live = _run(rt, tail)
    _eq(_col_i64(live, 0), [Int64(5), Int64(6)], String("live suffix from offset 4"))
    assert_equal(
        live.resolved.get_i64(
            broker_resolved_key(String(BROKER_RESOLVED_LOG_START_OFFSET), Int64(0))
        ),
        Int64(4),
    )


# =============================================================================
# 8. the binding does not choose how stored bytes decode
# =============================================================================


def test_a_forged_binding_schema_is_refused_by_name() raises:
    """Same arity, different types: a stale plan-cached binding, or one
    decoded off the wire, must not decode INT64 segment bytes as FLOAT64 or
    TIMESTAMP. The topic's durable config is the authority."""
    var store = _Store()
    var topic = String("forge")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(1), Int64(2)])
    var rt = _runtime(store)
    var cached = rt.build_binding(_params(topic))
    assert_equal(
        rt.open_scan(ScanRequest(resolve_for_execution(rt, cached))).num_rows(),
        2,
        "fixture: the honest binding reads",
    )
    var as_float = cached.copy()
    as_float.schema = Schema(
        names=[String("key"), String("value"), String(BROKER_PARTITION_COLUMN)],
        arrow_types=[
            ArrowType.FLOAT64.type_id,
            ArrowType.STRING.type_id,
            ArrowType.INT64.type_id,
        ],
        dtypes=[DType.float64, DType.uint8, DType.int64],
        nullables=[False, True, False],
    )
    var e1 = resolve_for_execution(rt, as_float)
    with assert_raises(contains="BROKER_SCAN_SCHEMA_MISMATCH"):
        _ = rt.open_scan(ScanRequest(e1^))
    var as_ts = cached.copy()
    as_ts.schema = Schema(
        names=[String("key"), String("value"), String(BROKER_PARTITION_COLUMN)],
        arrow_types=[
            ArrowType.TIMESTAMP.type_id,
            ArrowType.STRING.type_id,
            ArrowType.INT64.type_id,
        ],
        dtypes=[DType.int64, DType.uint8, DType.int64],
        nullables=[False, True, False],
    )
    var e2 = resolve_for_execution(rt, as_ts)
    with assert_raises(contains="BROKER_SCAN_SCHEMA_MISMATCH"):
        _ = rt.open_scan(ScanRequest(e2^))
    # Same names AND type ids, different nullability: the check compares the
    # full structural identity (`schema_identity.mojo`), not the type id alone.
    var as_nullable = cached.copy()
    as_nullable.schema = Schema(
        names=[String("key"), String("value"), String(BROKER_PARTITION_COLUMN)],
        arrow_types=[
            ArrowType.INT64.type_id,
            ArrowType.STRING.type_id,
            ArrowType.INT64.type_id,
        ],
        dtypes=[DType.int64, DType.uint8, DType.int64],
        nullables=[True, True, False],
    )
    var e3 = resolve_for_execution(rt, as_nullable)
    with assert_raises(contains="BROKER_SCAN_SCHEMA_MISMATCH"):
        _ = rt.open_scan(ScanRequest(e3^))


# =============================================================================
# 9. a zero-survivor log-compacted chunk
# =============================================================================


def test_a_zero_survivor_compacted_chunk() raises:
    """The production cleaner rewrites a fully superseded chunk to an EMPTY
    `.seg` with a sidecar of count 0, which `is_chunk_compacted` reads as
    compacted. It contributes no rows and moves no later offset. The same
    zero-count body over the ORIGINAL dense `.seg` is refused, which is the
    case that tells `is_chunk_compacted(body)` from `len(survivors) > 0` (the
    latter would number the dense rows `base_offset + r`)."""
    var store = _Store()
    var topic = String("zero")
    _write_config(store, topic, 1)
    _produce(store, topic, Int64(0), [Int64(1), Int64(2)])  # chunk 0: 0-1
    _produce(store, topic, Int64(0), [Int64(1), Int64(2)])  # chunk 1: 2-3
    _produce(store, topic, Int64(0), [Int64(5)])  # chunk 2: 4
    _compact_chunk(
        store,
        topic,
        Int64(0),
        Int64(0),
        _kv(List[Int64](), List[String](), List[Bool]()),
        List[Int64](),
    )
    var rt = _runtime(store)
    var whole = _run(rt, _params(topic))
    _eq(_col_i64(whole, 0), [Int64(1), Int64(2), Int64(5)], String("chunk 0 is empty"))
    assert_equal(
        whole.resolved.get_i64(
            broker_resolved_key(String(BROKER_RESOLVED_HIGH_WATERMARK), Int64(0))
        ),
        Int64(5),
    )
    var p = _params(topic)
    p.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(3))
    _eq(_col_i64(_run(rt, p), 0), [Int64(2), Int64(5)], String("offsets 3.. unchanged"))

    # The zero-count sidecar over chunk 1's ORIGINAL dense `.seg`.
    var manifest = _manifest(store, topic)
    var orig = ManifestBody.decode(manifest.read_chunk(Int64(1)))
    manifest.rewrite_chunk_body(
        Int64(1),
        encode_compacted_chunk_body(
            orig, String(orig.object_key), orig.crc32, List[Int64]()
        ),
    )
    with assert_raises(contains="BROKER_SCAN_COMPACTED_CHUNK_MISMATCH"):
        _ = _run(rt, _params(topic))


def main() raises:
    var suite = TestSuite()
    suite.test[test_live_and_compacted_tiers_are_both_read]()
    suite.test[test_a_body_swapped_without_its_segment_is_refused_by_name]()
    suite.test[test_produce_between_executions_is_visible_and_the_key_does_not_move]()
    suite.test[test_kip74_first_segment_is_returned_whole_over_budget]()
    suite.test[test_lso_under_an_open_transaction_then_commit_and_abort]()
    suite.test[test_a_client_supplied_live_token_is_always_overwritten]()
    suite.test[test_the_byte_budget_is_not_in_the_fingerprint]()
    suite.test[test_refusals_are_named]()
    suite.test[test_the_erased_runtime_registers_under_its_kind]()
    suite.test[test_a_compacted_parquet_prefix_is_refused_by_name]()
    suite.test[test_a_forged_binding_schema_is_refused_by_name]()
    suite.test[test_a_zero_survivor_compacted_chunk]()
    suite^.run()
