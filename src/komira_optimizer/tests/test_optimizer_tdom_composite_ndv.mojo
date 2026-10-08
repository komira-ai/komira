# =============================================================================
# Tests for composite-key NDV tracking + pair-bucket builder
# (src/komira_optimizer/optimizer_tdom.mojo)
# =============================================================================
#
# Acceptance tests. Validates that
#   * `build_pair_buckets` correctly groups single-key bridging edges by
#     unordered relation-pair endpoints; multi-key composite edges are
#     skipped.
#   * `composite_ndv_for_relation` computes
#         min(prod_i(single_col_NDV_i_for_rel), |rel|)
#     across the bucket's bridging edges for the requested side.
#   * `composite_ndv_pk_side` returns the PK-qualified side
#     (composite_NDV == |rel|) when exactly one side qualifies,
#     -1 when neither qualifies, -2 when both qualify.
#
# The cost model (`optimizer_tdom_cost.mojo`) and the cardinality model
# (`optimizer_tdom_card.mojo`) consume these signals to gate the FK-PK clamp
# `est = min(est, max(|L|, |R|))`.
#
# Test cases:
#   1. Standalone PK detection — a 2-relation single-key join where one
#      side has NDV equal to its cardinality (PK signal).
#   2. Composite-edge against partsupp-shape (Q9 mirror) — 2-column
#      composite `(l_partkey,l_suppkey)=(ps_partkey,ps_suppkey)`;
#      partsupp's composite_NDV == |partsupp| (PK); lineitem's NDV
#      product saturates much above |lineitem| but is clamped, so the
#      heuristic also flags lineitem as PK — exercising the "both
#      qualify → -2" branch of `composite_ndv_pk_side`.
#   3. Multi-set composite NOT PK — synthetic 2-column composite where
#      neither side's single-col-NDV product reaches its cardinality.
#   4. 3-column composite — verifies that the product extends across
#      arity > 2 buckets and saturates correctly.
#   5. `build_pair_buckets` correctness — mixed per-column + composite
#      input; verifies grouping, ordering, and multi-key edge skip.
#   6. Defensive `composite_ndv_for_relation` — invalid rel_id returns 1.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_reorder import (
    JoinRelation,
    JoinEdge,
    JoinChain,
)
from komira_optimizer.optimizer_column_stats_provider import (
    ColumnStatsValue,
    DefaultColumnStatsProvider,
    SyntheticColumnStatsProvider,
    TIER_PARQUET_METADATA,
    TIER_ROW_COUNT_HEURISTIC,
)
from komira_optimizer.optimizer_tdom import (
    PairBucket,
    build_pair_buckets,
    composite_ndv_for_relation,
    composite_ndv_pk_side,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Helpers
# =============================================================================


def _single_int_schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan(path: String, key: String, n: Int) -> LogicalPlan:
    var s = _single_int_schema(key)
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, s^, none_proj^, none_filt^, rc^
    )


def _make_relation(
    id: Int, key: String, cardinality: Int
) -> JoinRelation:
    var plan = _scan("r" + String(id) + ".parquet", key, cardinality)
    var ns: Optional[TableStats] = None
    return JoinRelation(id, plan^, cardinality, ns^)


def _mk_edge(lr: Int, rr: Int, lk: String, rk: String) -> JoinEdge:
    """Single-key per-column edge."""
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return JoinEdge(lr, rr, lks^, rks^)


def _mk_edge_composite(
    lr: Int,
    rr: Int,
    lk1: String,
    lk2: String,
    rk1: String,
    rk2: String,
) -> JoinEdge:
    """Multi-key composite (leftover-fallback shape)."""
    var lks = List[String]()
    lks.append(lk1)
    lks.append(lk2)
    var rks = List[String]()
    rks.append(rk1)
    rks.append(rk2)
    return JoinEdge(lr, rr, lks^, rks^)


# =============================================================================
# 1. Standalone PK detection — single-key edge, PK side identified
# =============================================================================


