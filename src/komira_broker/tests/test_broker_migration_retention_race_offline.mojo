# =============================================================================
# tests/test_broker_migration_retention_race_offline.mojo
#   A RetentionPass between a migration's materialize and retire — OFFLINE
# =============================================================================
#
# `migrate_partition` reads the legacy `_LOG_START` (L0), materializes the
# legacy chunks into `_base` (reusing their `.seg` objects), then retires
# them. If a RetentionPass advances the legacy `_LOG_START` to F in between,
# chunks [L0, F) carry only its plain tombstones although `_base` references
# their `.seg`. The retire walk used to start at a fresh read of
# `_LOG_START` (F), so no MOVED marker reached them and the reaper deleted
# their `.seg` (komira-ai/komira#494). The walk now starts at L0, the log
# start the migration read when it materialized.
#
# `_RaceStore` runs the RetentionPass at the right moment: inside the retire
# walk's first LIST of `<legacy>/tombstones/` (after materialize, before the
# walk reads `_LOG_START`). That call runs under the CAS gate lock, and the
# pass takes the lock again, so `main` switches the gate off
# (`komira_cas_gate_set_disabled`, the test-only switch; this test is single-
# threaded).
#
#   (1) The pass retires chunks 0 and 1 (F = 2). The migration still writes
#       MOVED markers on 0..3; it counts 2 and 3 as new (0 and 1 carry the
#       pass's tombstones). Reaps after both grace windows keep every `.seg`,
#       and `_base` serves all 40 records. Catches: a walk that re-reads the
#       log start (mutant), where chunks 0 and 1 lose their `.seg` at
#       10000 + grace.
#   (2) Chunk 0 is reaped before the walk reaches it: the walk skips it
#       (its key is gone, below the floor) and still marks chunk 1. Catches:
#       a walk that raises on the reaped chunk.
#   (3) Reading chunk 1 fails with a transport error: the migration raises,
#       writes no marker at or above F, and does not advance. Catches: a walk
#       that skips every error.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore
from komira_broker.manifest_body import ManifestBody
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.retention import ReapResult, ReapWorker, RetentionPass, RetentionPolicy
from komira_broker.sublineage_consume import SubLineageConsumeResolver
from komira_broker.sublineage_migration import SubLineageMigration

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
comptime _RETENTION_AT = Int64(10_000)
comptime _MIGRATE_AT = Int64(50_000)

# The race rule: its body is one mode byte.
comptime _RACE_RULE = "__fault__/race_mode"
comptime _MODE_RETENTION = UInt8(0)
comptime _MODE_RETENTION_THEN_REAP_0 = UInt8(1)
comptime _MODE_RETENTION_THEN_FAIL_1 = UInt8(2)
comptime _FAIL_GET = "__fault__/get/"


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
    """Delegates to a shared in-memory store. While `_RACE_RULE` is armed, the
    first LIST of `<legacy>/tombstones/` first runs a RetentionPass over the
    legacy manifest (retiring chunks 0 and 1), then what the mode adds."""

    var _inner: _Inner
    var _legacy: String

    def __init__(out self, var inner: _Inner, var legacy: String):
        self._inner = inner^
        self._legacy = legacy^

    def clone(self) -> Self:
        return Self(self._inner.clone(), String(self._legacy))

    def arm_race(self, mode: UInt8) raises:
        var body = List[UInt8]()
        body.append(mode)
        _ = self._inner.put(Path.parse(String(_RACE_RULE)), body)

    def _race(self) raises:
        var mode = self._inner.get(Path.parse(String(_RACE_RULE)))[0]
        self._inner.delete(Path.parse(String(_RACE_RULE)))
        var m = CasManifestStore[_Inner](
            store=self._inner.clone(),
            prefix=String(self._legacy),
            retry=RetryPolicy.fast_test(),
        )
        # Ages at 10000: 9000, 8000, 7000 (chunk 3 is active): 0 and 1 retire.
        var rp = RetentionPass[_Inner](RetentionPolicy.time_based(Int64(7500)))
        var res = rp.run(m, _RETENTION_AT)
        _ = rp^
        assert_equal(res.new_log_start_seq, Int64(2), "the pass advanced to F = 2")
        if mode == _MODE_RETENTION_THEN_REAP_0:
            m.reap(Int64(0))
        elif mode == _MODE_RETENTION_THEN_FAIL_1:
            _ = self._inner.put(
                Path.parse(
                    String(_FAIL_GET) + chunk_key(self._legacy, Int64(1)).raw()
                ),
                List[UInt8](),
            )
        _ = m^

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        if prefix.raw() == self._legacy + "/tombstones/" and _inner_has(
            self._inner, String(_RACE_RULE)
        ):
            self._race()
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if _inner_has(self._inner, String(_FAIL_GET) + path.raw()):
            raise Error("injected fault: transport error status=503")
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

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


