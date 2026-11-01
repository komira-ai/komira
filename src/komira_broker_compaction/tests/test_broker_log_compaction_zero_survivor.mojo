# =============================================================================
# test_broker_log_compaction_zero_survivor.mojo
#   The zero-survivor (fully superseded) chunk case
# =============================================================================
#
# A cleanable chunk whose every key is re-written at a higher offset in a later
# cleanable chunk has zero survivors: its whole [base, last] offset span becomes
# a gap in the compacted log (offsets are preserved, never renumbered; a
# fully-superseded chunk is skipped).
#
# The failure this test pins: `ProductionLogCleaner.run_once` re-encoded the
# empty survivor set into a sparse `.seg` and wrote an empty survivor-offset
# sidecar (count == 0). An empty sidecar is indistinguishable from no sidecar (an
# un-compacted chunk): `decode_compacted_survivor_offsets` returns
# `List[Int64]()` for both. So:
#   * the idempotency guard (`was_compacted = len(sc) > 0`) reads the
#     zero-survivor compacted chunk as un-compacted on the next round, and a
#     second run_once rewrites it again (a new `.seg`, a new orphan), so the
#     round is not idempotent;
#   * the consume path's `len(sidecar) == nrows` offset reconstruction cannot
#     tell a zero-survivor compacted chunk from an un-compacted one.
#
# The cleaner represents a zero-survivor chunk as an empty-segment marker in the
# manifest body (offset span preserved, no live `.seg`), so it is unambiguously
# "compacted, zero survivors". The chunk's original `.seg` is still scheduled
# for grace-gated orphan GC.
#
# Scenario (3 chunks; the cleaner excludes only the highest chunk_seq, the
# active chunk):
#   CHUNK 0 (cleanable, offsets 0..2): A->a0@0, B->b0@1, C->c0@2
#   CHUNK 1 (cleanable, offsets 3..5): A->a1@3, B->b1@4, C->c1@5  (re-writes all)
#   CHUNK 2 (ACTIVE,    offsets 6..7): D->d0@6, E->e0@7           (never compacted)
# Chunk 0 is fully superseded by chunk 1, so it has zero survivors and its span
# [0,2] is a gap. Chunk 1's three records are the global latest-per-key, so all
# survive (chunk 1 is already clean, with no local drops, so it is skipped).
# Chunk 2 is untouched.
#
# Offline: the clone-shared in-memory ConditionalWriteStore.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.string_array import StringArray

from komira_broker.broker_core import BrokerCore, BrokerTopicConfig
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.manifest_body import ManifestBody
from komira_broker.log_compaction import (
    CompactionConfig,
    decode_compacted_survivor_offsets,
    CLEANUP_POLICY_COMPACT,
)

from komira_broker_compaction.log_cleaner_driver import (
    ProductionLogCleaner,
    ProductionCleanResult,
    CompactionReapWorker,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers — (key:INT64, value:STRING-nullable) batch; tombstone = null value.
# =============================================================================


def _kv_schema() raises -> Schema:
    return Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.STRING.type_id],
        dtypes=[DType.int64, DType.uint8],
        nullables=[False, True],
    )


def _make_kv_batch(
    keys: List[Int64], values: List[String], valids: List[Bool]
) raises -> RecordBatch:
    """A (key:INT64, value:STRING-nullable) batch. `valids[i]==False` makes row i
    a TOMBSTONE (null value)."""
    var n = len(keys)
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var p = karr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, keys[i])
    var kcol = Column.from_primitive[DType.int64](karr^)
    var varr = StringArray.from_strings_with_validity(values, valids)
    var vcol = Column.from_string(varr^)
    return RecordBatch.from_typed_columns_2(_kv_schema(), kcol^, vcol^)