def test_standalone_pk_detection_single_key() raises:
    """A 2-relation single-key join where rel 0 has NDV(col)=100 and
    |rel 0|=100. Bucket size=1; composite NDV[rel 0] = min(100, 100) = 100
    == |rel 0| → PK side. rel 1 has NDV(col)=50 and |rel 1|=200, so
    composite NDV[rel 1] = min(50, 200) = 50 != 200 — not PK.

    `composite_ndv_pk_side` must return rel 0 = 0.
    """
    var chain = JoinChain()
    chain.relations.append(_make_relation(0, "x", 100))
    chain.relations.append(_make_relation(1, "y", 200))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var provider = SyntheticColumnStatsProvider()
    provider.inject(0, "x", 100, True, TIER_PARQUET_METADATA)
    provider.inject(1, "y", 50, True, TIER_PARQUET_METADATA)

    var buckets = build_pair_buckets(chain)
    assert_equal(len(buckets), 1, "one bucket for one edge")
    assert_equal(buckets[0].rel_a, 0)
    assert_equal(buckets[0].rel_b, 1)
    assert_equal(buckets[0].size(), 1)

    var ndv_0 = composite_ndv_for_relation(chain, buckets[0], 0, provider)
    var ndv_1 = composite_ndv_for_relation(chain, buckets[0], 1, provider)
    assert_equal(ndv_0, 100, "rel 0: min(100, 100) = 100 (PK on x)")
    assert_equal(ndv_1, 50, "rel 1: min(50, 200) = 50 (not PK on y)")

    var pk_side = composite_ndv_pk_side(chain, buckets[0], provider)
    assert_equal(pk_side, 0, "rel 0 is the PK side")


# =============================================================================
# 2. Composite-edge against partsupp-shape (Q9 mirror)
# =============================================================================


def test_composite_edge_partsupp_shape() raises:
    """Q9-shape: lineitem (6M) ⋈ partsupp (800K) on composite
    (l_partkey, l_suppkey) = (ps_partkey, ps_suppkey).

    The per-column split lowers this to TWO single-column edges in
    the same (lineitem, partsupp) bucket:
      e0: lineitem.l_partkey = partsupp.ps_partkey   (NDV: 200K, 200K)
      e1: lineitem.l_suppkey = partsupp.ps_suppkey   (NDV: 10K,  10K)

    Composite NDV per side:
      partsupp: min(200K * 10K, 800K)   = min(2e9, 800K)  = 800K
                → == |partsupp|   → PK side (true; partsupp IS the
                                              (partkey, suppkey) PK
                                              table by construction)
      lineitem: min(200K * 10K, 6M)     = min(2e9, 6M)    = 6M
                → == |lineitem|   → ALSO flagged PK by the heuristic

    The heuristic over-detects lineitem (every distinct (l_partkey,
    l_suppkey) tuple in TPC-H lineitem is a partsupp key, so there are at
    most 800K, not 6M — l_partkey and l_suppkey are NOT independent, but the
    independence-product clamps at |rel| which equals the row count).
    `composite_ndv_pk_side` returns -2 (ambiguous / both qualify) in
    this case — the clamp owns what -2 means
    (`optimizer_tdom_cost._bucket_has_fkpk_signal` clamps when either side
    is Tier-1 backed).

    This test pins the EXACT Q9 numbers
    (SF1 fixtures).
    """
    var R_LINEITEM = 0
    var R_PARTSUPP = 1
    var SF1_LINEITEM = 6_001_215
    var SF1_PARTSUPP = 800_000

    var chain = JoinChain()
    chain.relations.append(
        _make_relation(R_LINEITEM, "l_partkey", SF1_LINEITEM)
    )
    chain.relations.append(
        _make_relation(R_PARTSUPP, "ps_partkey", SF1_PARTSUPP)
    )
    # Per-column split: TWO edges in the same (lineitem, partsupp) bucket.
    chain.edges.append(
        _mk_edge(R_LINEITEM, R_PARTSUPP, "l_partkey", "ps_partkey")
    )
    chain.edges.append(
        _mk_edge(R_LINEITEM, R_PARTSUPP, "l_suppkey", "ps_suppkey")
    )

    # SF1 single-col NDVs (DuckDB sources).
    var provider = SyntheticColumnStatsProvider()
    provider.inject(R_LINEITEM, "l_partkey", 200_000, True,
                    TIER_PARQUET_METADATA)
    provider.inject(R_LINEITEM, "l_suppkey", 10_000, True,
                    TIER_PARQUET_METADATA)
    provider.inject(R_PARTSUPP, "ps_partkey", 200_000, True,
                    TIER_PARQUET_METADATA)
    provider.inject(R_PARTSUPP, "ps_suppkey", 10_000, True,
                    TIER_PARQUET_METADATA)

    var buckets = build_pair_buckets(chain)
    assert_equal(len(buckets), 1,
                 "one bucket — both edges share endpoints")
    assert_equal(buckets[0].size(), 2,
                 "bucket holds 2 bridging edges (the composite)")
    assert_equal(buckets[0].rel_a, R_LINEITEM)
    assert_equal(buckets[0].rel_b, R_PARTSUPP)

    var ndv_ps = composite_ndv_for_relation(
        chain, buckets[0], R_PARTSUPP, provider
    )
    var ndv_l = composite_ndv_for_relation(
        chain, buckets[0], R_LINEITEM, provider
    )

    # partsupp: min(200K * 10K = 2e9, 800K) = 800K == |partsupp| → PK.
    assert_equal(ndv_ps, SF1_PARTSUPP,
                 "partsupp composite NDV clamps to |partsupp| (PK)")
    # lineitem: min(200K * 10K = 2e9, 6M) = 6M == |lineitem| → over-
    # detected PK by the independence heuristic.
    assert_equal(ndv_l, SF1_LINEITEM,
                 "lineitem composite NDV clamps to |lineitem|")

    # Both sides qualify → ambiguous (returns -2). The clamp owns the
    # tie-break.
    var pk = composite_ndv_pk_side(chain, buckets[0], provider)
    assert_equal(pk, -2,
                 "both partsupp and lineitem qualify; the clamp owns the tie-break")


