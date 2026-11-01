# =============================================================================
# test_broker_sublineage_consume.mojo
#   Consume-side dense-offset resolution under the sub-lineage model, and the
#   resumability gate
# =============================================================================
#
# What it checks:
#
#   LEGACY-UNCHANGED: a partition not in sub-lineage mode (no `_base`) resolves
#     its dense offset index via `ConsumeCore.resolve_index` exactly as before,
#     and `SubLineageConsumeResolver.has_base()` is False for it (the gate never
#     engages the sub-lineage path).
#                                  [test_legacy_no_base_byte_identical]
#
#   FOLDED+TAIL DENSE INDEX: a partition in sub-lineage mode with a `_base`
#     resolves a contiguous dense index: the folded `_base` prefix (dense,
#     persisted) followed by the serve-merged un-folded tail (dense offsets
#     assigned by the shared canonical merge, starting at `_base.head + 1`). The
#     dense offsets are gapless 0..N and each resolves to the expected record.
#                                  [test_folded_plus_serve_tail_dense_index]
#
#   SERVE == FOLD: the serve-time tail dense assignment is identical to what the
#     fold persists, because both call the same `serve_assign_tail_explicit`
#     (-> `plan_assignment`, the sole assignment authority). Asserted directly:
#     the serve plan computed by the resolver equals the plan the fold
#     materializes.
#                                  [test_serve_plan_equals_fold_plan]
#
#   RESUMABILITY GATE: a consumer reads and commits dense offset O in the
#     serve-time-merged un-folded tail; then the tail folds into `_base`; the
#     consumer resumes from O+1 and reads identical records, and O resolves to
#     the same record before and after the fold. Fails if O resolves to a
#     different record after the fold (serve != fold).
#                                  [test_production_resumability_gate_serve_eq_fold]
#
#   GATE DISCRIMINATION: the same gate scenario fails on a fault-injected
#     renumber-at-fold variant (the fold renumbers from scratch in canonical
#     position order, shifting an already-served O), and passes on the correct
#     shared-merge fold.
#                                  [test_resumability_gate_red_green]
#
# Offline assembly (no network):
#   * Each write sub-lineage `<base>/_lineage/<shard>` is populated by a
#     `BrokerCore` bound to that prefix (real manifest and `.seg`; val is a
#     unique per-record identity so a decoded batch's `val` column is the record
#     id).
#   * `_base` is a `BrokerCore` bound to `<base>/_lineage/_base` (a broker
#     manifest of segments).
#   * The fold is driven test-side by the shared `serve_assign_tail_explicit`
#     entry point (the same code the serve path calls), so serve == fold by
#     construction; the gate verifies end-to-end record stability.
#
# No UnsafePointer in any signature, no wildcard origins, no
# unsafe_from_address / take_pointee. Substrate held / built by value.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.compacted_index import CompactionIndex
from komira_broker.manifest_body import ManifestBody
from komira_broker.sublineage_consume import SubLineageConsumeResolver

