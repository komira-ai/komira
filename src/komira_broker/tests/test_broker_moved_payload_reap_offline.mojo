# =============================================================================
# tests/test_broker_moved_payload_reap_offline.mojo
#   The reaper keeps the `.seg` objects `_base` reads — OFFLINE
# =============================================================================
#
# A sub-lineage migration re-records the legacy manifest's chunks into
# `_base`, and the segment fold re-records a writer shard's chunks there, both
# REUSING the same `.seg` objects. Each then tombstones its source chunks. The
# `ReapWorker` deleted a tombstoned chunk's `.seg` with its key, so a reap of
# the legacy prefix (the partition prefix `BrokerCore.reap_partition` reaps)
# or of a shard prefix deleted data `_base` serves (komira-ai/komira#494). Now
# both tombstone with `payload_moved` and the reaper reclaims only the chunk
# key.
#
#   (1) Migrate 4 legacy chunks, reap past grace: the legacy chunk keys are
#       gone, every `.seg` is present and byte-identical, and `_base` serves
#       all 40 records at offsets 0..39. Catches: the reaper ignoring the
#       flag; the migration not setting it.
#   (2) The same for the segment fold over shard `w01`, whose chunk 0 carries
#       a stranded tombstone without the flag from before the fold. Catches:
#       the fold not setting the flag; the fold leaving the stranded
#       tombstone as it was; the fold stamping wall-clock time, not `now_ms`.
#   (3) Control: retention retires chunks 0 and 1, then the migration moves
#       2 and 3. The reaper deletes the `.seg` of 0 and 1 (retention
#       tombstones, nothing references them) and keeps those of 2 and 3.
#       Catches: a fix that stops reaping segments at all.
#   (4) Grace (#494's second half): a failed RetentionPass advance left
#       tombstones on live chunks 0 and 1 at ts 10000. The migration moves
#       them past `_LOG_START` at ts 50000. It re-stamps them, so the reaper
#       waits a full grace from 50000 and then keeps their `.seg`. The
#       migration counts only the 2 chunks it newly tombstoned. Catches: the
#       old skip of already-tombstoned chunks (old ts, no flag: deleted at
#       once).
#   (5) Compatibility: a tombstone body written in the old 8-byte format
#       (raw bytes, not through the encoder) still reaps chunk and `.seg`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

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
    tombstone_key,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.sublineage_base_fold import BASE_SHARD_ID


comptime _Store = SharedInMemoryConditionalStore
comptime _CLUSTER = "movedseg"
comptime _TOPIC = "t"
comptime _GRACE = Int64(60_000)
comptime _RECORDS = 10  # records per chunk


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


def _strand_tombstones(
    store: _Store, prefix: String, n: Int, ts: Int64
) raises:
    """Tombstone chunks [0, n) without advancing `_LOG_START`: what a
    RetentionPass whose advance failed leaves behind."""
    var m = _manifest(store, prefix)
    for s in range(n):
        m.schedule_for_delete_at(Int64(s), ts)
    assert_equal(m.read_log_start_seq(), Int64(0), "stranded: log start unmoved")
    _ = m^


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


# =============================================================================
# (1) migration, then a reap: `_base` keeps every segment
# =============================================================================


def test_migration_then_reap_keeps_base_segments() raises:
    print("[test_migration_then_reap_keeps_base_segments] starting...")
    var store = _Store()
    var prefix = _prefix(Int64(0))
    _produce_at(store, prefix, Int64(0), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)

    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(Int64(50_000))
    _ = mig^
    assert_equal(st.records_migrated, Int64(40), "40 records migrated")
    assert_equal(st.source_chunks_retired, 4, "4 legacy chunks retired")

    var r0 = _reap(store, prefix, Int64(50_000) + _GRACE - Int64(1))
    assert_equal(r0.reaped_count, Int64(0), "within grace of the migration")
    var r1 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(4), "4 legacy chunks reaped")
    assert_equal(r1.skipped_live_count, Int64(0), "none live")
    _assert_chunk_keys_gone(store, prefix, 0, 4, "migration")
    _assert_segs_kept(store, keys, snap, 0, 4, "migration")
    _assert_base_serves(store, prefix, keys, 0, Int64(0), "migration")
    _ = store^
    print("[test_migration_then_reap_keeps_base_segments] PASS")


# =============================================================================
# (2) segment fold, then a reap of the shard: `_base` keeps every segment
# =============================================================================