# =============================================================================
# 3. Multi-set composite NOT PK — neither side reaches |rel|
# =============================================================================


def test_multi_set_composite_not_pk() raises:
    """A 2-column composite where the single-col-NDV product on EACH
    side is much smaller than the relation's cardinality. Neither
    side qualifies as PK.

    Setup:
      rel 0: |rel|=1000, col x: NDV=5, col y: NDV=4  → product = 20
                                                       < 1000 → not PK
      rel 1: |rel|=1000, col p: NDV=5, col q: NDV=4  → product = 20
                                                       < 1000 → not PK
      bucket: 2 edges (x=p, y=q)

    Verifies that:
      * `composite_ndv_for_relation` returns the PRODUCT (not the cap)
        when product < |rel|.
      * `composite_ndv_pk_side` returns -1 (no PK side).
    """
    var chain = JoinChain()
    chain.relations.append(_make_relation(0, "x", 1000))
    chain.relations.append(_make_relation(1, "p", 1000))
    chain.edges.append(_mk_edge(0, 1, "x", "p"))
    chain.edges.append(_mk_edge(0, 1, "y", "q"))

    var provider = SyntheticColumnStatsProvider()
    provider.inject(0, "x", 5, True, TIER_PARQUET_METADATA)
    provider.inject(0, "y", 4, True, TIER_PARQUET_METADATA)
    provider.inject(1, "p", 5, True, TIER_PARQUET_METADATA)
    provider.inject(1, "q", 4, True, TIER_PARQUET_METADATA)

    var buckets = build_pair_buckets(chain)
    assert_equal(len(buckets), 1)
    assert_equal(buckets[0].size(), 2)

    var ndv_0 = composite_ndv_for_relation(chain, buckets[0], 0, provider)
    var ndv_1 = composite_ndv_for_relation(chain, buckets[0], 1, provider)
    assert_equal(ndv_0, 20, "rel 0: 5 * 4 = 20 < 1000 (not PK)")
    assert_equal(ndv_1, 20, "rel 1: 5 * 4 = 20 < 1000 (not PK)")

    var pk = composite_ndv_pk_side(chain, buckets[0], provider)
    assert_equal(pk, -1, "neither side qualifies as PK")


# =============================================================================
# 4. Higher-arity (3-column) composite
# =============================================================================


def test_three_column_composite() raises:
    """Verifies that composite NDV extends correctly to 3-column
    composites — higher-arity composites are
    valid and the clamp must handle them.

    Setup: rel 0 has 3 columns participating in a 3-edge composite
    against rel 1.
      rel 0: |rel|=1000, col x: NDV=10, col y: NDV=10, col z: NDV=10
                                               product = 1000 == |rel 0| → PK
      rel 1: |rel|=2000, col p: NDV=10, col q: NDV=10, col r: NDV=10
                                               product = 1000 < 2000 → not PK
    """
    var chain = JoinChain()
    chain.relations.append(_make_relation(0, "x", 1000))
    chain.relations.append(_make_relation(1, "p", 2000))
    chain.edges.append(_mk_edge(0, 1, "x", "p"))
    chain.edges.append(_mk_edge(0, 1, "y", "q"))
    chain.edges.append(_mk_edge(0, 1, "z", "r"))

    var provider = SyntheticColumnStatsProvider()
    provider.inject(0, "x", 10, True, TIER_PARQUET_METADATA)
    provider.inject(0, "y", 10, True, TIER_PARQUET_METADATA)
    provider.inject(0, "z", 10, True, TIER_PARQUET_METADATA)
    provider.inject(1, "p", 10, True, TIER_PARQUET_METADATA)
    provider.inject(1, "q", 10, True, TIER_PARQUET_METADATA)
    provider.inject(1, "r", 10, True, TIER_PARQUET_METADATA)

    var buckets = build_pair_buckets(chain)
    assert_equal(len(buckets), 1)
    assert_equal(buckets[0].size(), 3, "3-edge bucket for 3-col composite")

    var ndv_0 = composite_ndv_for_relation(chain, buckets[0], 0, provider)
    var ndv_1 = composite_ndv_for_relation(chain, buckets[0], 1, provider)
    assert_equal(ndv_0, 1000, "rel 0: 10*10*10 = 1000 == |rel 0| (PK)")
    assert_equal(ndv_1, 1000, "rel 1: 10*10*10 = 1000 < 2000 (not PK)")

    var pk = composite_ndv_pk_side(chain, buckets[0], provider)
    assert_equal(pk, 0, "rel 0 is the unique PK side")