def _prefix(cluster: String, topic: String, partition: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(partition)


def _make_broker(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> BrokerCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
        broker_id=String("broker-A"),
    )


def _make_consume(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> ConsumeCore[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
    )


def _make_cleaner(
    store: _Store,
    cluster: String,
    topic: String,
    partition: Int64,
    config: CompactionConfig,
) raises -> ProductionLogCleaner[_Store]:
    var consume = _make_consume(store, cluster, topic, partition)
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return ProductionLogCleaner[_Store](
        consume=consume^,
        segment_store=store.clone(),
        manifest=manifest^,
        config=config,
        cluster=cluster,
        topic=topic,
        partition=partition,
        key_col=0,
        value_col=1,
    )


def _make_reaper(
    store: _Store, cluster: String, topic: String, partition: Int64,
    grace_ms: Int64,
) raises -> CompactionReapWorker[_Store]:
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, partition),
        retry=RetryPolicy.fast_test(),
    )
    return CompactionReapWorker[_Store](
        segment_store=store.clone(), manifest=manifest^, grace_ms=grace_ms
    )


def _object_exists(store: _Store, key: String) raises -> Bool:
    var s = store.clone()
    try:
        var _b = s.get(Path.parse(key))
        _ = _b
        return True
    except e:
        var msg = String(e)
        if (
            msg.find("not_found") >= 0
            or msg.find("NotFound") >= 0
            or msg.find("404") >= 0
            or msg.find("NoSuchKey") >= 0
        ):
            return False
        raise e^


# -----------------------------------------------------------------------------
# _ConsumedRow / _consume_all — drain a partition back into (key, value, tomb,
# abs_offset) tuples, computing each row's ABSOLUTE offset from the manifest's
# per-chunk base + the survivor-offset sidecar. A compacted chunk is SPARSE: its
# rows sit at their PRESERVED original offsets (sidecar[r]); an un-compacted
# chunk is dense (base + r). A ZERO-SURVIVOR chunk is an empty-segment marker —
# `_consume_all` must skip it cleanly (its span is a pure gap).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ConsumedRow(Copyable, Movable, Deinitable):
    var key: Int64
    var value: String
    var is_tombstone: Bool
    var abs_offset: Int64


