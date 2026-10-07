# =============================================================================
# tests/test_broker_migration_retention_race_offline.mojo
#   A RetentionPass (and a reaper) running during a migration — OFFLINE
# =============================================================================
#
# `migrate_partition` materializes the legacy chunks into `_base`, reusing
# their `.seg` objects, then retires them. A RetentionPass on the legacy
# manifest can plain-tombstone those chunks and advance past them at any
# point in between, and a reaper can run past its grace before the
# migration's retire. The `.seg` is safe only if the chunk's MOVED marker
# exists before the reaper can see the chunk below the floor. So the
# migration writes each chunk's MOVED marker BEFORE that chunk's `_base`
# append (komira-ai/komira#494). The reaper checks MOVED first and never
# touches a chunk at or above the floor.
#
# `_RaceStore` injects the interleaving inside a `_base` chunk append (the
# append path takes no CAS gate lock, so the injected pass and reaper run
# with the gate on).
#
#   (1) After the LAST chunk's `_base` append, a RetentionPass retires chunks
#       0 and 1. The retire still advances to 4, every `.seg` survives both
#       grace windows, and `_base` serves all 40 records.
#   (2) After chunk 1's `_base` append, a RetentionPass retires 0 and 1 AND a
#       real ReapWorker runs past that pass's grace. It reaps the chunk keys
#       and keeps both `.seg` objects; `_base` serves all 40 records. Catches:
#       a MOVED marker written only at retire (the reaper deletes .seg 0 and
#       1 first), or after the append (it misses chunk 1).
#   (3) The retire's head read: a transport error raises, not_found means
#       the manifest is gone (0 retired). The same holds for the segment
#       fold's retire. Catches: the old catch-all that took any error for
#       "already reaped" and retired nothing.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore
from komira_broker.manifest_body import ManifestBody
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.retention import ReapResult, ReapWorker, RetentionPass, RetentionPolicy
from komira_broker.sublineage_consume import SubLineageConsumeResolver
from komira_broker.sublineage_migration import SubLineageMigration
from komira_broker.sublineage_segment_fold import SegmentBaseFold

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
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
from komira_objectstore.sublineage_base_fold import BASE_SHARD_ID
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _Inner = SharedInMemoryConditionalStore
comptime _CLUSTER = "migrace"
comptime _TOPIC = "t"
comptime _GRACE = Int64(60_000)
comptime _RECORDS = 10
comptime _MIGRATE_AT = Int64(50_000)

# `<_RACE_ON><key>`: after a successful conditional PUT of `<key>`, run the
# race; the rule's body is one mode byte.
comptime _RACE_ON = "__fault__/race_on/"
comptime _MODE_RETENTION = UInt8(0)
comptime _MODE_RETENTION_THEN_REAP = UInt8(1)
# `<_LIST_FAIL><prefix>`: a LIST of `<prefix>` fails; body 0 = a transport
# error, 1 = not_found.
comptime _LIST_FAIL = "__fault__/list/"


def _inner_has(inner: _Inner, key: String) -> Bool:
    try:
        _ = inner.head(Path.parse(key))
        return True
    except:
        return False