# =============================================================================
# 5. build_pair_buckets — grouping, ordering, and multi-key edge skip
# =============================================================================


def test_build_pair_buckets_groups_and_skips_composites() raises:
    """Mixed input: per-column edges across multiple relation pairs
    PLUS one multi-key composite (leftover-fallback shape).

    Edges (insertion order):
      e0: 0 ⋈ 1 on (x=p)         per-column → bucket (0,1)
      e1: 2 ⋈ 3 on (a=b)         per-column → bucket (2,3)
      e2: 0 ⋈ 1 on (y=q)         per-column → extends bucket (0,1)
      e3: 4 ⋈ 5 on (m,n)=(c,d)   multi-key composite → SKIPPED
      e4: 1 ⋈ 0 on (z=r)         per-column reversed → extends (0,1)
                                  (canonical key is (min,max)=(0,1))

    Expected output:
      bucket 0: (0, 1) with edge_indices = [0, 2, 4]   # insertion order
      bucket 1: (2, 3) with edge_indices = [1]
      multi-key e3 is dropped (build_pair_buckets handles only single-key).
    """
    var chain = JoinChain()
    for i in range(6):
        chain.relations.append(_make_relation(i, "k", 100))
    chain.edges.append(_mk_edge(0, 1, "x", "p"))                    # e0
    chain.edges.append(_mk_edge(2, 3, "a", "b"))                    # e1
    chain.edges.append(_mk_edge(0, 1, "y", "q"))                    # e2
    chain.edges.append(
        _mk_edge_composite(4, 5, "m", "n", "c", "d")
    )                                                                # e3
    chain.edges.append(_mk_edge(1, 0, "z", "r"))                    # e4

    var buckets = build_pair_buckets(chain)
    assert_equal(len(buckets), 2,
                 "two buckets (0,1) + (2,3); composite e3 skipped")

    assert_equal(buckets[0].rel_a, 0, "bucket 0 = (0, 1) canonical")
    assert_equal(buckets[0].rel_b, 1)
    assert_equal(buckets[0].size(), 3, "(0,1) bucket has 3 single-key edges")
    assert_equal(buckets[0].edge_indices[0], 0)
    assert_equal(buckets[0].edge_indices[1], 2)
    assert_equal(buckets[0].edge_indices[2], 4)

    assert_equal(buckets[1].rel_a, 2)
    assert_equal(buckets[1].rel_b, 3)
    assert_equal(buckets[1].size(), 1)
    assert_equal(buckets[1].edge_indices[0], 1)

    # Defensive: composite_ndv on a single-key bucket member.
    var provider = SyntheticColumnStatsProvider()
    provider.inject(2, "a", 50, True, TIER_PARQUET_METADATA)
    var ndv = composite_ndv_for_relation(chain, buckets[1], 2, provider)
    assert_equal(ndv, 50, "single-key bucket: NDV = single-col NDV = 50")


# =============================================================================
# 6. Defensive — invalid rel_id returns 1
# =============================================================================


def test_composite_ndv_defensive_paths() raises:
    """`composite_ndv_for_relation` is defensive against out-of-range
    or non-participating rel_id queries — returns the cost-model
    identity (1) so the clamp path can call it without
    bounds-checking.
    """
    var chain = JoinChain()
    chain.relations.append(_make_relation(0, "x", 100))
    chain.relations.append(_make_relation(1, "y", 200))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var provider = SyntheticColumnStatsProvider()
    provider.inject(0, "x", 50, True, TIER_PARQUET_METADATA)
    provider.inject(1, "y", 50, True, TIER_PARQUET_METADATA)

    var buckets = build_pair_buckets(chain)
    assert_equal(len(buckets), 1)

    # rel_id not in bucket → return 1.
    var ndv_missing = composite_ndv_for_relation(
        chain, buckets[0], 99, provider
    )
    assert_equal(ndv_missing, 1, "rel_id not in bucket → 1")

    # Negative rel_id → 1.
    var ndv_neg = composite_ndv_for_relation(
        chain, buckets[0], -1, provider
    )
    assert_equal(ndv_neg, 1, "negative rel_id → 1")


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
