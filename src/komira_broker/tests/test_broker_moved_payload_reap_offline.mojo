# =============================================================================
# tests/test_broker_moved_payload_reap_offline.mojo
#   The reaper keeps the `.seg` objects `_base` reads — OFFLINE
# =============================================================================
#
# A sub-lineage migration re-records the legacy manifest's chunks into
# `_base`, and the segment fold re-records a writer shard's chunks there, both
# REUSING the same `.seg` objects. Each then retires its source chunks. The
# `ReapWorker` deleted a tombstoned chunk's `.seg` with its key, so a reap of
# the legacy prefix (the partition prefix `BrokerCore.reap_partition` reaps)
# or of a shard prefix deleted data `_base` serves (komira-ai/komira#494). Now
# both retire with a MOVED marker (`<prefix>/moved_tombstones/<seq>.tomb`, a
# key only `schedule_moved_for_delete_at` writes). The reaper checks it before
# anything else and then reclaims only the chunk key, with grace counted from
# the MOVED marker's ts.
#
#   (1) Migrate 4 legacy chunks, reap past grace: the legacy chunk keys are
#       gone, every `.seg` is present and byte-identical, and `_base` serves
#       all 40 records at offsets 0..39. Catches: the reaper ignoring MOVED
#       markers; `tombstone_seqs` not listing them (nothing is reaped).
#   (2) The same for the segment fold over shard `w01`, whose chunk 0 carries
#       a stranded plain tombstone from before the fold. Catches: the fold not
#       writing MOVED markers, or skipping the stranded chunk.
#   (3) Control: retention retires chunks 0 and 1, then the migration moves
#       2 and 3. The reaper deletes the `.seg` of 0 and 1 (plain tombstones,
#       nothing references them) and keeps those of 2 and 3.
#   (4) A failed RetentionPass advance left plain tombstones on live chunks 0
#       and 1 at ts 10000. The migration moves them past `_LOG_START` at
#       50000: grace counts from 50000, then their `.seg` is kept. The
#       migration counts only the 2 chunks that carried no marker.
#   (5) The race the review found: a RetentionPass whose `_LOG_START`
#       snapshot predates the migration's retire (the store serves it the
#       pre-migration pointer until its first tombstone write) tombstones
#       chunks 0..2 AFTER the migration retired them. With an in-place flag
#       that write downgraded the marker and the reaper deleted the `.seg`;
#       with a separate MOVED key every `.seg` survives.
#   (6) A plain tombstone with an OLD ts on a chunk that also has a MOVED
#       marker: nothing is reaped until the MOVED marker's grace elapses, and
#       the `.seg` is kept. Catches: a reaper that reads the plain tombstone
#       first.
#   (7) The legacy `_LOG_START` advance fails once (swallowed). The reaper
#       skips the live chunks. A second `migrate_partition` takes its
#       `already_migrated` branch, which still runs the retire walk: the
#       cursor reaches the legacy `next_offset`, the markers are re-stamped,
#       and the reaper reclaims the keys and keeps every `.seg`. Catches: the
#       old early return (the cursor never moved again).
#   (8) The same for the fold: the second `run_once` folds nothing (`_base`
#       anchors the watermark) but still retires shard `w01`; a third finds
#       the cursor at the watermark and re-stamps nothing (the reap at
#       60000 + grace still reclaims). Catches: a fold that retires only the
#       shards in its plan.
#   (9) Two reapers: between this reaper's LIST and its read of chunk 0's
#       MOVED marker, another reaper reaps chunk 0 (key, then marker). This
#       pass skips chunk 0 and reaps 1..3. Catches: the plain-tombstone read
#       raising not_found and aborting the whole pass.
#  (10) A transport error (503) reading a plain tombstone is NOT taken for
#       "another reaper took it": the pass raises and that chunk's `.seg` is
#       still there. Catches: the skip swallowing every error.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore, SegmentRef
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
    log_start_key,
    moved_tombstone_key,
    tombstone_key,
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
comptime _CLUSTER = "movedseg"
comptime _TOPIC = "t"
comptime _GRACE = Int64(60_000)
comptime _RECORDS = 10  # records per chunk

