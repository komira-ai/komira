# =============================================================================
# test_broker_scan_kind_compaction_race — a compaction landing MID-SCAN never
# drops the compacted prefix silently.
# =============================================================================
#
# The compaction worker (`komira_broker_compaction`'s `compaction_worker.mojo`)
# commits its `CompactedEntry` (step 6) and THEN advances the live `log_start`
# (step 8), in the background, alongside scans. The plan refuses a range
# reaching the compacted (Parquet) tier by LISTing the compaction index, and
# raises `start` to the `log_start` it read. If the LIST comes first, steps
# 6-8 can land between an EMPTY LIST and the `log_start` read: the plan then
# starts at the moved `log_start` and the read returns only the live suffix,
# with no error, reporting the prefix as if retention had deleted it. And the
# window between the plan and a reader is not one call: a split reader
# re-checks at open and before every segment, and refuses rather than clamps.
#
# `_CompactsMidScanStore` makes that interleaving deterministic. The FIRST
# LIST under the partition's compaction-index prefix arms it; the next
# operation OUTSIDE that prefix first lands the compaction (so the whole
# compaction-index read linearizes before it, and every later read after it).
# Whatever order `drain_scan` reads in, it must either refuse by name or
# return every offset from the requested start — never the suffix alone.
#
# The compaction is PRE-COMPUTED: steps 6 and 8 run once, through the real
# `CompactionIndex` / `CasManifestStore`, over a separate SHADOW store, and the
# hook copies the resulting objects raw into the scanned store — the
# compaction-index objects first, `_LOG_START` last (the worker's order). It
# cannot run them in place: every store call the hook intercepts is made
# under `cas_manifest.mojo`'s process-wide CAS gate, and `advance_log_start`
# takes that gate for write, so an in-place compaction self-deadlocks.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_resolver import resolve_for_execution

from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ScanOpened, ScanRequest

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    _topic_config_key,
)
from komira_broker.broker_scan_binding import BROKER_PARAM_TOPIC
from komira_broker.broker_scan_kind import (
    BROKER_RESOLVED_LOG_START_OFFSET,
    BrokerScanRuntime,
    broker_resolved_key,
)
from komira_broker.compacted_index import CompactionIndex, compacted_prefix

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


comptime _Inner = SharedInMemoryConditionalStore
comptime _CLUSTER = "bskr"
comptime _TOPIC = "race"
comptime _ARMED = "race-hook/armed"
comptime _FIRED = "race-hook/fired"


def _partition_prefix() -> String:
    return String(_CLUSTER) + "/_meta/topics/" + String(_TOPIC) + "/0"