def _consume_all(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises -> List[_ConsumedRow]:
    var consume = _make_consume(store, cluster, topic, partition)
    var index = consume.resolve_index()
    var out = List[_ConsumedRow]()
    for i in range(len(index)):
        ref s = index[i]
        # GET + decode the `.seg` → one RecordBatch (a compacted chunk is
        # sparse; a zero-survivor chunk's `.seg` decodes to 0 rows OR is absent
        # and represented by the empty-segment marker — either way the consume
        # yields no rows for it).
        var seg = consume.read_segment(s.copy())
        var stream = seg^.take_stream_bytes()
        var batch = decode_arrow_ipc_stream(stream^)
        var nrows = batch.num_rows()
        for r in range(nrows):
            var key = batch.column_value(0, r)
            var sa = batch.column_as_string(1)
            var tomb = sa.is_null(r)
            var val = String("") if tomb else sa.get(r)
            out.append(
                _ConsumedRow(
                    key=key,
                    value=val^,
                    is_tombstone=tomb,
                    abs_offset=s.base_offset + Int64(r),
                )
            )
    _ = consume^
    return out^


def _build_superseded_partition(
    store: _Store, cluster: String, topic: String, partition: Int64
) raises:
    """CHUNK 0 fully superseded by CHUNK 1 (both re-write keys A,B,C); CHUNK 2 is
    the active head."""
    var broker = _make_broker(store, cluster, topic, partition)
    # CHUNK 0 (cleanable, offsets 0..2): A->a0, B->b0, C->c0.
    var b0 = _make_kv_batch(
        [Int64(1), Int64(2), Int64(3)],
        [String("a0"), String("b0"), String("c0")],
        [True, True, True],
    )
    _ = broker.produce(b0^, Int64(1000))
    _ = broker.flush_if_buffered(Int64(1000))
    # CHUNK 1 (cleanable, offsets 3..5): A->a1, B->b1, C->c1 — RE-WRITES all of
    # chunk 0's keys at higher offsets → chunk 0 is FULLY SUPERSEDED.
    var b1 = _make_kv_batch(
        [Int64(1), Int64(2), Int64(3)],
        [String("a1"), String("b1"), String("c1")],
        [True, True, True],
    )
    _ = broker.produce(b1^, Int64(2000))
    _ = broker.flush_if_buffered(Int64(2000))
    # CHUNK 2 (ACTIVE, offsets 6..7): D->d0, E->e0 — never compacted.
    var b2 = _make_kv_batch(
        [Int64(4), Int64(5)], [String("d0"), String("e0")], [True, True]
    )
    _ = broker.produce(b2^, Int64(3000))
    _ = broker.flush_if_buffered(Int64(3000))
    _ = broker^


# =============================================================================
# (1) The cleaner does NOT raise on a fully-superseded (zero-survivor) chunk;
#     chunk 0 becomes an empty gap, chunk 1's survivors are intact, and a
#     consume over the whole range yields {A,B,C}-latest with chunk 0 gapped.
# =============================================================================


def test_zero_survivor_chunk_compacts_to_gap() raises:
    print("[test_zero_survivor_chunk_compacts_to_gap] starting...")
    var store = _Store()
    var cluster = String("zsGAP")
    var topic = String("compactT")
    var pid = Int64(0)
    _build_superseded_partition(store, cluster, topic, pid)

    var cleaner = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(86_400_000))
    )
    # MUST NOT raise (the RED: pre-fix this re-encoded a malformed empty `.seg`
    # / emitted an ambiguous empty sidecar).
    var res = cleaner.run_once(Int64(10_000))
    _ = cleaner^
    assert_true(res.ran, "cleaner ran")
    assert_equal(res.cleanable_chunks, Int64(2), "2 cleanable chunks (0,1)")
    assert_equal(res.records_scanned, Int64(6), "6 records scanned (chunks 0+1)")
    # Global latest-per-key over the cleanable range: A->a1@3, B->b1@4, C->c1@5.
    # → 3 survivors (all originate in chunk 1); 3 dropped (a0@0, b0@1, c0@2).
    assert_equal(res.survivors, Int64(3), "3 survivors (all chunk 1)")
    assert_equal(res.dropped, Int64(3), "3 dropped (chunk 0 fully superseded)")
    # Chunk 0 has ZERO local survivors → it IS rewritten (to an empty marker).
    # Chunk 1 has NO local drops (all 3 records are global latest) → SKIPPED.
    assert_equal(
        res.chunks_rewritten, Int64(1),
        "only chunk 0 rewritten (zero-survivor → empty-segment marker)",
    )
    assert_equal(
        res.orphans_scheduled, Int64(1),
        "chunk 0's original `.seg` scheduled for orphan GC",
    )

    # record_count PRESERVED on ALL chunks — chunk 0 still reports 3 (so the
    # offset span [0,2] stays a gap; downstream chunks never renumber).
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var mb0 = ManifestBody.decode(manifest.read_chunk(Int64(0)))
    assert_equal(
        mb0.record_count, Int64(3),
        "chunk 0 record_count PRESERVED (3) — span [0,2] is a gap",
    )
    var mb1 = ManifestBody.decode(manifest.read_chunk(Int64(1)))
    assert_equal(mb1.record_count, Int64(3), "chunk 1 record_count PRESERVED (3)")
    var mb2 = ManifestBody.decode(manifest.read_chunk(Int64(2)))
    assert_equal(mb2.record_count, Int64(2), "active chunk 2 record_count = 2")
    _ = manifest^

    # CONSUME the whole partition back. Chunk 0 yields NO rows (its span is a
    # pure gap); chunk 1's survivors {a1@3, b1@4, c1@5}; active {d0@6, e0@7}.
    var rows = _consume_all(store, cluster, topic, pid)
    assert_equal(
        len(rows), 5,
        "5 rows after compaction (3 chunk-1 survivors + 2 active; chunk 0"
        " fully gapped)",
    )
    # Chunk 0's [0,2] is a pure GAP — no row at offsets 0,1,2.
    var c0_gap = True
    var c1_a = False
    var c1_b = False
    var c1_c = False
    var act_d = False
    var act_e = False
    for i in range(len(rows)):
        var o = rows[i].abs_offset
        if o == Int64(0) or o == Int64(1) or o == Int64(2):
            c0_gap = False
        if o == Int64(3) and rows[i].key == Int64(1) and rows[i].value == "a1":
            c1_a = True
        if o == Int64(4) and rows[i].key == Int64(2) and rows[i].value == "b1":
            c1_b = True
        if o == Int64(5) and rows[i].key == Int64(3) and rows[i].value == "c1":
            c1_c = True
        if o == Int64(6) and rows[i].key == Int64(4) and rows[i].value == "d0":
            act_d = True
        if o == Int64(7) and rows[i].key == Int64(5) and rows[i].value == "e0":
            act_e = True
    assert_true(c0_gap, "chunk 0 span [0,2] is a pure GAP (no rows)")
    assert_true(c1_a, "chunk 1 A->a1 @3 survives (latest)")
    assert_true(c1_b, "chunk 1 B->b1 @4 survives (latest)")
    assert_true(c1_c, "chunk 1 C->c1 @5 survives (latest)")
    assert_true(act_d, "active D->d0 @6 untouched")
    assert_true(act_e, "active E->e0 @7 untouched")
    _ = store^
    print("[test_zero_survivor_chunk_compacts_to_gap] PASS")