def test_fold_then_reap_keeps_base_segments() raises:
    print("[test_fold_then_reap_keeps_base_segments] starting...")
    var store = _Store()
    var base_prefix = _prefix(Int64(1))
    var sp = sublineage_prefix(base_prefix, String("w01"))
    _produce_at(store, sp, Int64(1), 3)
    var keys = _seg_keys(store, sp, 3)
    var snap = _seg_bytes(store, keys)
    _strand_tombstones(store, sp, 1, Int64(10_000))

    var fold = SegmentBaseFold[_Store](store.clone(), base_prefix)
    var st = fold.run_once(Int64(50_000))
    _ = fold^
    assert_equal(st.records_folded, Int64(30), "30 records folded")
    assert_equal(st.source_chunks_retired, 2, "2 newly tombstoned")

    var r0 = _reap(store, sp, Int64(10_000) + _GRACE)
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the fold")
    var r1 = _reap(store, sp, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(3), "3 shard chunks reaped")
    _assert_chunk_keys_gone(store, sp, 0, 3, "fold")
    _assert_segs_kept(store, keys, snap, 0, 3, "fold")
    _assert_base_serves(store, base_prefix, keys, 0, Int64(0), "fold")
    _ = store^
    print("[test_fold_then_reap_keeps_base_segments] PASS")


# =============================================================================
# (3) control: retention-retired chunks still lose their segments
# =============================================================================


def test_retention_retired_segments_still_reaped() raises:
    print("[test_retention_retired_segments_still_reaped] starting...")
    var store = _Store()
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

    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(Int64(50_000))
    _ = mig^
    assert_equal(st.base_offset_start, Int64(20), "`_base` starts at 20")
    assert_equal(st.records_migrated, Int64(20), "chunks 2, 3 migrated")

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
    _ = store^
    print("[test_retention_retired_segments_still_reaped] PASS")


# =============================================================================
# (4) a stranded retention tombstone is re-stamped by the migration
# =============================================================================


def test_migration_restamps_stranded_tombstones() raises:
    print("[test_migration_restamps_stranded_tombstones] starting...")
    var store = _Store()
    var prefix = _prefix(Int64(3))
    _produce_at(store, prefix, Int64(3), 4)
    var keys = _seg_keys(store, prefix, 4)
    var snap = _seg_bytes(store, keys)
    _strand_tombstones(store, prefix, 2, Int64(10_000))

    var mig = SubLineageMigration[_Store](store.clone(), prefix)
    var st = mig.migrate_partition(Int64(50_000))
    _ = mig^
    assert_equal(st.records_migrated, Int64(40), "all 40 records migrated")
    assert_equal(st.source_chunks_retired, 2, "only 2, 3 newly tombstoned")
    var m = _manifest(store, prefix)
    for s in range(2):
        assert_equal(
            m.tombstone_schedule_ts(Int64(s)),
            Int64(50_000),
            "stranded tombstone " + String(s) + " re-stamped",
        )
    _ = m^

    var r0 = _reap(store, prefix, Int64(10_000) + _GRACE)
    assert_equal(r0.reaped_count, Int64(0), "grace counts from the migration")
    _assert_segs_kept(store, keys, snap, 0, 4, "within grace")
    var r1 = _reap(store, prefix, Int64(50_000) + _GRACE)
    assert_equal(r1.reaped_count, Int64(4), "4 legacy chunks reaped")
    _assert_chunk_keys_gone(store, prefix, 0, 4, "stranded")
    _assert_segs_kept(store, keys, snap, 0, 4, "stranded")
    _assert_base_serves(store, prefix, keys, 0, Int64(0), "stranded")
    _ = store^
    print("[test_migration_restamps_stranded_tombstones] PASS")


# =============================================================================
# (5) an old-format tombstone reaps chunk and segment as before
# =============================================================================


def _le8(v: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


def test_old_format_tombstone_reaps_segment() raises:
    print("[test_old_format_tombstone_reaps_segment] starting...")
    var store = _Store()
    var prefix = _prefix(Int64(4))
    _produce_at(store, prefix, Int64(4), 3)
    var keys = _seg_keys(store, prefix, 3)
    var snap = _seg_bytes(store, keys)
    var m = _manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.time_based(Int64(7500)))
    var res = rp.run(m, Int64(10_000))
    _ = rp^
    _ = m^
    assert_equal(res.new_log_start_seq, Int64(2), "retention retired 0, 1")
    # Overwrite both markers with the pre-flag body, byte for byte.
    for s in range(2):
        _ = store.put(tombstone_key(prefix, Int64(s)), _le8(Int64(10_000)))

    var r = _reap(store, prefix, Int64(10_000) + _GRACE)
    assert_equal(r.reaped_count, Int64(2), "both reaped")
    for i in range(2):
        assert_false(_has(store, keys[i]), "old-format .seg " + String(i) + " deleted")
    _assert_chunk_keys_gone(store, prefix, 0, 2, "old format")
    _assert_segs_kept(store, keys, snap, 2, 3, "active chunk")
    _ = store^
    print("[test_old_format_tombstone_reaps_segment] PASS")


def main() raises:
    test_migration_then_reap_keeps_base_segments()
    test_fold_then_reap_keeps_base_segments()
    test_retention_retired_segments_still_reaped()
    test_migration_restamps_stranded_tombstones()
    test_old_format_tombstone_reaps_segment()
    print("[OK] test_broker_moved_payload_reap_offline — 5 cases passed")