def _has(store: _Inner, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


def _compact_offsets_0_to_3(store: _Inner) raises:
    """Steps 6 and 8 of the compaction worker, in its order: chunks 0..1
    (offsets 0..3) become one Parquet object in the compaction index, THEN
    the live `log_start` moves to (seq 2, offset 4)."""
    var cidx = CompactionIndex[_Inner].build(store.clone(), _partition_prefix())
    _ = cidx.append_compacted(
        String(_CLUSTER) + "/compacted/race-0.parquet",
        Int64(0),
        Int64(3),
        Int64(4),
        Int64(0),
        Int64(1),
    )
    var m = CasManifestStore[_Inner](
        store=store.clone(), prefix=_partition_prefix(), retry=RetryPolicy.fast_test()
    )
    var cur = m.read_log_start()
    _ = m.advance_log_start(Int64(2), Int64(4), cur.etag)


def _collect_keys(store: _Inner, prefix: String, mut out: List[String]) raises:
    """Every object key under `prefix`, recursively."""
    var res = store.list_with_delimiter(Path.parse(prefix))
    for i in range(len(res.objects)):
        out.append(String(res.objects[i].location))
    for i in range(len(res.common_prefixes)):
        _collect_keys(store, res.common_prefixes[i], out)


def _land_compaction(shadow: _Inner, target: _Inner) raises:
    """Copy the shadow's compaction objects into `target` raw: the
    compaction-index lineage first (step 6), the partition's `_LOG_START`
    last (step 8)."""
    var keys = List[String]()
    _collect_keys(shadow, String(_CLUSTER) + "/", keys)
    var log_start_key = String("")
    var cp = compacted_prefix(_partition_prefix())
    for i in range(len(keys)):
        if keys[i] == _partition_prefix() + "/_LOG_START":
            log_start_key = keys[i]
            continue
        if not keys[i].startswith(cp):
            # Only the compaction index and `_LOG_START` move; anything else
            # the shadow holds must not overwrite the scanned log.
            continue
        _ = target.put(Path.parse(keys[i]), shadow.get(Path.parse(keys[i])))
    if log_start_key == String(""):
        raise Error("fixture: the shadow compaction wrote no _LOG_START")
    _ = target.put(Path.parse(log_start_key), shadow.get(Path.parse(log_start_key)))


struct _CompactsMidScanStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates every verb to a shared in-memory store. The first LIST under
    the compaction-index prefix ARMS it; the next verb on a key outside that
    prefix lands the shadow's compaction (once) before it runs. The one-shot
    state lives in the shared inner store, so every clone sees it."""

    var _inner: _Inner
    var _shadow: _Inner

    def __init__(out self, var inner: _Inner, var shadow: _Inner):
        self._inner = inner^
        self._shadow = shadow^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._shadow.clone())

    def _before(self, key: String, is_list: Bool) raises:
        if _has(self._inner, String(_FIRED)):
            return
        if key.startswith(compacted_prefix(_partition_prefix())):
            if is_list and not _has(self._inner, String(_ARMED)):
                _ = self._inner.put(Path.parse(String(_ARMED)), List[UInt8]())
            return
        if _has(self._inner, String(_ARMED)):
            _ = self._inner.put(Path.parse(String(_FIRED)), List[UInt8]())
            _land_compaction(self._shadow, self._inner)

    def head(self, path: Path) raises -> ObjectMeta:
        self._before(path.raw(), False)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._before(prefix.raw(), True)
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._before(path.raw(), False)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._before(path.raw(), False)
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._before(path.raw(), False)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._before(path.raw(), False)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._before(path.raw(), False)
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._before(path.raw(), False)
        self._inner.delete(path)


def _kv_schema() raises -> Schema:
    return Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.STRING.type_id],
        dtypes=[DType.int64, DType.uint8],
        nullables=[False, True],
    )


def _kv_keys(keys: List[Int64]) raises -> RecordBatch:
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


def _produce(store: _Inner, keys: List[Int64]) raises:
    """One produce == one flushed segment == one manifest chunk."""
    var manifest = CasManifestStore[_Inner](
        store=store.clone(), prefix=_partition_prefix(), retry=RetryPolicy.fast_test()
    )
    var b = BrokerCore[_Inner](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(0),
        broker_id=String("broker-A"),
    )
    _ = b.produce(_kv_keys(keys), Int64(1000))
    _ = b.flush_if_buffered(Int64(1000))


def _keys(o: ScanOpened) raises -> List[Int64]:
    var out = List[Int64]()
    for i in range(o.num_batches()):
        ref b = o.batches[][i]
        for r in range(b.num_rows()):
            out.append(Int64(b.column_value(0, r)))
    return out^


def test_a_compaction_landing_mid_scan_never_drops_the_prefix() raises:
    var inner = _Inner()
    var cfg = BrokerTopicConfig(1, List[String](), _kv_schema())
    _ = inner.put(
        Path.parse(_topic_config_key(String(_CLUSTER), String(_TOPIC))), cfg.encode()
    )
    _produce(inner, [Int64(1), Int64(2)])  # chunk 0: offsets 0-1
    _produce(inner, [Int64(3), Int64(4)])  # chunk 1: offsets 2-3
    _produce(inner, [Int64(5), Int64(6)])  # chunk 2: offsets 4-5

    var shadow = _Inner()
    _compact_offsets_0_to_3(shadow)
    var rt = BrokerScanRuntime[_CompactsMidScanStore](
        _CompactsMidScanStore(inner.clone(), shadow.clone()), String(_CLUSTER)
    )
    var params = ScanParams()
    params.put_str(String(BROKER_PARAM_TOPIC), String(_TOPIC))
    var cached = rt.build_binding(params)
    var exec_binding = resolve_for_execution(rt, cached)
    assert_false(
        _has(inner, String(_ARMED)), "fixture: nothing LISTed the index before open"
    )

    var refused = False
    var got = List[Int64]()
    var log_start = Int64(-1)
    try:
        var o = drain_scan(rt, ScanRequest(exec_binding^))
        got = _keys(o)
        log_start = o.resolved.get_i64(
            broker_resolved_key(String(BROKER_RESOLVED_LOG_START_OFFSET), Int64(0))
        )
    except e:
        assert_true(
            String(e).find("BROKER_SCAN_COMPACTED_TIER_UNREAD") >= 0,
            String("a refusal must name the compacted tier; got: ") + String(e),
        )
        refused = True
    # Not vacuous: the compaction really landed inside this one drain.
    assert_true(_has(inner, String(_FIRED)), "the compaction fired mid-scan")
    if not refused:
        # Every offset from 0, and the log_start that was actually read.
        assert_equal(len(got), 6, "the compacted prefix was dropped silently")
        for i in range(6):
            assert_equal(got[i], Int64(i + 1), String("row ") + String(i))
        assert_equal(log_start, Int64(0), "reported log_start is the one read")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_compaction_landing_mid_scan_never_drops_the_prefix]()
    suite^.run()