# =============================================================================
# (2) IDEMPOTENCY — a SECOND run_once over an already-zero-survivor'd chunk is a
#     NO-OP (no re-rewrite, no new orphan). The pre-fix RED: the empty sidecar
#     was read as "un-compacted", so the second run re-rewrote chunk 0 again.
# =============================================================================


def test_zero_survivor_rerun_is_noop() raises:
    print("[test_zero_survivor_rerun_is_noop] starting...")
    var store = _Store()
    var cluster = String("zsIDEM")
    var topic = String("compactT")
    var pid = Int64(0)
    _build_superseded_partition(store, cluster, topic, pid)

    var cleaner1 = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(86_400_000))
    )
    var res1 = cleaner1.run_once(Int64(10_000))
    _ = cleaner1^
    assert_equal(res1.chunks_rewritten, Int64(1), "first run rewrites chunk 0")
    assert_equal(res1.orphans_scheduled, Int64(1), "first run schedules 1 orphan")

    # Capture chunk 0's body AFTER the first compaction (the empty-segment
    # representation). The second run must leave it byte-stable.
    var manifest = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var body_after1 = manifest.read_chunk(Int64(0))
    var mb0_after1 = ManifestBody.decode(body_after1)
    var key_after1 = String(mb0_after1.object_key)
    _ = manifest^

    # SECOND run_once — MUST be a no-op for chunk 0 (already zero-survivor'd).
    var cleaner2 = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(86_400_000))
    )
    var res2 = cleaner2.run_once(Int64(20_000))
    _ = cleaner2^
    assert_equal(
        res2.chunks_rewritten, Int64(0),
        "second run REWRITES NOTHING (chunk 0 already zero-survivor'd —"
        " idempotent; RED: pre-fix re-rewrote it)",
    )
    assert_equal(
        res2.orphans_scheduled, Int64(0),
        "second run schedules NO new orphan (idempotent)",
    )

    # Chunk 0's body is byte-stable across the no-op second run (same object_key,
    # same record_count).
    var manifest2 = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var mb0_after2 = ManifestBody.decode(manifest2.read_chunk(Int64(0)))
    assert_equal(
        String(mb0_after2.object_key), key_after1,
        "chunk 0 object_key unchanged by the no-op second run",
    )
    assert_equal(
        mb0_after2.record_count, Int64(3),
        "chunk 0 record_count still PRESERVED (3) after second run",
    )
    _ = manifest2^

    # And it still consumes to the same 5-row result.
    var rows = _consume_all(store, cluster, topic, pid)
    assert_equal(len(rows), 5, "still 5 rows after the idempotent second run")
    _ = store^
    print("[test_zero_survivor_rerun_is_noop] PASS")