# Fault rules are marker objects in the shared store, so every clone sees them.
# A write (PUT / conditional PUT / CAS) to the target fails once.
comptime _FAIL_WRITE_ONCE = "__fault__/write_once/"
# A GET of the target reads as absent until the first plain tombstone write.
comptime _STALE_UNTIL_TOMB = "__fault__/stale_until_tomb/"
# A GET of the target finds it reaped by another reaper: the target is
# deleted and the GET reads as absent.
comptime _OTHER_REAPER = "__fault__/other_reaper/"
# A GET of the target fails with a transport error (not absence).
comptime _FAIL_GET = "__fault__/get/"


def _inner_has(inner: _Inner, key: String) -> Bool:
    try:
        _ = inner.head(Path.parse(key))
        return True
    except:
        return False


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates every verb to a shared in-memory store, applying the rules
    above."""

    var _inner: _Inner

    def __init__(out self, var inner: _Inner):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def arm(self, rule: String, target: String) raises:
        _ = self._inner.put(Path.parse(rule + target), List[UInt8]())

    def _write_fault(self, path: Path) raises:
        var rule = String(_FAIL_WRITE_ONCE) + path.raw()
        if _inner_has(self._inner, rule):
            self._inner.delete(Path.parse(rule))
            raise Error("injected fault: transport error status=503")

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if _inner_has(self._inner, String(_STALE_UNTIL_TOMB) + path.raw()):
            raise Error("injected: not_found (404), a stale pre-migration view")
        if _inner_has(self._inner, String(_FAIL_GET) + path.raw()):
            raise Error("injected fault: transport error status=503")
        var other = String(_OTHER_REAPER) + path.raw()
        if _inner_has(self._inner, other):
            self._inner.delete(Path.parse(other))
            self._inner.delete(path)
            raise Error("injected: not_found (404), another reaper took it")
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._write_fault(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._write_fault(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._write_fault(path)
        if path.raw().find("/tombstones/") >= 0:
            # The stale view ends with the first plain tombstone write.
            var res = self._inner.list_with_delimiter(
                Path.parse(String(_STALE_UNTIL_TOMB))
            )
            for i in range(len(res.objects)):
                self._inner.delete(Path.parse(res.objects[i].location))
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


comptime _Store = _FaultStore


# =============================================================================
# helpers
# =============================================================================


def _new_store() -> _Store:
    return _FaultStore(_Inner())


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


def _produce_at(store: _Store, prefix: String, pid: Int64, n_chunks: Int) raises:
    """`n_chunks` chunks of `_RECORDS` records into the manifest at `prefix`,
    created at ts 1000, 2000, ..."""
    var broker = BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, prefix),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=pid,
        broker_id=String("broker-A"),
    )
    for i in range(n_chunks):
        var ts = Int64(1000) + Int64(i) * Int64(1000)
        _ = broker.produce(_batch(Int64(i * _RECORDS), _RECORDS), ts)
        _ = broker.flush_if_buffered(ts)
    _ = broker^


def _seg_keys(store: _Store, prefix: String, n: Int) raises -> List[String]:
    var m = _manifest(store, prefix)
    var out = List[String]()
    for s in range(n):
        out.append(String(ManifestBody.decode(m.read_chunk(Int64(s))).object_key))
    _ = m^
    return out^


def _seg_bytes(store: _Store, keys: List[String]) raises -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    for i in range(len(keys)):
        out.append(store.get(Path.parse(keys[i])))
    return out^


def _reap(store: _Store, prefix: String, now_ms: Int64) raises -> ReapResult:
    var seg_store = store.clone()
    var m = _manifest(store, prefix)
    var w = ReapWorker[_Store](_GRACE)
    var r = w.run(seg_store, m, now_ms)
    _ = m^
    return r^


def _plain_tombstones(
    store: _Store, prefix: String, lo: Int, hi: Int, ts: Int64
) raises:
    """Plain tombstones on chunks [lo, hi) without moving `_LOG_START`."""
    var m = _manifest(store, prefix)
    for s in range(lo, hi):
        m.schedule_for_delete_at(Int64(s), ts)
    _ = m^


def _log_start(store: _Store, prefix: String) raises -> List[Int64]:
    var m = _manifest(store, prefix)
    var ls = m.read_log_start()
    _ = m^
    return [ls.log_start_seq, ls.log_start_offset]


def _assert_segs_kept(
    store: _Store,
    keys: List[String],
    snap: List[List[UInt8]],
    lo: Int,
    hi: Int,
    what: String,
) raises:
    for i in range(lo, hi):
        assert_true(_has(store, keys[i]), what + ": .seg " + String(i) + " kept")
        var now = store.get(Path.parse(keys[i]))
        assert_equal(len(now), len(snap[i]), what + ": .seg " + String(i) + " size")
        for b in range(len(now)):
            if now[b] != snap[i][b]:
                assert_true(False, what + ": .seg " + String(i) + " bytes changed")


def _assert_chunk_keys_gone(
    store: _Store, prefix: String, lo: Int, hi: Int, what: String
) raises:
    for s in range(lo, hi):
        assert_false(
            _has(store, chunk_key(prefix, Int64(s)).raw()),
            what + ": chunk key " + String(s) + " reaped",
        )


def _assert_base_serves(
    store: _Store,
    base_prefix: String,
    keys: List[String],
    lo: Int,
    first_offset: Int64,
    what: String,
) raises:
    """`_base` resolves `keys[lo:]` at consecutive offsets from `first_offset`,
    and each segment reads back with all `_RECORDS` records."""
    var r = SubLineageConsumeResolver[_Store](store.clone(), base_prefix)
    var refs = r.resolve_index()
    _ = r^
    assert_equal(len(refs), len(keys) - lo, what + ": `_base` segment count")
    var core = ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=_manifest(store, sublineage_prefix(base_prefix, BASE_SHARD_ID)),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(0),
    )
    var expect = first_offset
    for i in range(len(refs)):
        assert_equal(refs[i].object_key, keys[lo + i], what + ": `_base` key")
        assert_equal(refs[i].base_offset, expect, what + ": `_base` offset")
        assert_equal(refs[i].record_count, Int64(_RECORDS), what + ": count")
        var seg = core.read_segment(refs[i].copy())
        assert_equal(seg.base_offset, expect, what + ": read offset")
        assert_equal(seg.record_count, Int64(_RECORDS), what + ": records read")
        expect += Int64(_RECORDS)
    _ = core^


def _migrate(store: _Store, prefix: String, now_ms: Int64) raises -> Int:
    """Run one migration; returns its `source_chunks_retired`."""
    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(now_ms)
    _ = mig^
    return st.source_chunks_retired


# =============================================================================
# (1) migration, then a reap: `_base` keeps every segment
# =============================================================================


def test_migration_then_reap_keeps_base_segments() raises:
    print("[test_migration_then_reap_keeps_base_segments] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(0))
    _produce_at(store, prefix, Int64(0), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)

    assert_equal(_migrate(store, prefix, Int64(50_000)), 4, "4 retired")

    var r0 = _reap(store, prefix, Int64(50_000) + _GRACE - Int64(1))
    assert_equal(r0.reaped_count, Int64(0), "within grace of the migration")
    var r1 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(4), "4 legacy chunks reaped")
    assert_equal(r1.skipped_live_count, Int64(0), "none live")
    _assert_chunk_keys_gone(store, prefix, 0, 4, "migration")
    _assert_segs_kept(store, keys, snap, 0, 4, "migration")
    _assert_base_serves(store, prefix, keys, 0, Int64(0), "migration")
    print("[test_migration_then_reap_keeps_base_segments] PASS")


# =============================================================================
# (2) segment fold, then a reap of the shard: `_base` keeps every segment
# =============================================================================


def test_fold_then_reap_keeps_base_segments() raises:
    print("[test_fold_then_reap_keeps_base_segments] starting...")
    var store = _new_store()
    var base_prefix = _prefix(Int64(1))
    var sp = sublineage_prefix(base_prefix, String("w01"))
    _produce_at(store, sp, Int64(1), 3)
    var keys = _seg_keys(store, sp, 3)
    var snap = _seg_bytes(store, keys)
    _plain_tombstones(store, sp, 0, 1, Int64(10_000))  # stranded on chunk 0

    var fold = SegmentBaseFold[_Store](store.clone(), base_prefix)
    var st = fold.run_once(Int64(50_000))
    _ = fold^
    assert_equal(st.records_folded, Int64(30), "30 records folded")
    assert_equal(st.source_chunks_retired, 2, "2 newly retired")

    var r0 = _reap(store, sp, Int64(10_000) + _GRACE)
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the fold")
    var r1 = _reap(store, sp, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(3), "3 shard chunks reaped")
    _assert_chunk_keys_gone(store, sp, 0, 3, "fold")
    _assert_segs_kept(store, keys, snap, 0, 3, "fold")
    _assert_base_serves(store, base_prefix, keys, 0, Int64(0), "fold")
    print("[test_fold_then_reap_keeps_base_segments] PASS")


# =============================================================================
# (3) control: retention-retired chunks still lose their segments
# =============================================================================


def test_retention_retired_segments_still_reaped() raises:
    print("[test_retention_retired_segments_still_reaped] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(2))
    _produce_at(store, prefix, Int64(2), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)

    # Ages at 10000: 9000, 8000, 7000 (chunk 3 is active): 0 and 1 retire.
    var m = _manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.time_based(Int64(7500)))
    var res = rp.run(m, Int64(10_000))
    _ = rp^
    _ = m^
    assert_equal(res.new_log_start_seq, Int64(2), "retention retired 0, 1")
    assert_equal(_migrate(store, prefix, Int64(50_000)), 2, "2, 3 retired")

    var r1 = _reap(store, prefix, Int64(10_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(2), "retention chunks 0, 1 reaped")
    for i in range(2):
        assert_false(_has(store, keys[i]), "retention .seg " + String(i) + " deleted")
    _assert_chunk_keys_gone(store, prefix, 0, 2, "retention")
    _assert_segs_kept(store, keys, snap, 2, 4, "migrated, within grace")

    var r2 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r2.reaped_count, Int64(2), "migrated chunks 2, 3 reaped")
    _assert_chunk_keys_gone(store, prefix, 2, 4, "migrated")
    _assert_segs_kept(store, keys, snap, 2, 4, "migrated")
    _assert_base_serves(store, prefix, keys, 2, Int64(20), "mixed")
    print("[test_retention_retired_segments_still_reaped] PASS")


# =============================================================================
# (4) stranded plain tombstones: grace counts from the migration
# =============================================================================


def test_migration_restamps_stranded_tombstones() raises:
    print("[test_migration_restamps_stranded_tombstones] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(3))
    _produce_at(store, prefix, Int64(3), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)
    _plain_tombstones(store, prefix, 0, 2, Int64(10_000))

    assert_equal(_migrate(store, prefix, Int64(50_000)), 2, "only 2, 3 new")

    var r0 = _reap(store, prefix, Int64(10_000) + _GRACE)
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the migration")
    _assert_segs_kept(store, keys, snap, 0, 4, "within grace")
    var r1 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(4), "4 legacy chunks reaped")
    _assert_chunk_keys_gone(store, prefix, 0, 4, "stranded")
    _assert_segs_kept(store, keys, snap, 0, 4, "stranded")
    _assert_base_serves(store, prefix, keys, 0, Int64(0), "stranded")
    print("[test_migration_restamps_stranded_tombstones] PASS")


# =============================================================================
# (5) a RetentionPass with a pre-migration snapshot, after the migration retire
# =============================================================================


def test_retention_after_migration_retire_keeps_segments() raises:
    print("[test_retention_after_migration_retire_keeps_segments] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(4))
    _produce_at(store, prefix, Int64(4), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)
    assert_equal(_migrate(store, prefix, Int64(50_000)), 4, "4 retired")
    assert_equal(_log_start(store, prefix)[0], Int64(4), "legacy cursor at 4")

    # The pass reads the pointer as it was before the migration (absent), so
    # it sees chunks 0..2 as live and out of policy (ages 59000, 58000, 57000
    # at 60000) and tombstones them, plain. Its advance then sees the real
    # pointer, already past its target: a no-op.
    store.arm(String(_STALE_UNTIL_TOMB), log_start_key(prefix).raw())
    var m = _manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.time_based(Int64(56_500)))
    var res = rp.run(m, Int64(60_000))
    _ = rp^
    _ = m^
    assert_equal(res.tombstoned_count, Int64(3), "the stale pass tombstoned 0..2")
    assert_equal(_log_start(store, prefix)[0], Int64(4), "pointer not moved back")

    var r = _reap(store, prefix, Int64(60_000) + _GRACE)
    _assert_segs_kept(store, keys, snap, 0, 4, "retention after migration")
    assert_equal(r.reaped_count, Int64(4), "4 legacy chunk keys reaped")
    _assert_chunk_keys_gone(store, prefix, 0, 4, "retention after migration")
    _assert_base_serves(store, prefix, keys, 0, Int64(0), "retention after")
    print("[test_retention_after_migration_retire_keeps_segments] PASS")


# =============================================================================
# (6) an older plain tombstone beside a MOVED marker
# =============================================================================


def test_plain_and_moved_on_one_chunk_keeps_segment() raises:
    print("[test_plain_and_moved_on_one_chunk_keeps_segment] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(5))
    _produce_at(store, prefix, Int64(5), 3)
    var keys = _seg_keys(store, prefix, 3)
    var snap = _seg_bytes(store, keys)
    assert_equal(_migrate(store, prefix, Int64(50_000)), 3, "3 retired")
    _plain_tombstones(store, prefix, 0, 1, Int64(1))

    var r0 = _reap(store, prefix, Int64(50_000) + _GRACE - Int64(1))
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the MOVED marker")
    _assert_segs_kept(store, keys, snap, 0, 3, "before grace")
    var r1 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(3), "3 reaped")
    _assert_chunk_keys_gone(store, prefix, 0, 3, "plain and moved")
    _assert_segs_kept(store, keys, snap, 0, 3, "plain and moved")
    assert_false(
        _has(store, prefix + "/tombstones/" + "00000000000000000000.tomb"),
        "the plain marker is reaped too",
    )
    print("[test_plain_and_moved_on_one_chunk_keeps_segment] PASS")


# =============================================================================
# (7) a failed legacy advance; the `already_migrated` re-run finishes it
# =============================================================================


def test_migration_rerun_after_failed_advance() raises:
    print("[test_migration_rerun_after_failed_advance] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(6))
    _produce_at(store, prefix, Int64(6), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)

    store.arm(String(_FAIL_WRITE_ONCE), log_start_key(prefix).raw())
    assert_equal(_migrate(store, prefix, Int64(50_000)), 4, "4 retired")
    assert_equal(_log_start(store, prefix)[0], Int64(0), "the advance failed")
    var r0 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r0.reaped_count, Int64(0), "live: nothing reaped")
    assert_equal(r0.skipped_live_count, Int64(4), "4 live markers skipped")

    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(Int64(60_000))
    _ = mig^
    assert_true(st.already_migrated, "the re-run finds `_base` complete")
    assert_equal(st.source_chunks_retired, 0, "no new marker")
    var ls = _log_start(store, prefix)
    assert_equal(ls[0], Int64(4), "legacy cursor seq reaches the tail")
    assert_equal(ls[1], Int64(40), "legacy cursor offset = legacy next_offset")

    var r1 = _reap(store, prefix, Int64(60_000) + _GRACE - Int64(1))
    assert_equal(r1.reaped_count, Int64(0), "re-stamped: grace from 60000")
    var r2 = _reap(store, prefix, Int64(60_000) + _GRACE)
    assert_equal(r2.reaped_count, Int64(4), "4 legacy chunk keys reaped")
    _assert_chunk_keys_gone(store, prefix, 0, 4, "migration re-run")
    _assert_segs_kept(store, keys, snap, 0, 4, "migration re-run")
    _assert_base_serves(store, prefix, keys, 0, Int64(0), "migration re-run")
    print("[test_migration_rerun_after_failed_advance] PASS")


# =============================================================================
# (8) a failed shard advance; the next fold retires the shard anyway
# =============================================================================


def test_fold_rerun_after_failed_advance() raises:
    print("[test_fold_rerun_after_failed_advance] starting...")
    var store = _new_store()
    var base_prefix = _prefix(Int64(7))
    var sp = sublineage_prefix(base_prefix, String("w01"))
    _produce_at(store, sp, Int64(7), 3)
    var keys = _seg_keys(store, sp, 3)
    var snap = _seg_bytes(store, keys)

    store.arm(String(_FAIL_WRITE_ONCE), log_start_key(sp).raw())
    var fold = SegmentBaseFold[_Store](store.clone(), base_prefix)
    var st1 = fold.run_once(Int64(50_000))
    assert_equal(st1.records_folded, Int64(30), "30 records folded")
    assert_equal(_log_start(store, sp)[0], Int64(0), "the advance failed")
    var r0 = _reap(store, sp, Int64(50_000) + _GRACE)
    assert_equal(r0.skipped_live_count, Int64(3), "3 live markers skipped")

    var st2 = fold.run_once(Int64(60_000))
    assert_equal(st2.records_folded, Int64(0), "nothing left to fold")
    assert_equal(st2.source_chunks_retired, 0, "no new marker")
    var ls = _log_start(store, sp)
    assert_equal(ls[0], Int64(3), "shard cursor seq reaches the tail")
    assert_equal(ls[1], Int64(30), "shard cursor offset = folded watermark")
    # A third round finds the cursor at the watermark: it writes nothing (the
    # markers keep their 60000 stamp, so the reap below is on time).
    var st3 = fold.run_once(Int64(65_000))
    _ = fold^
    assert_equal(st3.source_chunks_retired, 0, "steady state: nothing retired")

    var r1 = _reap(store, sp, Int64(60_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(3), "3 shard chunk keys reaped")
    _assert_chunk_keys_gone(store, sp, 0, 3, "fold re-run")
    _assert_segs_kept(store, keys, snap, 0, 3, "fold re-run")
    _assert_base_serves(store, base_prefix, keys, 0, Int64(0), "fold re-run")
    print("[test_fold_rerun_after_failed_advance] PASS")


# =============================================================================
# (9) a concurrent reaper takes a MOVED-only seq after this pass's LIST
# =============================================================================


def test_concurrent_reaper_took_a_moved_seq() raises:
    print("[test_concurrent_reaper_took_a_moved_seq] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(8))
    _produce_at(store, prefix, Int64(8), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)
    assert_equal(_migrate(store, prefix, Int64(50_000)), 4, "4 retired")

    # The other reaper deleted chunk 0's key; its marker goes on our GET.
    store.delete(chunk_key(prefix, Int64(0)))
    store.arm(String(_OTHER_REAPER), moved_tombstone_key(prefix, Int64(0)).raw())
    var r = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(3), "chunks 1..3 reaped, 0 skipped")
    assert_false(
        _has(store, String(_OTHER_REAPER) + moved_tombstone_key(prefix, Int64(0)).raw()),
        "the other reaper ran",
    )
    _assert_chunk_keys_gone(store, prefix, 0, 4, "two reapers")
    _assert_segs_kept(store, keys, snap, 0, 4, "two reapers")
    print("[test_concurrent_reaper_took_a_moved_seq] PASS")


# =============================================================================
# (10) a transport error on the plain tombstone read raises
# =============================================================================


def test_plain_tombstone_read_error_raises() raises:
    print("[test_plain_tombstone_read_error_raises] starting...")
    var store = _new_store()
    var prefix = _prefix(Int64(9))
    _produce_at(store, prefix, Int64(9), 3)
    var keys = _seg_keys(store, prefix, 3)
    var m = _manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.time_based(Int64(7500)))
    var res = rp.run(m, Int64(10_000))
    _ = rp^
    _ = m^
    assert_equal(res.new_log_start_seq, Int64(2), "retention retired 0, 1")

    store.arm(String(_FAIL_GET), tombstone_key(prefix, Int64(0)).raw())
    var raised = False
    try:
        _ = _reap(store, prefix, Int64(10_000) + _GRACE)
    except e:
        raised = True
        assert_true(String(e).find("503") >= 0, String(e))
    assert_true(raised, "the transport error is raised, not skipped")
    assert_true(_has(store, keys[0]), ".seg 0 still there")
    print("[test_plain_tombstone_read_error_raises] PASS")


def main() raises:
    test_migration_then_reap_keeps_base_segments()
    test_fold_then_reap_keeps_base_segments()
    test_retention_retired_segments_still_reaped()
    test_migration_restamps_stranded_tombstones()
    test_retention_after_migration_retire_keeps_segments()
    test_plain_and_moved_on_one_chunk_keeps_segment()
    test_migration_rerun_after_failed_advance()
    test_fold_rerun_after_failed_advance()
    test_concurrent_reaper_took_a_moved_seq()
    test_plain_tombstone_read_error_raises()
    print("[OK] test_broker_moved_payload_reap_offline — 10 cases passed")