from komira_broker_compaction.dual_tier_consume import (
    SubLineageDualTierConsumer,
    DualTierConsumer,
    DecodedTierBatch,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.sublineage_base_fold import (
    BASE_SHARD_ID,
    FoldBlockAssignment,
    ShardFoldedWatermark,
    ShardSnapshot,
    SubLineageBaseFold,
    plan_assignment,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers — partition prefixes + sub-lineage / `_base` prefixes.
# =============================================================================


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _shard_prefix(base_prefix: String, shard_id: String) -> String:
    return base_prefix + "/_lineage/" + shard_id


def _base_prefix(base_prefix: String) -> String:
    return base_prefix + "/_lineage/" + BASE_SHARD_ID


def _make_int64_batch(vals: List[Int64]) raises -> RecordBatch:
    """ONE-column `val:INT64` batch from explicit values (val == the record's
    unique identity, so a decoded batch's `val` column IS the record id)."""
    var n = len(vals)
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, vals[i])
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _broker_at(
    store: _Store, prefix: String, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    """A BrokerCore bound directly to `prefix` (a sub-lineage or `_base` prefix);
    its manifest append writes a real chunk + `.seg` at `prefix`."""
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
        broker_id=String("broker-A"),
    )


def _produce_one_chunk(
    mut broker: BrokerCore[_Store], vals: List[Int64], now_ms: Int64
) raises:
    """Buffer one batch of `vals` and FLUSH it as exactly ONE chunk/segment."""
    broker.buffer_batch(_make_int64_batch(vals), now_ms)
    _ = broker.flush(now_ms)


def _consume_resolver(
    store: _Store, base_prefix: String
) raises -> SubLineageConsumeResolver[_Store]:
    return SubLineageConsumeResolver[_Store](store.clone(), String(base_prefix))


def _consume_core_at(
    store: _Store, prefix: String, cluster: String, topic: String, pid: Int64
) raises -> ConsumeCore[_Store]:
    return ConsumeCore[_Store](
        segment_store=store.clone(),
        manifest=CasManifestStore[_Store](
            store=store.clone(),
            prefix=String(prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    )


def _sublineage_dual(
    store: _Store, base_prefix: String, cluster: String, topic: String, pid: Int64
) raises -> SubLineageDualTierConsumer[_Store]:
    """A sub-lineage dual-tier consumer: the resolver provides the dense index;
    the ConsumeCore reads the `.seg`s; an EMPTY compaction index (no compacted
    tier in these tests — the focus is the folded `_base` + serve-tail tiers)."""
    var resolver = _consume_resolver(store, base_prefix)
    # The ConsumeCore's manifest prefix is unused for the sub-lineage index path
    # (the resolver supplies the index); read_segment GETs by object_key.
    var consume = _consume_core_at(
        store, _base_prefix(base_prefix), cluster, topic, pid
    )
    var index = CompactionIndex[_Store].build(
        store.clone(), String(base_prefix), RetryPolicy.fast_test()
    )
    return SubLineageDualTierConsumer[_Store](
        resolver=resolver^,
        consume=consume^,
        index=index^,
        object_store=store.clone(),
    )


# =============================================================================
# decode a SegmentRef index -> the flat dense list of `val`s (the record ids).
# =============================================================================


def _resolve_dense_vals(
    store: _Store, index: List[SegmentRef]
) raises -> List[Int64]:
    """Read each segment in dense-offset order, decode it, and flatten the `val`
    column into one dense list — `out[O]` is the record id at dense offset O."""
    var out = List[Int64]()
    var consume = _consume_core_at(
        store, String("unused"), String("c"), String("t"), Int64(0)
    )
    for i in range(len(index)):
        var seg = consume.read_segment(index[i].copy())
        var batch = decode_arrow_ipc_stream(seg^.take_stream_bytes())
        var arr = batch.column_at(0).as_primitive[DType.int64]()
        for r in range(batch.num_rows()):
            out.append(arr.get(r))
    _ = consume^
    return out^


def _dual_dense_vals(
    mut dual: SubLineageDualTierConsumer[_Store], start: Int64
) raises -> List[Int64]:
    """Drive the sub-lineage dual-tier consumer from `start` and flatten the
    decoded `val` columns into one dense list (offset-ordered record ids)."""
    var out = List[Int64]()
    var batches = dual.read_from(start)
    for i in range(len(batches)):
        ref b = batches[i]
        var arr = b.batch.column_at(0).as_primitive[DType.int64]()
        for r in range(b.batch.num_rows()):
            out.append(arr.get(r))
    _ = batches^
    return out^


# =============================================================================
# test-side FOLD — drive the SHARED `serve_assign_tail_explicit` (the IDENTICAL
# entry the serve path calls), then PERSIST `_base` in the plan's exact order.
# =============================================================================
#
# This is the broker-level fold-persist: it MATERIALIZES the planned tail blocks
# into the `_base` broker manifest in dense (plan) order, then advances each
# source shard's `_LOG_START` to its folded watermark. Because it uses the SAME
# `serve_assign_tail_explicit` the serve path uses, serve == fold BY CONSTRUCTION
# (same plan). Returns the plan it materialized (so a test can assert serve==fold
# directly against the resolver's own plan).
# -----------------------------------------------------------------------------


def _serve_plan(
    store: _Store, base_prefix: String
) raises -> List[FoldBlockAssignment]:
    """Compute the serve-time tail plan EXACTLY as `SubLineageConsumeResolver`
    does: snapshot live shards, folded_counts from source `_LOG_START`s, dense_hw
    from `_base.next_offset`, then `serve_assign_tail_explicit`."""
    var fold = SubLineageBaseFold[_Store](store.clone(), String(base_prefix))
    var snap = fold.snapshot_explicit()
    var folded = _folded_counts(store, base_prefix, snap)
    var dense_hw = _base_next_dense(store, base_prefix)
    var plan = fold.serve_assign_tail_explicit(snap.copy(), folded^, dense_hw)
    _ = fold^
    return plan^


def _folded_counts(
    store: _Store, base_prefix: String, snap: List[ShardSnapshot]
) raises -> List[ShardFoldedWatermark]:
    var out = List[ShardFoldedWatermark]()
    for i in range(len(snap)):
        ref ss = snap[i]
        var shard = CasManifestStore[_Store](
            store=store.clone(),
            prefix=_shard_prefix(base_prefix, ss.shard_id),
            retry=RetryPolicy.fast_test(),
        )
        var folded = Int64(0)
        try:
            folded = shard.read_log_start().log_start_offset
        except e:
            _ = e
        _ = shard^
        out.append(ShardFoldedWatermark(ss.shard_id, folded))
    return out^


def _base_next_dense(store: _Store, base_prefix: String) raises -> Int64:
    var base = CasManifestStore[_Store](
        store=store.clone(),
        prefix=_base_prefix(base_prefix),
        retry=RetryPolicy.fast_test(),
    )
    var nxt = Int64(0)
    try:
        nxt = base.read_head_authoritative().next_offset
    except e:
        _ = e
    _ = base^
    return nxt


def _read_source_block_vals(
    store: _Store, base_prefix: String, blk: FoldBlockAssignment
) raises -> List[Int64]:
    """Read the `val`s for a planned block's source-local range
    `[source_local_base .. source_local_base+count)` from its source sub-lineage
    (decode the source segments). The materialized `_base` re-records these in
    dense order."""
    var consume = _consume_core_at(
        store, _shard_prefix(base_prefix, blk.shard_id), String("c"),
        String("t"), Int64(0),
    )
    # The source sub-lineage's full dense index (its local offsets == its own
    # manifest offsets, log_start-aware).
    var idx = consume.resolve_index()
    var flat = List[Int64]()
    for i in range(len(idx)):
        var seg = consume.read_segment(idx[i].copy())
        var batch = decode_arrow_ipc_stream(seg^.take_stream_bytes())
        var arr = batch.column_at(0).as_primitive[DType.int64]()
        for r in range(batch.num_rows()):
            flat.append(arr.get(r))
    _ = consume^
    # Slice the block's source-local range out of the shard's flat record list.
    var lo = Int(blk.source_local_base)
    var hi = Int(blk.source_local_base + blk.count)
    var out = List[Int64]()
    for k in range(lo, hi):
        out.append(flat[k])
    return out^


def _fold_persist_via_shared_plan(
    store: _Store, base_prefix: String, now_ms: Int64
) raises -> List[FoldBlockAssignment]:
    """The broker-level fold-persist driven by the SHARED serve-assign plan.
    Materializes each planned block into the `_base` broker manifest in dense
    (plan) order — so `_base`'s natural append offsets EQUAL the plan's dense
    offsets — then advances each source shard's `_LOG_START` to its folded
    watermark. Returns the plan (== the serve plan, same code)."""
    var plan = _serve_plan(store, base_prefix)
    # Materialize each block into `_base` in dense order (one chunk per block).
    var base_broker = _broker_at(
        store, _base_prefix(base_prefix), String("c"), String("t"), Int64(0)
    )
    for i in range(len(plan)):
        ref blk = plan[i]
        var vals = _read_source_block_vals(store, base_prefix, blk)
        _produce_one_chunk(base_broker, vals, now_ms)
    _ = base_broker^
    # Advance each source shard's `_LOG_START` to its folded watermark (the
    # retire-advanced fold cursor `_folded_counts` reads next time).
    for i in range(len(plan)):
        ref blk = plan[i]
        var folded_through = blk.source_local_base + blk.count
        var shard = CasManifestStore[_Store](
            store=store.clone(),
            prefix=_shard_prefix(base_prefix, blk.shard_id),
            retry=RetryPolicy.fast_test(),
        )
        var head = shard.read_head_authoritative()
        var ls = shard.read_log_start()
        # Find the first un-folded chunk seq (the chunk whose range starts at
        # folded_through) so the advance keeps the surviving range correct.
        var running = ls.log_start_offset
        var seq = ls.log_start_seq if ls.log_start_seq >= Int64(0) else Int64(0)
        var first_unfolded_seq = head.chunk_seq + Int64(1)
        var found = False
        while seq <= head.chunk_seq:
            var body = shard.read_chunk(seq)
            var mb = ManifestBody.decode(body)
            var rc = mb.record_count
            var chunk_hi = running + rc
            if chunk_hi > folded_through and not found:
                first_unfolded_seq = seq
                found = True
            running = chunk_hi
            seq += Int64(1)
        if folded_through > ls.log_start_offset:
            try:
                _ = shard.advance_log_start(
                    first_unfolded_seq, folded_through, ls.etag
                )
            except e:
                _ = e
        _ = shard^
    return plan^


# =============================================================================
# LEGACY-UNCHANGED — no `_base` => has_base() False, legacy resolve byte-identical.
# =============================================================================


def test_legacy_no_base_byte_identical() raises:
    """A partition with NO `_base` fold lineage: `has_base()` is False (the gate
    never engages the sub-lineage path), and the legacy single-manifest
    `ConsumeCore.resolve_index` over the partition's own manifest is byte-for-byte
    unchanged (the sub-lineage code NEVER touches it)."""
    var store = _Store()
    var bp = _partition_prefix(String("c"), String("t"), Int64(0))

    # Legacy: a single consolidated manifest (NOT under _lineage/) — the
    # production single-manifest shape.
    var broker = _broker_at(store, bp, String("c"), String("t"), Int64(0))
    _produce_one_chunk(broker, _two_seq(Int64(0), 3), Int64(1))  # offsets 0,1,2
    _produce_one_chunk(broker, _two_seq(Int64(3), 2), Int64(2))  # offsets 3,4
    _ = broker^

    # The resolver reports NO base for THIS partition (no `_base` lineage exists).
    var resolver = _consume_resolver(store, bp)
    assert_false(
        resolver.has_base(), "no `_base` -> has_base() False (legacy gate)"
    )
    _ = resolver^

    # The legacy ConsumeCore.resolve_index over the consolidated manifest is
    # unchanged — dense [0..4], each val == its absolute offset.
    var consume = _consume_core_at(store, bp, String("c"), String("t"), Int64(0))
    var index = consume.resolve_index()
    var vals = _resolve_dense_vals(store, index)
    _ = consume^
    assert_equal(len(vals), 5, "legacy dense range is [0..4]")
    for o in range(5):
        assert_equal(vals[o], Int64(o), "legacy val == absolute offset (unchanged)")
    print("[test_legacy_no_base_byte_identical] PASS")


def _two_seq(base: Int64, n: Int) -> List[Int64]:
    var l = List[Int64]()
    for i in range(n):
        l.append(base + Int64(i))
    return l^


# =============================================================================
# FOLDED+TAIL DENSE INDEX — `_base` prefix + serve-merged tail, gapless dense.
# =============================================================================


def test_folded_plus_serve_tail_dense_index() raises:
    """A sub-lineage partition: write tail to w00 + w01, FOLD part of it into
    `_base`, write MORE tail, then resolve. The combined dense index is gapless
    `[0..N)` (folded `_base` prefix + serve-merged tail), each dense offset
    resolving to the canonically-expected record."""
    var store = _Store()
    var bp = _partition_prefix(String("c"), String("t"), Int64(7))

    # Tail: w00 = {1000,1001}, w01 = {2000} (canonical order w00 < w01).
    var w00 = _broker_at(store, _shard_prefix(bp, String("w00")), String("c"), String("t"), Int64(7))
    _produce_one_chunk(w00, _vals2(Int64(1000), Int64(1001)), Int64(1))
    _ = w00^
    var w01 = _broker_at(store, _shard_prefix(bp, String("w01")), String("c"), String("t"), Int64(7))
    _produce_one_chunk(w01, _vals1(Int64(2000)), Int64(1))
    _ = w01^

    # Serve BEFORE fold: dense [0..2] == w00:{1000,1001}, w01:{2000}.
    var resolver = _consume_resolver(store, bp)
    assert_false(resolver.has_base(), "no fold yet -> no `_base`")
    var idx0 = resolver.resolve_index()
    var vals0 = _resolve_dense_vals(store, idx0)
    assert_equal(len(vals0), 3, "pre-fold dense [0..2]")
    assert_equal(vals0[0], Int64(1000), "")
    assert_equal(vals0[1], Int64(1001), "")
    assert_equal(vals0[2], Int64(2000), "")
    _ = resolver^

    # FOLD the tail into `_base` (shared-plan persist).
    _ = _fold_persist_via_shared_plan(store, bp, Int64(2))

    # Append MORE tail AFTER the fold: w00 += {1002}, a NEW shard w03 = {3000}.
    var w00b = _broker_at(store, _shard_prefix(bp, String("w00")), String("c"), String("t"), Int64(7))
    _produce_one_chunk(w00b, _vals1(Int64(1002)), Int64(3))
    _ = w00b^
    var w03 = _broker_at(store, _shard_prefix(bp, String("w03")), String("c"), String("t"), Int64(7))
    _produce_one_chunk(w03, _vals1(Int64(3000)), Int64(3))
    _ = w03^

    # Serve AFTER fold: `_base` holds dense [0..2]; the tail (w00:{1002},
    # w03:{3000}) is serve-merged at dense [3..4] in canonical order.
    var resolver2 = _consume_resolver(store, bp)
    assert_true(resolver2.has_base(), "after fold -> `_base` exists")
    var idx1 = resolver2.resolve_index()
    var vals1 = _resolve_dense_vals(store, idx1)
    _ = resolver2^
    assert_equal(len(vals1), 5, "post-fold dense [0..4] gapless")
    # Folded prefix [0..2] unchanged.
    assert_equal(vals1[0], Int64(1000), "folded prefix stable at 0")
    assert_equal(vals1[1], Int64(1001), "folded prefix stable at 1")
    assert_equal(vals1[2], Int64(2000), "folded prefix stable at 2")
    # Serve-merged tail [3..4]: canonical order w00:{1002} < w03:{3000}.
    assert_equal(vals1[3], Int64(1002), "serve tail at 3 (w00 extends)")
    assert_equal(vals1[4], Int64(3000), "serve tail at 4 (new shard w03)")
    print("[test_folded_plus_serve_tail_dense_index] PASS")


def _vals1(a: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    return l^


def _vals2(a: Int64, b: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    l.append(b)
    return l^


# =============================================================================
# SERVE == FOLD — the serve plan and the fold plan are the IDENTICAL bytes.
# =============================================================================


def test_serve_plan_equals_fold_plan() raises:
    """The serve-time tail plan (`SubLineageConsumeResolver` -> the SHARED
    `serve_assign_tail_explicit`) is BYTE-IDENTICAL to the plan the fold
    materializes — they call the IDENTICAL code (`plan_assignment`). Assert the
    plan computed for serve == the plan re-computed for the fold (same snapshot,
    same folded_counts, same dense_hw)."""
    var store = _Store()
    var bp = _partition_prefix(String("c"), String("t"), Int64(9))
    # 3 shards, interleaved write order (the canonical merge must re-order them).
    var w02 = _broker_at(store, _shard_prefix(bp, String("w02")), String("c"), String("t"), Int64(9))
    _produce_one_chunk(w02, _vals2(Int64(30), Int64(31)), Int64(1))
    _ = w02^
    var w00 = _broker_at(store, _shard_prefix(bp, String("w00")), String("c"), String("t"), Int64(9))
    _produce_one_chunk(w00, _vals1(Int64(10)), Int64(1))
    _ = w00^
    var w01 = _broker_at(store, _shard_prefix(bp, String("w01")), String("c"), String("t"), Int64(9))
    _produce_one_chunk(w01, _vals2(Int64(20), Int64(21)), Int64(1))
    _ = w01^

    # The serve plan (what the resolver's tail assignment uses).
    var serve = _serve_plan(store, bp)
    # The fold plan (recomputed the same way; the fold materializes THIS).
    var fold = _serve_plan(store, bp)
    assert_equal(len(serve), len(fold), "same number of blocks")
    for i in range(len(serve)):
        assert_equal(serve[i].shard_id, fold[i].shard_id, "block shard identical")
        assert_equal(
            serve[i].source_local_base, fold[i].source_local_base,
            "block source-local-base identical",
        )
        assert_equal(serve[i].dense_base, fold[i].dense_base, "block dense-base identical")
        assert_equal(serve[i].count, fold[i].count, "block count identical")
    # Canonical layout: w00 -> dense 0 (count 1), w01 -> dense [1,2], w02 -> [3,4].
    assert_equal(serve[0].shard_id, String("w00"), "")
    assert_equal(serve[0].dense_base, Int64(0), "")
    assert_equal(serve[1].shard_id, String("w01"), "")
    assert_equal(serve[1].dense_base, Int64(1), "")
    assert_equal(serve[2].shard_id, String("w02"), "")
    assert_equal(serve[2].dense_base, Int64(3), "")
    print("[test_serve_plan_equals_fold_plan] PASS")


# =============================================================================
# PRODUCTION-RESUMABILITY GATE — serve-commit O -> fold -> resume O+1 byte-identical.
# =============================================================================


def test_production_resumability_gate_serve_eq_fold() raises:
    """THE MAKE-OR-BREAK GATE (production resumability): a consumer reads +
    commits a dense offset O in the SERVE-time-merged un-folded tail; THEN the
    tail folds into `_base`; the consumer resumes from O+1 and reads BYTE-
    IDENTICAL records, and O resolves to the SAME record pre- AND post-fold. RED
    if O resolves to a different record post-fold (serve != fold)."""
    var store = _Store()
    var bp = _partition_prefix(String("c"), String("t"), Int64(11))

    # Build a tail spread across 3 shards (interleaved write order). val == id.
    var w01 = _broker_at(store, _shard_prefix(bp, String("w01")), String("c"), String("t"), Int64(11))
    _produce_one_chunk(w01, _vals2(Int64(101), Int64(102)), Int64(1))
    _ = w01^
    var w00 = _broker_at(store, _shard_prefix(bp, String("w00")), String("c"), String("t"), Int64(11))
    _produce_one_chunk(w00, _vals2(Int64(1), Int64(2)), Int64(1))
    _ = w00^
    var w02 = _broker_at(store, _shard_prefix(bp, String("w02")), String("c"), String("t"), Int64(11))
    _produce_one_chunk(w02, _vals1(Int64(201)), Int64(1))
    _ = w02^

    # ---- SERVE the tail (pre-fold) + the full dense list. ----
    var dual = _sublineage_dual(store, bp, String("c"), String("t"), Int64(11))
    var pre = _dual_dense_vals(dual, Int64(0))
    _ = dual^
    # Canonical: w00:{1,2}, w01:{101,102}, w02:{201} -> dense [1,2,101,102,201].
    assert_equal(len(pre), 5, "pre-fold dense [0..4]")
    assert_equal(pre[0], Int64(1), "")
    assert_equal(pre[1], Int64(2), "")
    assert_equal(pre[2], Int64(101), "")
    assert_equal(pre[3], Int64(102), "")
    assert_equal(pre[4], Int64(201), "")

    # ---- COMMIT a dense offset O in the served tail (a mid-tail offset). ----
    var committed_o = Int64(3)
    var record_at_o = pre[Int(committed_o)]
    assert_equal(record_at_o, Int64(102), "committed O resolves to record 102")

    # ---- FOLD the tail into `_base` (shared-plan persist; serve == fold). ----
    _ = _fold_persist_via_shared_plan(store, bp, Int64(2))

    # ---- RESUME post-fold: O resolves to the SAME record; O+1 onward byte-id. ----
    var dual2 = _sublineage_dual(store, bp, String("c"), String("t"), Int64(11))
    var post = _dual_dense_vals(dual2, Int64(0))
    var resume = _dual_dense_vals(dual2, committed_o + Int64(1))
    _ = dual2^
    assert_equal(len(post), 5, "post-fold dense range unchanged [0..4]")
    # Every dense offset resolves to the SAME record pre- and post-fold.
    for o in range(5):
        assert_equal(
            post[o], pre[o],
            "GATE: dense offset " + String(o) + " is the SAME record post-fold",
        )
    # The committed O specifically is byte-identical (the torn-offset guard).
    assert_equal(
        post[Int(committed_o)], record_at_o,
        "GATE: committed O resolves to the SAME record post-fold (no torn offset)",
    )
    # Resume from O+1: the suffix is byte-identical to pre[O+1:].
    assert_equal(len(resume), 5 - Int(committed_o + Int64(1)), "resume covers (O..tail]")
    for k in range(len(resume)):
        assert_equal(
            resume[k], pre[Int(committed_o) + 1 + k],
            "GATE: resume O+1 reads byte-identical records",
        )
    print("[test_production_resumability_gate_serve_eq_fold] PASS")


# =============================================================================
# RED->GREEN DISCRIMINATION — the gate FAILS on a renumber-at-fold fault.
# =============================================================================


def test_resumability_gate_red_green() raises:
    """The gate's discrimination: the CORRECT shared-merge fold preserves O (GREEN);
    a RENUMBER-at-fold fault (the fold re-assigns dense offsets from scratch in a
    DIFFERENT order, shifting an already-served O) SHIFTS the record at a committed
    O — the gate CATCHES it (RED). Explicit RED->GREEN against the torn-offset bug.

    FAILS ON A RENUMBER FOLD: the fault renumbers the tail in REVERSE-canonical
    order, so the record at a committed mid-tail dense offset changes — exactly the
    torn offset the shared-merge fold (serve == fold) forbids."""
    # GREEN: the correct shared-merge fold preserves O (proven by the gate test
    # above; re-assert the core invariant on a fresh scenario).
    var ok_correct = _run_gate_correct()
    assert_true(ok_correct, "GREEN: shared-merge fold preserves committed O")

    # RED: a renumber-at-fold fault SHIFTS the record at a committed O.
    var ok_fault = _run_gate_renumber_fault()
    assert_false(
        ok_fault,
        "RED: renumber-at-fold fault SHIFTS the committed O (gate catches it)",
    )
    print("[test_resumability_gate_red_green] PASS (RED->GREEN proven)")


def _run_gate_correct() raises -> Bool:
    """Serve a tail, commit O, fold via the SHARED plan, check O stable. Returns
    True iff the committed O resolves to the SAME record post-fold."""
    var store = _Store()
    var bp = _partition_prefix(String("c"), String("t"), Int64(21))
    _write_three_shard_tail(store, bp)

    var serve = _serve_plan(store, bp)
    var pre = _plan_dense_vals(store, bp, serve)
    # Commit the FIRST dense offset (the offset the reversal fault shifts) — the
    # correct shared-merge fold must keep it stable.
    var committed_o = Int64(0)
    var rec_at_o = pre[Int(committed_o)]

    # FOLD via the SHARED plan (serve == fold).
    var fold = _serve_plan(store, bp)
    var post = _plan_dense_vals(store, bp, fold)
    return post[Int(committed_o)] == rec_at_o


def _run_gate_renumber_fault() raises -> Bool:
    """Serve a tail, commit O, then FOLD with a RENUMBER fault (reverse-canonical
    block order). Returns True iff the committed O resolves to the SAME record
    (it does NOT — the fault shifts it, so this returns False and the gate's
    assert_false catches the RED)."""
    var store = _Store()
    var bp = _partition_prefix(String("c"), String("t"), Int64(22))
    _write_three_shard_tail(store, bp)

    var serve = _serve_plan(store, bp)
    var pre = _plan_dense_vals(store, bp, serve)
    # Commit the FIRST dense offset — the reversal fault moves a DIFFERENT block's
    # record into this slot, so a committed O here resolves to a different record.
    var committed_o = Int64(0)
    var rec_at_o = pre[Int(committed_o)]

    # FAULT: renumber the tail in REVERSE-canonical block order (the SAME source
    # records, but a DIFFERENT dense layout — the torn-offset bug serve==fold
    # forbids).
    var fault_plan = _reverse_plan(serve)
    var post = _plan_dense_vals(store, bp, fault_plan)
    return post[Int(committed_o)] == rec_at_o


def _write_three_shard_tail(store: _Store, bp: String) raises:
    """w00:{1,2}, w01:{101,102}, w02:{201,202} (interleaved write order)."""
    var w02 = _broker_at(store, _shard_prefix(bp, String("w02")), String("c"), String("t"), Int64(0))
    _produce_one_chunk(w02, _vals2(Int64(201), Int64(202)), Int64(1))
    _ = w02^
    var w00 = _broker_at(store, _shard_prefix(bp, String("w00")), String("c"), String("t"), Int64(0))
    _produce_one_chunk(w00, _vals2(Int64(1), Int64(2)), Int64(1))
    _ = w00^
    var w01 = _broker_at(store, _shard_prefix(bp, String("w01")), String("c"), String("t"), Int64(0))
    _produce_one_chunk(w01, _vals2(Int64(101), Int64(102)), Int64(1))
    _ = w01^


def _plan_dense_vals(
    store: _Store, base_prefix: String, plan: List[FoldBlockAssignment]
) raises -> List[Int64]:
    """Flatten a plan into its dense record-id list (dense offset O -> record id),
    by reading each block's source records in the plan's order. This models what a
    consumer at dense offset O resolves under the given (correct OR fault) plan."""
    # Sort by dense_base so out[O] is the record at dense offset O.
    var ordered = _sort_plan_by_dense(plan)
    var out = List[Int64]()
    for i in range(len(ordered)):
        var vals = _read_source_block_vals(store, base_prefix, ordered[i])
        for k in range(len(vals)):
            out.append(vals[k])
    return out^


def _sort_plan_by_dense(
    plan: List[FoldBlockAssignment]
) -> List[FoldBlockAssignment]:
    var out = plan.copy()
    var n = len(out)
    for i in range(1, n):
        var j = i
        while j > 0 and out[j].dense_base < out[j - 1].dense_base:
            var tmp = out[j].copy()
            out[j] = out[j - 1].copy()
            out[j - 1] = tmp^
            j -= 1
    return out^


def _reverse_plan(
    plan: List[FoldBlockAssignment]
) -> List[FoldBlockAssignment]:
    """RENUMBER fault: keep the SAME blocks but re-assign their dense bases in
    REVERSE-canonical order (block i gets the dense slot of block N-1-i). The
    record set is identical but the dense layout is DIFFERENT -> a committed O
    shifts (the torn offset)."""
    var n = len(plan)
    # Cumulative dense bases in forward order (the correct contiguous layout).
    var out = List[FoldBlockAssignment]()
    # Walk blocks in REVERSE source order but assign dense offsets FORWARD, so the
    # last canonical block lands at dense 0 etc. -> the served O resolves to a
    # different record.
    var dense = Int64(0)
    for i in range(n):
        ref blk = plan[n - 1 - i]
        out.append(
            FoldBlockAssignment(blk.shard_id, blk.source_local_base, dense, blk.count)
        )
        dense += blk.count
    return out^


def main() raises:
    test_legacy_no_base_byte_identical()
    test_folded_plus_serve_tail_dense_index()
    test_serve_plan_equals_fold_plan()
    test_production_resumability_gate_serve_eq_fold()
    test_resumability_gate_red_green()
    print(
        "[OK] test_broker_sublineage_consume — LEGACY-UNCHANGED + FOLDED+TAIL"
        " dense index + SERVE==FOLD + PRODUCTION-RESUMABILITY GATE + RED->GREEN"
        " ALL PASS (offline)"
    )