# =============================================================================
# (3) ORPHAN GC — the original (pre-compaction) `.seg` of a now-empty chunk is
#     scheduled for grace-gated orphan GC (same as the >=1-survivor path).
# =============================================================================


def test_zero_survivor_orphan_gc() raises:
    print("[test_zero_survivor_orphan_gc] starting...")
    var store = _Store()
    var cluster = String("zsGC")
    var topic = String("compactT")
    var pid = Int64(0)
    _build_superseded_partition(store, cluster, topic, pid)

    # Capture chunk 0's ORIGINAL `.seg` key BEFORE compaction (the orphan).
    var manifest0 = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_prefix(cluster, topic, pid),
        retry=RetryPolicy.fast_test(),
    )
    var orig0 = ManifestBody.decode(manifest0.read_chunk(Int64(0)))
    var orphan_key = String(orig0.object_key)
    _ = manifest0^
    assert_true(
        _object_exists(store, orphan_key), "original chunk-0 `.seg` exists"
    )

    var cleaner = _make_cleaner(
        store, cluster, topic, pid, CompactionConfig.compact(Int64(86_400_000))
    )
    var res = cleaner.run_once(Int64(10_000))
    _ = cleaner^
    assert_equal(
        res.orphans_scheduled, Int64(1),
        "1 orphan scheduled (chunk 0's superseded `.seg`)",
    )
    # The original `.seg` is still present (scheduled, pre-grace).
    assert_true(
        _object_exists(store, orphan_key),
        "orphaned original `.seg` still present pre-grace",
    )

    # Reap BEFORE grace (orphan @10_000, grace 60_000, run @20_000 → not reaped).
    var reaper_early = _make_reaper(store, cluster, topic, pid, Int64(60_000))
    var r_early = reaper_early.run(Int64(20_000))
    _ = reaper_early^
    assert_equal(r_early, Int64(0), "pre-grace: 0 orphans reaped")
    assert_true(
        _object_exists(store, orphan_key),
        "pre-grace: orphan still present",
    )

    # Reap AFTER grace (run @100_000 → age 90_000 >= 60_000 → reaped).
    var reaper_late = _make_reaper(store, cluster, topic, pid, Int64(60_000))
    var r_late = reaper_late.run(Int64(100_000))
    _ = reaper_late^
    assert_equal(r_late, Int64(1), "post-grace: the chunk-0 orphan reaped")
    assert_false(
        _object_exists(store, orphan_key),
        "post-grace: orphaned original `.seg` REAPED",
    )

    # Partition still consumes correctly after the orphan GC.
    var rows = _consume_all(store, cluster, topic, pid)
    assert_equal(len(rows), 5, "partition still consumes 5 rows after orphan GC")
    _ = store^
    print("[test_zero_survivor_orphan_gc] PASS")


def main() raises:
    test_zero_survivor_chunk_compacts_to_gap()
    test_zero_survivor_rerun_is_noop()
    test_zero_survivor_orphan_gc()
    print(
        "[OK] test_broker_log_compaction_zero_survivor — 3 log-compaction"
        " zero-survivor tests passed (fully-superseded chunk → empty gap with"
        " PRESERVED offset span, idempotent re-run no-op, orphan `.seg`"
        " grace-gated GC — real Arrow-IPC `.seg`, offline)"
    )