struct _RaceStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates to a shared in-memory store, applying the rules above. The
    race runs a RetentionPass over the legacy manifest (retiring chunks 0 and
    1) and, in `_MODE_RETENTION_THEN_REAP`, a ReapWorker past its grace."""

    var _inner: _Inner
    var _legacy: String

    def __init__(out self, var inner: _Inner, var legacy: String):
        self._inner = inner^
        self._legacy = legacy^

    def clone(self) -> Self:
        return Self(self._inner.clone(), String(self._legacy))

    def arm(self, rule: String, target: String, mode: UInt8) raises:
        var body = List[UInt8]()
        body.append(mode)
        _ = self._inner.put(Path.parse(rule + target), body)

    def _race(self, mode: UInt8) raises:
        var m = CasManifestStore[_Inner](
            store=self._inner.clone(),
            prefix=String(self._legacy),
            retry=RetryPolicy.fast_test(),
        )
        # Chunks are created at 1000..4000; chunk 3 is active. Each policy
        # retires exactly 0 and 1.
        var at = Int64(10_000) if mode == _MODE_RETENTION else Int64(60_000)
        var keep_ms = Int64(7_500) if mode == _MODE_RETENTION else Int64(57_500)
        var rp = RetentionPass[_Inner](RetentionPolicy.time_based(keep_ms))
        var res = rp.run(m, at)
        _ = rp^
        assert_equal(res.new_log_start_seq, Int64(2), "the pass advanced to 2")
        if mode == _MODE_RETENTION_THEN_REAP:
            var seg_store = self._inner.clone()
            var w = ReapWorker[_Inner](_GRACE)
            _ = w.run(seg_store, m, at + _GRACE)
        _ = m^

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        var rule = String(_LIST_FAIL) + prefix.raw()
        if _inner_has(self._inner, rule):
            var mode = self._inner.get(Path.parse(rule))[0]
            if mode == UInt8(0):
                raise Error("injected fault: transport error status=503")
            raise Error("injected: not_found (404), the manifest is gone")
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
        var meta = self._inner.conditional_put(path, bytes, precond)
        var rule = String(_RACE_ON) + path.raw()
        if _inner_has(self._inner, rule):
            var mode = self._inner.get(Path.parse(rule))[0]
            self._inner.delete(Path.parse(rule))
            self._race(mode)
        return meta^

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


comptime _Store = _RaceStore


# =============================================================================
# helpers
# =============================================================================


def _prefix(pid: Int64) -> String:
    return String(_CLUSTER) + "/_meta/topics/" + String(_TOPIC) + "/" + String(pid)


def _manifest(store: _Store, prefix: String) -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _has(store: _Store, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


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


def _setup(pid: Int64) raises -> _Store:
    """A legacy partition of 4 chunks of 10 records, created at 1000..4000."""
    var prefix = _prefix(pid)
    var store = _RaceStore(_Inner(), String(prefix))
    var broker = BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, prefix),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=pid,
        broker_id=String("broker-A"),
    )
    for i in range(4):
        var ts = Int64(1000) + Int64(i) * Int64(1000)
        _ = broker.produce(_batch(Int64(i * _RECORDS), _RECORDS), ts)
        _ = broker.flush_if_buffered(ts)
    _ = broker^
    return store^


def _seg_keys(store: _Store, prefix: String) raises -> List[String]:
    var m = _manifest(store, prefix)
    var out = List[String]()
    for s in range(4):
        out.append(String(ManifestBody.decode(m.read_chunk(Int64(s))).object_key))
    _ = m^
    return out^


def _reap(store: _Store, prefix: String, now_ms: Int64) raises -> ReapResult:
    var seg_store = store.clone()
    var m = _manifest(store, prefix)
    var w = ReapWorker[_Store](_GRACE)
    var r = w.run(seg_store, m, now_ms)
    _ = m^
    return r^


def _moved(store: _Store, prefix: String) raises -> List[Int64]:
    var m = _manifest(store, prefix)
    var out = m.moved_tombstone_seqs()
    _ = m^
    return out^


def _assert_seqs(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": seq " + String(i))


def _assert_base_serves(
    store: _Store, prefix: String, keys: List[String], what: String
) raises:
    var r = SubLineageConsumeResolver[_Store](store.clone(), prefix)
    var refs = r.resolve_index()
    _ = r^
    assert_equal(len(refs), len(keys), what + ": `_base` segment count")
    var core = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, sublineage_prefix(prefix, BASE_SHARD_ID)),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(0),
    )
    for i in range(len(refs)):
        assert_equal(refs[i].object_key, keys[i], what + ": `_base` key")
        assert_equal(refs[i].base_offset, Int64(i * _RECORDS), what + ": offset")
        var seg = core.read_segment(refs[i].copy())
        assert_equal(seg.record_count, Int64(_RECORDS), what + ": records read")
    _ = core^


def _base_chunk(prefix: String, seq: Int) raises -> String:
    return chunk_key(sublineage_prefix(prefix, BASE_SHARD_ID), Int64(seq)).raw()


def _migrate_with_race(
    store: _Store, prefix: String, after_base_chunk: Int, mode: UInt8
) raises -> Int:
    store.arm(String(_RACE_ON), _base_chunk(prefix, after_base_chunk), mode)
    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(_MIGRATE_AT)
    _ = mig^
    assert_false(
        _has(store, String(_RACE_ON) + _base_chunk(prefix, after_base_chunk)),
        "the race ran",
    )
    assert_equal(st.records_migrated, Int64(40), "40 records migrated")
    var m = _manifest(store, prefix)
    assert_equal(m.read_log_start_seq(), Int64(4), "the migration advanced to 4")
    _ = m^
    return st.source_chunks_retired


# =============================================================================
# (1) retention after the last `_base` append
# =============================================================================


def test_retention_after_materialize() raises:
    print("[test_retention_after_materialize] starting...")
    var pid = Int64(0)
    var prefix = _prefix(pid)
    var store = _setup(pid)
    var keys = _seg_keys(store, prefix)
    _ = _migrate_with_race(store, prefix, 3, _MODE_RETENTION)

    var r0 = _reap(store, prefix, Int64(10_000) + _GRACE)
    for i in range(4):
        assert_true(_has(store, keys[i]), "after the pass's grace: .seg " + String(i) + " kept")
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the MOVED markers")
    var r1 = _reap(store, prefix, _MIGRATE_AT + _GRACE)
    assert_equal(r1.reaped_count, Int64(4), "4 chunk keys reaped")
    for i in range(4):
        assert_true(_has(store, keys[i]), ".seg " + String(i) + " kept")
        assert_false(
            _has(store, chunk_key(prefix, Int64(i)).raw()), "key " + String(i) + " reaped"
        )
    _assert_base_serves(store, prefix, keys, "retention after materialize")
    print("[test_retention_after_materialize] PASS")


# =============================================================================
# (2) retention AND a reaper past grace, mid-materialize
# =============================================================================


def test_retention_and_reap_mid_materialize() raises:
    print("[test_retention_and_reap_mid_materialize] starting...")
    var pid = Int64(1)
    var prefix = _prefix(pid)
    var store = _setup(pid)
    var keys = _seg_keys(store, prefix)
    _ = _migrate_with_race(store, prefix, 1, _MODE_RETENTION_THEN_REAP)

    for i in range(4):
        assert_true(_has(store, keys[i]), "after the injected reap: .seg " + String(i) + " kept")
    for i in range(2):
        assert_false(
            _has(store, chunk_key(prefix, Int64(i)).raw()),
            "the injected reaper reclaimed key " + String(i),
        )
    _assert_base_serves(store, prefix, keys, "reap mid-materialize")
    var r = _reap(store, prefix, _MIGRATE_AT + _GRACE)
    assert_equal(r.reaped_count, Int64(2), "chunk keys 2, 3 reaped")
    for i in range(4):
        assert_true(_has(store, keys[i]), ".seg " + String(i) + " kept")
    _assert_base_serves(store, prefix, keys, "reap mid-materialize, after")
    print("[test_retention_and_reap_mid_materialize] PASS")


# =============================================================================
# (3) the retire's head read
# =============================================================================


def test_retire_head_read_errors() raises:
    print("[test_retire_head_read_errors] starting...")
    var pid = Int64(2)
    var prefix = _prefix(pid)
    var store = _setup(pid)
    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var legacy = mig._legacy_manifest()
    var lk = prefix + "/manifest/"

    store.arm(String(_LIST_FAIL), lk, UInt8(0))
    var raised = False
    try:
        _ = mig._retire_migrated_legacy(legacy, Int64(40), _MIGRATE_AT)
    except e:
        raised = True
        assert_true(String(e).find("503") >= 0, String(e))
    assert_true(raised, "migration: a transport error is raised")
    store.arm(String(_LIST_FAIL), lk, UInt8(1))
    assert_equal(
        mig._retire_migrated_legacy(legacy, Int64(40), _MIGRATE_AT),
        0,
        "migration: not_found = nothing to retire",
    )
    assert_equal(len(_moved(store, prefix)), 0, "migration: nothing marked")
    _ = legacy^
    _ = mig^

    var sp = sublineage_prefix(prefix, String("w01"))
    var fold = SegmentBaseFold[_Store](store.clone(), prefix)
    var sk = sp + "/manifest/"
    store.arm(String(_LIST_FAIL), sk, UInt8(0))
    var raised2 = False
    try:
        _ = fold._retire_folded_source(String("w01"), Int64(30), _MIGRATE_AT)
    except e:
        raised2 = True
        assert_true(String(e).find("503") >= 0, String(e))
    assert_true(raised2, "fold: a transport error is raised")
    store.arm(String(_LIST_FAIL), sk, UInt8(1))
    assert_equal(
        fold._retire_folded_source(String("w01"), Int64(30), _MIGRATE_AT),
        0,
        "fold: not_found = nothing to retire",
    )
    _ = fold^
    print("[test_retire_head_read_errors] PASS")


def main() raises:
    test_retention_after_materialize()
    test_retention_and_reap_mid_materialize()
    test_retire_head_read_errors()
    print("[OK] test_broker_migration_retention_race_offline — 3 cases passed")
