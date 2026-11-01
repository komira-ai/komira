# =============================================================================
# test_broker_dual_tier_pushdown_offline.mojo
#   Cross-tier consume coverage (offline)
# =============================================================================
#
# Coverage for two paths in the dual-tier consume driver (`dual_tier_consume.mojo`):
#
#   (A) `DualTierConsumer.read_from_pushdown(start, predicate, projection)`,
#       the cross-tier pushdown orchestration:
#         * compacted Parquet refs -> `_read_compacted_ref_pushdown` ->
#           `decode_compacted_parquet_bytes_pushdown` (row-group zonemap prune,
#           column projection and the correctness row filter).
#         * live Arrow-IPC refs    -> `_read_live_ref_pushdown` -> decode, then
#           `_apply_consume_pushdown` (no zonemap: decode-time filter and
#           projection only).
#       `test_broker_compacted_pushdown_offline` covers the single-object leaf
#       (`decode_compacted_parquet_bytes_pushdown`), not this cross-tier driver.
#
#   (B) the read-repair fallback in `_read_from_impl` (reached via `read_from`):
#       on a live-segment not-found (the `.seg` was reaped after compaction
#       superseded it), re-resolve from `r.base_offset` with
#       `allow_repair=False` and read the now-compacted tier. A live not-found
#       has to be injected.
#
# Offline assembly (no network):
#   * Live tier: real `.seg`s produced via `BrokerCore.produce` /
#     `flush_if_buffered` into a clone-shared in-memory
#     `SharedInMemoryConditionalStore` (value == offset).
#   * Compacted tier: multi-row-group Parquet objects hand-built via
#     `write_record_batches_to_parquet_bytes(max_rows_per_rg=10)` (the seam the
#     worker's transcode PUTs, with a small row-group cap so the row groups have
#     disjoint stat ranges and pruning is observable), PUT to the same store and
#     registered via `CompactionIndex.append_compacted`. The worker itself
#     compacts into single-row-group objects, so it cannot make pruning
#     observable offline.
#   * value == offset by construction, so a `val <op> literal` predicate's
#     surviving row set is a closed-form integer set the test checks exactly.
#
# No UnsafePointer in any signature, no wildcard origins, no
# unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr, BIN_LT, BIN_GE
from komira_plan_expr.scalar_value import ScalarValue

from komira_parquet_writer.record_batch_writer import (
    write_record_batches_to_parquet_bytes,
)
from komira_parquet_api.types import CompressionCodec

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore
from komira_broker.compacted_index import CompactionIndex
from komira_broker_compaction.compaction_worker import CompactionWorker