# =============================================================================
# (1) the race: every `.seg` survives
# =============================================================================


def test_retention_between_materialize_and_retire() raises:
    print("[test_retention_between_materialize_and_retire] starting...")
    var pid = Int64(0)
    var prefix = _prefix(pid)
    var store = _setup(pid)
    var keys = _seg_keys(store, prefix)

    store.arm_race(_MODE_RETENTION)
    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(_MIGRATE_AT)
    _ = mig^
    assert_false(_has(store, String(_RACE_RULE)), "the race ran")
    assert_equal(st.records_migrated, Int64(40), "40 records migrated")
    assert_equal(st.source_chunks_retired, 2, "2, 3 new; 0, 1 had tombstones")

    var r0 = _reap(store, prefix, _RETENTION_AT + _GRACE)
    for i in range(4):
        assert_true(_has(store, keys[i]), "after the retention grace: .seg " + String(i) + " kept")
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the MOVED markers")
    _assert_seqs(
        _moved(store, prefix),
        [Int64(0), Int64(1), Int64(2), Int64(3)],
        "MOVED on every migrated chunk",
    )
    var r1 = _reap(store, prefix, _MIGRATE_AT + _GRACE)
    assert_equal(r1.reaped_count, Int64(4), "4 chunk keys reaped")
    for i in range(4):
        assert_true(_has(store, keys[i]), ".seg " + String(i) + " kept")
        assert_false(
            _has(store, chunk_key(prefix, Int64(i)).raw()), "key " + String(i) + " reaped"
        )
    _assert_base_serves(store, prefix, keys, "race")
    print("[test_retention_between_materialize_and_retire] PASS")


# =============================================================================
# (2) a chunk in [L0, F) already reaped: skipped
# =============================================================================


def test_already_reaped_chunk_below_floor_is_skipped() raises:
    print("[test_already_reaped_chunk_below_floor_is_skipped] starting...")
    var pid = Int64(1)
    var prefix = _prefix(pid)
    var store = _setup(pid)

    store.arm_race(_MODE_RETENTION_THEN_REAP_0)
    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(_MIGRATE_AT)
    _ = mig^
    assert_false(_has(store, String(_RACE_RULE)), "the race ran")
    assert_equal(st.records_migrated, Int64(40), "40 records migrated")
    assert_false(_has(store, chunk_key(prefix, Int64(0)).raw()), "chunk 0 was reaped")
    _assert_seqs(
        _moved(store, prefix),
        [Int64(1), Int64(2), Int64(3)],
        "chunk 0 skipped, 1..3 MOVED",
    )
    var m = _manifest(store, prefix)
    assert_equal(m.read_log_start_seq(), Int64(4), "the migration advanced")
    _ = m^
    print("[test_already_reaped_chunk_below_floor_is_skipped] PASS")


# =============================================================================
# (3) any other read error raises before the advance
# =============================================================================


def test_read_error_below_floor_raises() raises:
    print("[test_read_error_below_floor_raises] starting...")
    var pid = Int64(2)
    var prefix = _prefix(pid)
    var store = _setup(pid)

    store.arm_race(_MODE_RETENTION_THEN_FAIL_1)
    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var raised = False
    try:
        _ = mig.migrate_partition(_MIGRATE_AT)
    except e:
        raised = True
        assert_true(String(e).find("503") >= 0, String(e))
    _ = mig^
    assert_true(raised, "the transport error is raised")
    _assert_seqs(_moved(store, prefix), [Int64(0)], "only chunk 0 marked")
    var m = _manifest(store, prefix)
    assert_equal(m.read_log_start_seq(), Int64(2), "no advance past F")
    _ = m^
    print("[test_read_error_below_floor_raises] PASS")


def main() raises:
    # Test-only: the injected RetentionPass runs inside a gated manifest call.
    external_call["komira_cas_gate_set_disabled", NoneType](Int32(1))
    test_retention_between_materialize_and_retire()
    test_already_reaped_chunk_below_floor_is_skipped()
    test_read_error_below_floor_raises()
    print("[OK] test_broker_migration_retention_race_offline — 3 cases passed")