from komira_broker_compaction.dual_tier_consume import (
    DualTierConsumer,
    DecodedTierBatch,
    DualTierPushdownResult,
    decode_compacted_parquet_bytes,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


# =============================================================================
# helpers — store / broker / consume / index / dual-tier assembly (offline).
# =============================================================================


def _partition_prefix(cluster: String, topic: String, pid: Int64) -> String:
    return cluster + "/_meta/topics/" + topic + "/" + String(pid)


def _make_broker(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> BrokerCore[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var manifest = CasManifestStore[_Store](
        store=store.clone(), prefix=prefix^, retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_Store](
        segment_store=store.clone(),
        manifest=manifest^,
        cluster=cluster,
        topic=topic,
        partition=pid,
        broker_id=String("broker-A"),
    )


def _make_index(
    store: _Store, cluster: String, topic: String, pid: Int64
) -> CompactionIndex[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    return CompactionIndex[_Store].build(
        store.clone(), prefix, RetryPolicy.fast_test()
    )


def _make_dual(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises -> DualTierConsumer[_Store]:
    var prefix = _partition_prefix(cluster, topic, pid)
    var consume = ConsumeCore[_Store](
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
    var index = CompactionIndex[_Store].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    )
    return DualTierConsumer[_Store](
        consume=consume^, index=index^, object_store=store.clone()
    )


def _make_int64_batch(base_val: Int64, n: Int) raises -> RecordBatch:
    """ONE-column `val:INT64` batch where val == base_val + i (so val == its
    absolute offset by construction across the whole topic)."""
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


def _make_two_col_batch(
    val_base: Int64, tag_base: Int64, n: Int
) raises -> RecordBatch:
    """TWO-column batch: val:INT64 (val_base + i) + tag:INT64 (tag_base + i).
    The second column lets a projection drop one and assert column parity /
    order across tiers."""
    var schema = Schema(
        names=[String("val"), String("tag")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.int64, DType.int64],
        nullables=[False, False],
    )
    var val_arr = PrimitiveArray[DType.int64].allocate(n)
    var val_p = val_arr._typed_ptr_mut()
    for i in range(n):
        val_p.store[width=1](i, val_base + Int64(i))
    var tag_arr = PrimitiveArray[DType.int64].allocate(n)
    var tag_p = tag_arr._typed_ptr_mut()
    for i in range(n):
        tag_p.store[width=1](i, tag_base + Int64(i))
    var val_col = Column.from_primitive[DType.int64](val_arr^)
    var tag_col = Column.from_primitive[DType.int64](tag_arr^)
    return RecordBatch.from_typed_columns_2(schema^, val_col^, tag_col^)


def _pred_val_lt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_LT,
        Expr.col_ref(String("val")),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _pred_val_ge(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GE,
        Expr.col_ref(String("val")),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _i64_at(rb: RecordBatch, col_idx: Int, row: Int) raises -> Int64:
    var arr = rb.column_at(col_idx).as_primitive[DType.int64]()
    return arr.get(row)


# Compacted-tier staging: build a multi-row-group Parquet object (val == offset)
# and register it in the compaction index at a chosen key.


def _stage_compacted_object_1col(
    store: _Store,
    mut index: CompactionIndex[_Store],
    key: String,
    base_offset: Int64,
    n_rgs: Int,
    rows_per_rg: Int,
    supersedes_lo: Int64,
    supersedes_hi: Int64,
) raises:
    """Build a 1-column (`val:INT64`) compacted Parquet object covering
    `[base, base + n_rgs*rows_per_rg)` with `val == absolute offset`, split into
    `n_rgs` DISJOINT-range row groups (`max_rows_per_rg=rows_per_rg`), PUT it to
    `store` at `key`, and append a `CompactedEntry` linking the key to the
    offset range. RG ranges are disjoint + sorted, so a `val <op> literal`
    predicate prunes whole row groups via the zonemap."""
    var batches = Slab[RecordBatch]()
    for rg in range(n_rgs):
        var rg_base = base_offset + Int64(rg * rows_per_rg)
        batches.append(_make_int64_batch(rg_base, rows_per_rg))
    var pbytes = write_record_batches_to_parquet_bytes(
        batches^, codec=CompressionCodec.SNAPPY, max_rows_per_rg=rows_per_rg
    )
    _ = store.put(Path.parse(key), pbytes^)
    var count = Int64(n_rgs * rows_per_rg)
    _ = index.append_compacted(
        parquet_key=key,
        base_offset=base_offset,
        last_offset=base_offset + count - Int64(1),
        record_count=count,
        supersedes_lo=supersedes_lo,
        supersedes_hi=supersedes_hi,
    )


def _stage_compacted_object_2col(
    store: _Store,
    mut index: CompactionIndex[_Store],
    key: String,
    base_offset: Int64,
    n_rgs: Int,
    rows_per_rg: Int,
    supersedes_lo: Int64,
    supersedes_hi: Int64,
) raises:
    """Like `_stage_compacted_object_1col` but with TWO columns (`val`, `tag`),
    `tag == 1000 + offset`. Used by the projection-parity test."""
    var batches = Slab[RecordBatch]()
    for rg in range(n_rgs):
        var rg_base = base_offset + Int64(rg * rows_per_rg)
        batches.append(
            _make_two_col_batch(rg_base, Int64(1000) + rg_base, rows_per_rg)
        )
    var pbytes = write_record_batches_to_parquet_bytes(
        batches^, codec=CompressionCodec.SNAPPY, max_rows_per_rg=rows_per_rg
    )
    _ = store.put(Path.parse(key), pbytes^)
    var count = Int64(n_rgs * rows_per_rg)
    _ = index.append_compacted(
        parquet_key=key,
        base_offset=base_offset,
        last_offset=base_offset + count - Int64(1),
        record_count=count,
        supersedes_lo=supersedes_lo,
        supersedes_hi=supersedes_hi,
    )


def _produce_live_segments_1col(
    mut broker: BrokerCore[_Store],
    base_offset: Int64,
    n_segments: Int,
    rows: Int,
    ts0: Int64,
) raises -> List[String]:
    """Produce `n_segments` live `.seg`s of `rows` rows each (`val==offset`)
    starting at `base_offset`. Returns the produced segment keys (for the
    read-repair test's deletion). The broker assigns absolute offsets in
    produce order, so the caller must have already compacted the
    `[0, base_offset)` prefix (or there is none) for these to land at
    `base_offset`."""
    var keys = List[String]()
    for i in range(n_segments):
        var seg_base = base_offset + Int64(i * rows)
        var rb = _make_int64_batch(seg_base, rows)
        _ = broker.produce(rb^, ts0 + Int64(i) * Int64(1000))
        var pr_opt = broker.flush_if_buffered(ts0 + Int64(i) * Int64(1000))
        if not pr_opt:
            raise Error("live flush " + String(i) + " produced nothing")
        var pr = pr_opt.value().copy()
        keys.append(String(pr.segment_key))
    return keys^


# Closed-form oracle over `val == offset`: number of offsets in [0, total) that
# survive the predicate.


def _oracle_lt(total: Int, v: Int64) -> Int:
    var c = 0
    for o in range(total):
        if Int64(o) < v:
            c += 1
    return c


def _oracle_ge(total: Int, v: Int64) -> Int:
    var c = 0
    for o in range(total):
        if Int64(o) >= v:
            c += 1
    return c


def _total_surviving_rows(res: DualTierPushdownResult) raises -> Int:
    var t = 0
    for i in range(len(res.batches)):
        t += res.batches[i].batch.num_rows()
    return t


# Topology builder used by the (A) tests. Compacted tier (2 multi-RG objects),
# then live tier (2 segments):
#   obj A: offsets  0..19  (2 RGs: 0..9, 10..19)     supersedes live chunks 0..1
#   obj B: offsets 20..39  (2 RGs: 20..29, 30..39)   supersedes live chunks 2..3
#   live : offsets 40..59  (2 segments: 40..49, 50..59)
# Total 0..59, val == offset; 4 compacted RGs.


def _build_two_tier_topology_1col(
    store: _Store, cluster: String, topic: String, pid: Int64
) raises:
    # Compacted tier: 2 objects, each 2 RGs of 10 rows.
    var index = _make_index(store, cluster, topic, pid)
    _stage_compacted_object_1col(
        store,
        index,
        key=cluster + "/compacted/obj-A-0-19.parquet",
        base_offset=Int64(0),
        n_rgs=2,
        rows_per_rg=10,
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(1),
    )
    _stage_compacted_object_1col(
        store,
        index,
        key=cluster + "/compacted/obj-B-20-39.parquet",
        base_offset=Int64(20),
        n_rgs=2,
        rows_per_rg=10,
        supersedes_lo=Int64(2),
        supersedes_hi=Int64(3),
    )
    _ = index^

    # Live tier: produce 4 live segments (offsets 0..39) so the manifest's
    # running base lands the FINAL 2 segments at offsets 40..59 — the
    # still-live suffix above the compacted boundary (40). dual_tier_resolve
    # then skips the live segments fully inside the compacted prefix.
    var broker = _make_broker(store, cluster, topic, pid)
    _ = _produce_live_segments_1col(
        broker, base_offset=Int64(0), n_segments=6, rows=10, ts0=Int64(1000)
    )


# =============================================================================
# (A) read_from_pushdown — cross-tier pushdown orchestration.
# =============================================================================


def test_A2_rowset_equivalence_straddle_both_tiers() raises:
    """(A) property 2 — ROW-SET EQUIVALENCE (the key property). A predicate
    whose matching rows straddle BOTH tiers yields the SAME logical row set as
    an oracle (the closed-form integer set under `val==offset`). The COMPACTED
    tier (RG-prune-THEN-filter) and the LIVE tier (filter-only) must agree."""
    print("[test_A2_rowset_equivalence_straddle_both_tiers] starting...")
    var store = _Store()
    var cluster = String("dtA2")
    var topic = String("t")
    var pid = Int64(0)
    _build_two_tier_topology_1col(store, cluster, topic, pid)

    # Predicate `val >= 25` straddles BOTH tiers:
    #   compacted: obj A (0..19) fully pruned; obj B RG0(20..29) survives w/
    #              rows 25..29, RG1(30..39) survives w/ all -> 25..39.
    #   live     : 40..59 all survive (filter-only).
    var dual = _make_dual(store, cluster, topic, pid)
    var pred: Optional[Expr] = _pred_val_ge(Int64(25))
    var res = dual.read_from_pushdown(
        Int64(0), pred^, Optional[List[String]](None)
    )

    # Oracle: number of offsets in [0,60) with offset >= 25  -> 35 (25..59).
    var oracle = _oracle_ge(60, Int64(25))
    assert_equal(oracle, 35, "oracle val>=25 over [0,60) is 35 rows")
    assert_equal(
        _total_surviving_rows(res),
        oracle,
        "cross-tier pushdown surviving rows == oracle (straddle both tiers)",
    )

    # The match set straddles BOTH tiers: at least one compacted survivor AND
    # at least one live survivor.
    var compacted_rows = 0
    var live_rows = 0
    for i in range(len(res.batches)):
        if res.batches[i].is_compacted:
            compacted_rows += res.batches[i].batch.num_rows()
        else:
            live_rows += res.batches[i].batch.num_rows()
    assert_true(compacted_rows > 0, "some survivors from compacted tier")
    assert_true(live_rows > 0, "some survivors from live tier")
    assert_equal(compacted_rows, 15, "compacted survivors 25..39 == 15")
    assert_equal(live_rows, 20, "live survivors 40..59 == 20")

    # Every surviving value actually satisfies the predicate (no leak across
    # the prune-then-filter compacted arm).
    for i in range(len(res.batches)):
        var nrows = res.batches[i].batch.num_rows()
        for r in range(nrows):
            assert_true(
                _i64_at(res.batches[i].batch, 0, r) >= Int64(25),
                "every surviving val >= 25",
            )
    _ = res^
    print("[test_A2_rowset_equivalence_straddle_both_tiers] PASS")


def test_A1_cross_tier_offset_ordering() raises:
    """(A) property 1 — CROSS-TIER OFFSET ORDERING. Output batches span
    `[start, tail)` in monotonic offset order, compacted refs before the live
    tail (the dual_tier_resolve contract). Verified with NO predicate so the
    full set is present (40 compacted + 20 live = 60 rows, 0..59)."""
    print("[test_A1_cross_tier_offset_ordering] starting...")
    var store = _Store()
    var cluster = String("dtA1")
    var topic = String("t")
    var pid = Int64(0)
    _build_two_tier_topology_1col(store, cluster, topic, pid)

    var dual = _make_dual(store, cluster, topic, pid)
    var res = dual.read_from_pushdown(
        Int64(0), Optional[Expr](None), Optional[List[String]](None)
    )
    # 2 compacted objects + 2 live segments = 4 batches.
    assert_equal(len(res.batches), 4, "2 compacted + 2 live batches")
    assert_true(res.batches[0].is_compacted, "batch 0 compacted")
    assert_true(res.batches[1].is_compacted, "batch 1 compacted")
    assert_false(res.batches[2].is_compacted, "batch 2 live")
    assert_false(res.batches[3].is_compacted, "batch 3 live")

    # Monotone, contiguous, no gap/dup, compacted before live.
    var expect_next = Int64(0)
    var saw_live = False
    for i in range(len(res.batches)):
        assert_equal(
            res.batches[i].base_offset,
            expect_next,
            "contiguous base at batch " + String(i),
        )
        # Once we have seen a live batch, no compacted batch may follow.
        if res.batches[i].is_compacted:
            assert_false(
                saw_live, "compacted batch must not follow a live batch"
            )
        else:
            saw_live = True
        expect_next = res.batches[i].last_offset + Int64(1)
    assert_equal(expect_next, Int64(60), "tail offset == 60")
    assert_equal(_total_surviving_rows(res), 60, "all 60 rows (no predicate)")

    # The whole-topic values are exactly 0..59 in order (val==offset).
    var next_val = Int64(0)
    for i in range(len(res.batches)):
        var nrows = res.batches[i].batch.num_rows()
        for r in range(nrows):
            assert_equal(
                _i64_at(res.batches[i].batch, 0, r),
                next_val,
                "value==offset in order",
            )
            next_val += Int64(1)
    _ = res^
    print("[test_A1_cross_tier_offset_ordering] PASS")


def test_A3_rg_pruning_accounting() raises:
    """(A) property 3 — RG-PRUNING ACCOUNTING. A selective predicate ->
    rgs_pruned > 0 AND rgs_total == rgs_pruned + rgs_decoded. An unfiltered read
    -> rgs_pruned == 0, rgs_decoded == rgs_total. The accounting AGGREGATES over
    every compacted object touched (the cross-tier summation the driver does)."""
    print("[test_A3_rg_pruning_accounting] starting...")
    var store = _Store()
    var cluster = String("dtA3")
    var topic = String("t")
    var pid = Int64(0)
    _build_two_tier_topology_1col(store, cluster, topic, pid)

    # Selective: `val >= 25` prunes obj A's 2 RGs (max 19 < 25); obj B's 2 RGs
    # survive. 4 total compacted RGs across both objects.
    var dual = _make_dual(store, cluster, topic, pid)
    var pred: Optional[Expr] = _pred_val_ge(Int64(25))
    var res = dual.read_from_pushdown(
        Int64(0), pred^, Optional[List[String]](None)
    )
    assert_equal(res.rgs_total, 4, "4 compacted RGs total across 2 objects")
    assert_equal(res.rgs_pruned, 2, "obj A's 2 RGs pruned (val>=25)")
    assert_equal(res.rgs_decoded, 2, "obj B's 2 RGs decoded")
    assert_equal(
        res.rgs_total,
        res.rgs_pruned + res.rgs_decoded,
        "accounting closes: total == pruned + decoded",
    )
    assert_true(res.rgs_pruned > 0, "selective predicate prunes some RGs")
    _ = res^

    # Unfiltered: no predicate -> nothing pruned, all 4 decoded.
    var dual2 = _make_dual(store, cluster, topic, pid)
    var res2 = dual2.read_from_pushdown(
        Int64(0), Optional[Expr](None), Optional[List[String]](None)
    )
    assert_equal(res2.rgs_total, 4, "4 RGs total (unfiltered)")
    assert_equal(res2.rgs_pruned, 0, "no predicate -> 0 pruned")
    assert_equal(res2.rgs_decoded, 4, "all 4 RGs decoded (unfiltered)")
    assert_equal(res2.rgs_decoded, res2.rgs_total, "decoded == total")
    _ = res2^
    print("[test_A3_rg_pruning_accounting] PASS")


def test_A4_projection_column_parity_across_tiers() raises:
    """(A) property 4 — PROJECTION COLUMN PARITY across tiers. A projection
    yields the SAME columns in the SAME order from the compacted (Parquet) tier
    and the live (Arrow-IPC) tier. Project `tag` only (a column-order mismatch
    Parquet-vs-Arrow-IPC is a real risk)."""
    print("[test_A4_projection_column_parity_across_tiers] starting...")
    var store = _Store()
    var cluster = String("dtA4")
    var topic = String("t")
    var pid = Int64(0)

    # Compacted tier: ONE 2-col object covering 0..19 (2 RGs).
    var index = _make_index(store, cluster, topic, pid)
    _stage_compacted_object_2col(
        store,
        index,
        key=cluster + "/compacted/obj2c-0-19.parquet",
        base_offset=Int64(0),
        n_rgs=2,
        rows_per_rg=10,
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(1),
    )
    _ = index^

    # Live tier: 2-col segments at 20..39 (produced after the compacted prefix).
    var broker = _make_broker(store, cluster, topic, pid)
    # The live manifest must contain segments covering 0..39 so the running base
    # lands the live suffix at 20..39 (compacted boundary == 20).
    var base_ts = Int64(1000)
    for i in range(4):
        var seg_base = Int64(i * 10)
        var rb = _make_two_col_batch(seg_base, Int64(1000) + seg_base, 10)
        _ = broker.produce(rb^, base_ts + Int64(i) * Int64(1000))
        _ = broker.flush_if_buffered(base_ts + Int64(i) * Int64(1000))

    # Project `tag` only, with a predicate on `val` (the predicate column is NOT
    # in the projection -> filter-before-project on BOTH tiers).
    var dual = _make_dual(store, cluster, topic, pid)
    var pred: Optional[Expr] = _pred_val_ge(Int64(5))
    var proj_cols = List[String]()
    proj_cols.append(String("tag"))
    var proj: Optional[List[String]] = proj_cols^
    var res = dual.read_from_pushdown(Int64(0), pred^, proj^)

    # EVERY batch (compacted AND live) must carry exactly ONE column named
    # `tag` at index 0 — identical column set + order across tiers.
    var saw_compacted = False
    var saw_live = False
    for i in range(len(res.batches)):
        assert_equal(
            res.batches[i].batch.num_columns(),
            1,
            "projected to 1 column at batch " + String(i),
        )
        assert_equal(
            res.batches[i].batch.schema.field_name(0),
            String("tag"),
            "projected column is `tag` at batch " + String(i),
        )
        if res.batches[i].is_compacted:
            saw_compacted = True
        else:
            saw_live = True
    assert_true(saw_compacted, "projection asserted on a compacted batch")
    assert_true(saw_live, "projection asserted on a live batch")

    # The surviving `tag` values (== 1000 + offset, offset >= 5) start at 1005.
    # Find the first surviving compacted batch and check its first tag.
    var checked_first = False
    for i in range(len(res.batches)):
        if res.batches[i].batch.num_rows() > 0 and not checked_first:
            assert_equal(
                _i64_at(res.batches[i].batch, 0, 0),
                Int64(1005),
                "first surviving tag == 1000 + 5",
            )
            checked_first = True
    _ = res^
    print("[test_A4_projection_column_parity_across_tiers] PASS")


def test_A5_per_ref_predicate_not_aliased_across_refs() raises:
    """(A) property 5: the per-ref predicate/projection copy. A multi-ref read
    must filter correctly on every ref, not just the first: the predicate must
    not be corrupted, aliased or consumed after the first ref. With 2 compacted
    objects and 2 live segments (4 refs), each ref's surviving rows
    independently satisfy the predicate and the per-tier counts are exact."""
    print("[test_A5_per_ref_predicate_not_aliased_across_refs] starting...")
    var store = _Store()
    var cluster = String("dtA5")
    var topic = String("t")
    var pid = Int64(0)
    _build_two_tier_topology_1col(store, cluster, topic, pid)

    # `val < 45` matches obj A fully (0..19), obj B fully (20..39), live seg0
    # partly (40..44), live seg1 not at all (50..59 all >= 45). The predicate is
    # exercised on all 4 refs; if it were consumed/aliased after ref 0, later
    # refs would mis-filter.
    var dual = _make_dual(store, cluster, topic, pid)
    var pred: Optional[Expr] = _pred_val_lt(Int64(45))
    var res = dual.read_from_pushdown(
        Int64(0), pred^, Optional[List[String]](None)
    )

    var oracle = _oracle_lt(60, Int64(45))
    assert_equal(oracle, 45, "oracle val<45 over [0,60) is 45 rows")
    assert_equal(
        _total_surviving_rows(res), oracle, "all-refs surviving rows == oracle"
    )

    # Per-ref correctness: EVERY surviving value < 45 on EVERY ref, and no ref
    # is silently empty when it should have survivors.
    assert_equal(len(res.batches), 4, "4 refs decoded")
    for i in range(len(res.batches)):
        var nrows = res.batches[i].batch.num_rows()
        for r in range(nrows):
            assert_true(
                _i64_at(res.batches[i].batch, 0, r) < Int64(45),
                "every surviving val < 45 on ref " + String(i),
            )
    # Ref 0 (obj A 0..19): all 20 survive. Ref 1 (obj B 20..39): all 20 survive.
    # Ref 2 (live 40..49): 5 survive (40..44). Ref 3 (live 50..59): 0 survive.
    assert_equal(res.batches[0].batch.num_rows(), 20, "obj A: 20 survive")
    assert_equal(res.batches[1].batch.num_rows(), 20, "obj B: 20 survive")
    assert_equal(res.batches[2].batch.num_rows(), 5, "live seg0: 5 survive")
    assert_equal(res.batches[3].batch.num_rows(), 0, "live seg1: 0 survive")
    _ = res^
    print("[test_A5_per_ref_predicate_not_aliased_across_refs] PASS")


def test_A6_gap_chunk_zero_row_live_segment() raises:
    """(A) property 6 (if cheap) — interaction with a GAP chunk. A 0-row live
    segment (the zero-survivor sparse `.seg` shape from commit 60528555c, here
    a pure offset gap) consumed in a cross-tier pushdown read yields the gap
    correctly: it contributes 0 rows and does NOT corrupt the predicate flow
    for the surrounding refs."""
    print("[test_A6_gap_chunk_zero_row_live_segment] starting...")
    var store = _Store()
    var cluster = String("dtA6")
    var topic = String("t")
    var pid = Int64(0)

    # Compacted object 0..19 (2 RGs). Then produce a NORMAL live segment 20..29,
    # a ZERO-ROW gap segment (offset 30, advancing the manifest base by 0 rows),
    # and another normal segment 30..39.
    var index = _make_index(store, cluster, topic, pid)
    _stage_compacted_object_1col(
        store,
        index,
        key=cluster + "/compacted/obj-0-19.parquet",
        base_offset=Int64(0),
        n_rgs=2,
        rows_per_rg=10,
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(1),
    )
    _ = index^

    var broker = _make_broker(store, cluster, topic, pid)
    var base_ts = Int64(1000)
    # 2 live segments before the boundary (so 0..19 are superseded by compacted).
    for i in range(2):
        var seg_base = Int64(i * 10)
        var rb = _make_int64_batch(seg_base, 10)
        _ = broker.produce(rb^, base_ts + Int64(i) * Int64(1000))
        _ = broker.flush_if_buffered(base_ts + Int64(i) * Int64(1000))
    # A normal live segment 20..29.
    var rb2 = _make_int64_batch(Int64(20), 10)
    _ = broker.produce(rb2^, base_ts + Int64(3000))
    _ = broker.flush_if_buffered(base_ts + Int64(3000))
    # A ZERO-ROW gap segment (0 rows) — produce an empty batch + flush.
    var empty = _make_int64_batch(Int64(30), 0)
    _ = broker.produce(empty^, base_ts + Int64(4000))
    _ = broker.flush_if_buffered(base_ts + Int64(4000))
    # A normal live segment 30..39 (offsets continue past the 0-row gap).
    var rb3 = _make_int64_batch(Int64(30), 10)
    _ = broker.produce(rb3^, base_ts + Int64(5000))
    _ = broker.flush_if_buffered(base_ts + Int64(5000))

    var dual = _make_dual(store, cluster, topic, pid)
    # No predicate: full range. The 0-row segment contributes 0 rows; total is
    # 40 (compacted 0..19 + live 20..29 + 0-row + 30..39).
    var res = dual.read_from_pushdown(
        Int64(0), Optional[Expr](None), Optional[List[String]](None)
    )
    assert_equal(_total_surviving_rows(res), 40, "40 rows incl. 0-row gap seg")

    # With a predicate `val >= 25` spanning the gap region: 25..39 survive (15).
    var dual2 = _make_dual(store, cluster, topic, pid)
    var pred: Optional[Expr] = _pred_val_ge(Int64(25))
    var res2 = dual2.read_from_pushdown(
        Int64(0), pred^, Optional[List[String]](None)
    )
    assert_equal(
        _total_surviving_rows(res2), 15, "25..39 survive across the gap"
    )
    for i in range(len(res2.batches)):
        var nrows = res2.batches[i].batch.num_rows()
        for r in range(nrows):
            assert_true(
                _i64_at(res2.batches[i].batch, 0, r) >= Int64(25),
                "every surviving val >= 25 across gap",
            )
    _ = res^
    _ = res2^
    print("[test_A6_gap_chunk_zero_row_live_segment] PASS")


# =============================================================================
# (B) read-repair fallback in `_read_from_impl` (reached via `read_from`).
#
# The recovery path (a live-segment not-found re-resolves to the compacted tier
# and succeeds) is a concurrency scenario that a single-threaded static store
# cannot reproduce: it needs `ConsumeCore.resolve_index()` to differ between the
# outer resolve and the re-resolve (a slow reader resolves before compaction,
# then a concurrent compaction advances `log_start` and reaps the `.seg`). In a
# static store both resolves see the same state:
#   * If `log_start` has advanced past the superseded chunk (the post-compaction
#     steady state), the live index never lists the reaped segment, so the range
#     goes straight to the compacted tier and read-repair is not entered (B2).
#   * If `log_start` has not advanced, the live ref is resolved on both passes,
#     so the re-resolve fails again and the bounded single-attempt guard raises
#     (B1 and B3: the repair branch is reached and bounded).
# =============================================================================


def test_B1_read_repair_branch_reached_and_bounded() raises:
    """(B) The read-repair branch is reached on a live-segment 404 and is
    bounded (single attempt, no infinite loop). A live `.seg` is deleted while
    the live manifest still lists it (log_start not advanced) and the compacted
    tier does not cover the range: the resolve routes the range to live, the GET
    404s, read-repair re-resolves from the ref's base (allow_repair=False),
    re-404s, and the 404 propagates once."""
    print("[test_B1_read_repair_branch_reached_and_bounded] starting...")
    var store = _Store()
    var cluster = String("dtB1")
    var topic = String("t")
    var pid = Int64(0)

    # 4 live segments (0..39). NO compaction (log_start at 0; all live).
    var broker = _make_broker(store, cluster, topic, pid)
    var live_keys = _produce_live_segments_1col(
        broker, base_offset=Int64(0), n_segments=4, rows=10, ts0=Int64(1000)
    )
    assert_equal(len(live_keys), 4, "4 live segments produced (0..39)")

    # Compacted tier covers ONLY [0,9] (one entry). [10,39] stays live. So a
    # read_from(0) routes [0,9] -> compacted and [10,39] -> live refs. Deleting
    # the live .seg covering [10,19] makes that live ref 404 -> read-repair fires
    # -> re-resolve from base 10 routes [10,19] to live AGAIN (compacted does not
    # cover it) -> re-404 -> propagate (single attempt).
    var index = _make_index(store, cluster, topic, pid)
    _stage_compacted_object_1col(
        store,
        index,
        key=cluster + "/compacted/obj-0-9.parquet",
        base_offset=Int64(0),
        n_rgs=1,
        rows_per_rg=10,
        supersedes_lo=Int64(0),
        supersedes_hi=Int64(0),
    )
    _ = index^

    # Sanity BEFORE the delete: read_from(0) succeeds, and [10,19] IS served by a
    # LIVE ref (proving the resolve genuinely routes to the live tier — so the
    # subsequent delete actually exercises the read-repair branch, not a
    # compacted-only path).
    var dual0 = _make_dual(store, cluster, topic, pid)
    var b0 = dual0.read_from(Int64(0))
    var saw_live_10_19 = False
    var total0 = 0
    for i in range(len(b0)):
        total0 += b0[i].batch.num_rows()
        if (
            (not b0[i].is_compacted)
            and b0[i].base_offset == Int64(10)
            and b0[i].last_offset == Int64(19)
        ):
            saw_live_10_19 = True
    assert_equal(total0, 40, "pre-delete: full 0..39 readable")
    assert_true(
        saw_live_10_19, "[10,19] is served by a LIVE ref (repair branch is live)"
    )
    _ = b0^

    # Delete the live .seg covering [10,19] -> its GET 404s -> read-repair fires.
    store.delete(Path.parse(live_keys[1]))

    var dual = _make_dual(store, cluster, topic, pid)
    var raised = False
    try:
        var b = dual.read_from(Int64(0))
        _ = b^
    except e:
        # The read-repair branch was REACHED (a live 404), re-resolved once, and
        # could not recover offline -> the 404 propagates a SINGLE time (the
        # `allow_repair=False` guard prevents an infinite re-repair loop).
        if (
            String(e).find("not_found") >= 0
            or String(e).find("404") >= 0
            or String(e).find("NotFound") >= 0
            or String(e).find("NoSuchKey") >= 0
        ):
            raised = True
        else:
            raise e^
    assert_true(
        raised,
        "read-repair reached the live 404 and surfaced it once (bounded)",
    )
    _ = live_keys^
    print("[test_B1_read_repair_branch_reached_and_bounded] PASS")


def test_B2_post_compaction_reaped_seg_served_from_compacted() raises:
    """(B) — the POST-COMPACTION steady state (the read-repair design's PRIMARY
    race-avoidance: the grace window + log_start advance). After
    `CompactionWorker.run_once` compacts + supersedes + ADVANCES log_start, and
    the superseded live `.seg` is REAPED (deleted), a `read_from` returns the
    FULL range ENTIRELY from the compacted tier — the deleted live `.seg` is
    never touched (the live index no longer lists it). This is the dual-tier
    consume's robustness to reaped live segments WITHOUT needing read-repair —
    the steady state the read-repair fallback exists to backstop only on the
    residual concurrency race."""
    print("[test_B2_post_compaction_reaped_seg_served_from_compacted]"
          " starting...")
    var store = _Store()
    var cluster = String("dtB2")
    var topic = String("t")
    var pid = Int64(0)
    var prefix = _partition_prefix(cluster, topic, pid)

    # Produce 4 live segments (0..39) + capture the .seg keys.
    var broker = _make_broker(store, cluster, topic, pid)
    var live_keys = _produce_live_segments_1col(
        broker, base_offset=Int64(0), n_segments=4, rows=10, ts0=Int64(1000)
    )
    assert_equal(len(live_keys), 4, "4 live segments produced (0..39)")

    # Real compaction round: PUT Parquet + append compacted entry + tombstone
    # superseded live chunks + ADVANCE log_start (the genuine worker path).
    var worker = CompactionWorker[_Store](
        consume=ConsumeCore[_Store](
            segment_store=store.clone(),
            manifest=CasManifestStore[_Store](
                store=store.clone(),
                prefix=String(prefix),
                retry=RetryPolicy.fast_test(),
            ),
            cluster=cluster,
            topic=topic,
            partition=pid,
        ),
        index=CompactionIndex[_Store].build(
            store.clone(), String(prefix), RetryPolicy.fast_test()
        ),
        segment_store=store.clone(),
        live_manifest=CasManifestStore[_Store](
            store=store.clone(),
            prefix=String(prefix),
            retry=RetryPolicy.fast_test(),
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    )
    var res = worker.run_once(
        now_ms=Int64(100000), min_segments=Int64(2), max_segments=Int64(64)
    )
    assert_true(res.compacted, "a compaction round was published")
    assert_equal(res.last_offset, Int64(39), "compacted [0,39]")

    # REAP: delete ALL the superseded live .seg objects (post-grace reap).
    for i in range(len(live_keys)):
        store.delete(Path.parse(live_keys[i]))

    # read_from(0) MUST NOT raise: the live index no longer lists the reaped
    # chunks (log_start advanced), so the resolve routes the whole range to the
    # compacted tier. NONE of the deleted .seg objects are touched.
    var dual = _make_dual(store, cluster, topic, pid)
    var b = dual.read_from(Int64(0))
    var total = 0
    var expect_next = Int64(0)
    for i in range(len(b)):
        assert_true(b[i].is_compacted, "served from compacted tier (reaped live)")
        assert_equal(
            b[i].base_offset, expect_next, "contiguous at batch " + String(i)
        )
        var nrows = b[i].batch.num_rows()
        for r in range(nrows):
            assert_equal(
                _i64_at(b[i].batch, 0, r),
                expect_next + Int64(r),
                "value==offset from compacted",
            )
        total += nrows
        expect_next = b[i].last_offset + Int64(1)
    assert_equal(total, 40, "full 0..39 served after reap")
    assert_equal(expect_next, Int64(40), "tail == 40")
    _ = b^
    _ = live_keys^
    print("[test_B2_post_compaction_reaped_seg_served_from_compacted] PASS")


def test_B3_unrepairable_404_raises_no_infinite_loop() raises:
    """(B) — the SINGLE-ATTEMPT guard, isolated. A live `.seg` 404 in a range
    that is in NEITHER tier (no compacted coverage, log_start not advanced) must
    RAISE after exactly ONE repair attempt (`allow_repair=False` on the
    re-resolve) — never an infinite repair loop."""
    print("[test_B3_unrepairable_404_raises_no_infinite_loop] starting...")
    var store = _Store()
    var cluster = String("dtB3")
    var topic = String("t")
    var pid = Int64(0)

    var broker = _make_broker(store, cluster, topic, pid)
    var live_keys = _produce_live_segments_1col(
        broker, base_offset=Int64(0), n_segments=3, rows=10, ts0=Int64(1000)
    )
    assert_equal(len(live_keys), 3, "3 live segments (0..29)")
    # NO compacted tier at all. Delete the FIRST live .seg [0,9] -> read_from(0)
    # routes [0,9] to live -> 404 -> repair re-resolves from base 0 -> still
    # live (no compacted) -> re-404 -> propagate once.
    store.delete(Path.parse(live_keys[0]))

    var dual = _make_dual(store, cluster, topic, pid)
    var raised = False
    try:
        var b = dual.read_from(Int64(0))
        _ = b^
    except e:
        if (
            String(e).find("not_found") >= 0
            or String(e).find("404") >= 0
            or String(e).find("NotFound") >= 0
            or String(e).find("NoSuchKey") >= 0
        ):
            raised = True
        else:
            raise e^
    assert_true(
        raised,
        "an unrepairable 404 raises once (single-attempt guard, no loop)",
    )
    _ = live_keys^
    print("[test_B3_unrepairable_404_raises_no_infinite_loop] PASS")


def main() raises:
    # (A) read_from_pushdown — cross-tier pushdown orchestration.
    test_A1_cross_tier_offset_ordering()
    test_A2_rowset_equivalence_straddle_both_tiers()
    test_A3_rg_pruning_accounting()
    test_A4_projection_column_parity_across_tiers()
    test_A5_per_ref_predicate_not_aliased_across_refs()
    test_A6_gap_chunk_zero_row_live_segment()
    # (B) read-repair fallback + post-compaction reaped-segment robustness.
    test_B1_read_repair_branch_reached_and_bounded()
    test_B2_post_compaction_reaped_seg_served_from_compacted()
    test_B3_unrepairable_404_raises_no_infinite_loop()
    print("ALL test_broker_dual_tier_pushdown_offline PASS")
