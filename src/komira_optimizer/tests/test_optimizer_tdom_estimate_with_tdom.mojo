# =============================================================================
# Tests for estimate_with_tdom + edge_bridges + has_classes_for
# (src/komira_optimizer/optimizer_tdom_cost.mojo)
# =============================================================================
#
# Acceptance tests for the TDOM pair cost. Validates that
# `estimate_with_tdom` produces the equivalence-set denominator that
# DuckDB's `GetDenominator` computes at cardinality_estimator.cpp:285-401,
# including:
#   * The redundant-edge SKIP via `seen_classes` (cardinality_estimator.cpp:336-341)
#     — THE load-bearing dedup mechanism that re-ranks Q5 from the
#       fan-out plan to the lineitem-supplier-early plan.
#   * The tie-break determinism contract
#     — (left_relation, right_relation, edge_index) ascending after the
#       primary TDOM-descending sort.
#   * The leftover-composite fallback — composite edges
#     contribute `_max_ndv_across_keys_for_edge` instead of a class TDOM.
#   * The saturation policy — no saturation; the divide-after-multiply is
#     exact while the product fits Int64.
#
# Q5 worked-example test (case 8) is the LOAD-BEARING end-to-end validation:
# it constructs the 6-relation Q5 chain + 6 per-column edges + Tier-2
# provider, builds the TdomGraph via `build_tdom_graph`, computes the
# per-pair costs for the critical lineitem-supplier-early vs customer-supplier
# fan-out candidates, and verifies the cost ranking matches the
# analytic prediction.
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
    RelationSet,
)
from komira_optimizer.optimizer_column_stats_provider import (
    ColumnStatsValue,
    DefaultColumnStatsProvider,
    SyntheticColumnStatsProvider,
    TIER_PARQUET_METADATA,
    TIER_ROW_COUNT_HEURISTIC,
)
from komira_optimizer.optimizer_tdom import (
    ColumnBinding,
    EquivalenceClass,
    TdomGraph,
    build_tdom_graph,
)
from komira_optimizer.optimizer_tdom_cost import (
    edge_bridges,
    estimate_with_tdom,
    has_classes_for,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Helpers — mirror the equivalence-classes test's fixture builders so the
# test file is self-contained.
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
    id: Int,
    key: String,
    cardinality: Int,
    var stats: Optional[TableStats],
) -> JoinRelation:
    var plan = _scan("r" + String(id) + ".parquet", key, cardinality)
    return JoinRelation(id, plan^, cardinality, stats^)


def _mk_edge(
    lr: Int, rr: Int, lk: String, rk: String
) -> JoinEdge:
    """Single-key per-column edge."""
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return JoinEdge(lr, rr, lks^, rks^)


def _mk_edge2(
    lr: Int,
    rr: Int,
    lk1: String,
    lk2: String,
    rk1: String,
    rk2: String,
) -> JoinEdge:
    """Composite 2-key edge (leftover-fallback shape)."""
    var lks = List[String]()
    lks.append(lk1)
    lks.append(lk2)
    var rks = List[String]()
    rks.append(rk1)
    rks.append(rk2)
    return JoinEdge(lr, rr, lks^, rks^)


# =============================================================================
# 1. Single-edge denominator — the simplest correctness check
# =============================================================================


def test_single_edge_denominator() raises:
    """One bridging edge, one class, TDOM = 10.

    left_card = 100, right_card = 200 → numerator = 20,000
    denominator = 10 (the class TDOM)
    estimate = 20,000 // 10 = 2,000
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 10, ns2^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    # Tier-2 path: MIN(100, 10) = 10 = the class TDOM.
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.num_classes(), 1)
    assert_equal(tdom.classes[0].tdom(), 10)

    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    var est = estimate_with_tdom(
        tdom, chain, left, right, 100, 200, provider
    )
    # (100 * 200) / 10 = 2000.
    assert_equal(est, 2_000)


# =============================================================================
# 2. Multi-edge SAME class — the redundant-edge skip (THE dedup win)
# =============================================================================


def test_multi_edge_same_class_redundant_skip() raises:
    """Two bridging edges that resolve to the SAME equivalence class —
    only ONE contribution to the denominator (the dedup win that lets Q5
    re-rank).

    Setup: 3 relations A, B, C with NDVs 100, 25, 200.
      e0: A.x = B.y    → class C0 {(A,x), (B,y)}
      e1: B.y = C.z    → extends C0 → {(A,x), (B,y), (C,z)}, TDOM = MIN(100,25,200) = 25.

    Now consider candidate pair `{A, C} | {B}`:
      bridging edges = [e0 (A in left, B in right), e1 (B in right, C in left)]
      Both belong to class C0 — denom should be 25 (counted ONCE), NOT 25*25 = 625.

    estimate = (left_card * right_card) / 25.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))   # A
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 25, ns2^))   # B (bridge)
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "z", 200, ns3^))  # C
    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    chain.edges.append(_mk_edge(1, 2, "y", "z"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.num_classes(), 1, "transitive merge → 1 class")
    assert_equal(tdom.classes[0].tdom(), 25)

    # left = {A, C}, right = {B}. e0 bridges (A in left, B in right);
    # e1 bridges (B in right, C in left). BOTH point to class 0.
    var left = RelationSet.singleton(0).union(RelationSet.singleton(2))
    var right = RelationSet.singleton(1)
    var est = estimate_with_tdom(
        tdom, chain, left, right, 1000, 50, provider
    )
    # (1000 * 50) / 25 = 2000 — NOT (1000 * 50) / 625 = 80.
    assert_equal(est, 2_000, "redundant-edge skip: class counted ONCE")


# =============================================================================
# 3. Multi-class SAME relation-pair bucket — MAX-within-bucket algebra
# =============================================================================


def test_multi_class_same_relation_pair_takes_max() raises:
    """TWO distinct equivalence classes that share the SAME canonical
    relation-pair bucket `(rel_a, rel_b)` contribute via MAX-within-
    bucket (NOT PRODUCT-across-classes).

    The bucket algebra fix (per DuckDB
    `cardinality_estimator.cpp:285-401`): two classes between the same
    relation pair are CORRELATED (they're keys on one relation pair),
    not INDEPENDENT — so the denominator takes MAX of the per-class
    TDOMs within the bucket, not their product.

    Setup (cards >> NDV products, so the Tier-1 FK-PK clamp does NOT
    fire and we observe the bucket algebra cleanly):
      A: card=10_000, NDV(x)=20, NDV(p)=200 (Tier-1)
      B: card=10_000, NDV(y)=100, NDV(q)=50 (Tier-1)
      e0: A.x = B.y → class C0, TDOM = MAX(20, 100) = 100 (Tier-1 cross-class MAX)
      e1: A.p = B.q → class C1, TDOM = MAX(200, 50) = 200

    Both edges go into bucket (0, 1). MAX-within-bucket = MAX(100, 200)
    = 200.

    Before the fix (BUGGY): denom = 100 * 200 = 20_000 → est = (10K*10K)/20K = 5000.
    With the fix:          denom = MAX(100, 200) = 200 → est = (10K*10K)/200 = 500_000.

    PK-clamp check: composite_NDV(A)=4000 < |A|=10_000 → NOT PK; same
    for B. pk_side=-1; clamp does NOT fire. est stays at 500_000.
    """
    var chain = JoinChain()
    # rel A: card 10_000 with Tier-1 NDVs.
    var ts_a_names = List[String]()
    ts_a_names.append("x")
    ts_a_names.append("p")
    var ts_a_stats = List[ColumnStats]()
    var dc_x: Optional[Int] = 20
    var min_x: Optional[ScalarValue] = None
    var max_x: Optional[ScalarValue] = None
    var nc_x: Optional[Int] = None
    ts_a_stats.append(ColumnStats(dc_x^, min_x^, max_x^, nc_x^))
    var dc_p: Optional[Int] = 200
    var min_p: Optional[ScalarValue] = None
    var max_p: Optional[ScalarValue] = None
    var nc_p: Optional[Int] = None
    ts_a_stats.append(ColumnStats(dc_p^, min_p^, max_p^, nc_p^))
    var ts_a: Optional[TableStats] = TableStats(
        10_000, ts_a_names^, ts_a_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(0, "x", 10_000, ts_a^))

    # rel B: card 10_000 with Tier-1 NDVs.
    var ts_b_names = List[String]()
    ts_b_names.append("y")
    ts_b_names.append("q")
    var ts_b_stats = List[ColumnStats]()
    var dc_y: Optional[Int] = 100
    var min_y: Optional[ScalarValue] = None
    var max_y: Optional[ScalarValue] = None
    var nc_y: Optional[Int] = None
    ts_b_stats.append(ColumnStats(dc_y^, min_y^, max_y^, nc_y^))
    var dc_q: Optional[Int] = 50
    var min_q: Optional[ScalarValue] = None
    var max_q: Optional[ScalarValue] = None
    var nc_q: Optional[Int] = None
    ts_b_stats.append(ColumnStats(dc_q^, min_q^, max_q^, nc_q^))
    var ts_b: Optional[TableStats] = TableStats(
        10_000, ts_b_names^, ts_b_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(1, "y", 10_000, ts_b^))

    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    chain.edges.append(_mk_edge(0, 1, "p", "q"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    # Two independent classes (different column pairs, transitively).
    # Tier-1 path uses cross-class MAX:
    #   class 0 = MAX(20, 100) = 100
    #   class 1 = MAX(200, 50) = 200
    assert_equal(tdom.num_classes(), 2)

    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    var est = estimate_with_tdom(
        tdom, chain, left, right, 10_000, 10_000, provider
    )
    # MAX-within-bucket: denom = MAX(100, 200) = 200.
    # est = (10_000 * 10_000) / 200 = 500_000.
    assert_equal(
        est, 500_000,
        "MAX-within-bucket: two classes in same (0,1) bucket → MAX TDOM (NOT product)"
    )


# =============================================================================
# 3.5. Multi-class DIFFERENT relation-pair buckets — PRODUCT-across-buckets
#       (Q5-preservation guard)
# =============================================================================


def test_multi_class_different_relation_pairs_still_multiply() raises:
    """Two equivalence classes that span DIFFERENT relation-pair buckets
    contribute via PRODUCT (independent equivalence classes between
    different pairs).

    Q5-preservation: the MAX-within-bucket fix MUST NOT collapse
    PRODUCT-across-DIFFERENT-pairs into a MAX. That's the case where Q5's
    cost model picks the lineitem-supplier-early plan — the
    customer-supplier and lineitem-supplier classes are between
    different pairs and their TDOMs multiply.

    Setup:
      A: card=10_000, NDV(x)=20, NDV(p)=50
      B: card=10_000, NDV(y)=100
      C: card=10_000, NDV(q)=200
      e0: A.x = B.y → class C0, bucket (0,1), TDOM = MAX(20, 100) = 100
      e1: A.p = C.q → class C1, bucket (0,2), TDOM = MAX(50, 200) = 200

    Candidate `{A} ⋈ {B, C}`:
      bridging edges = [e0, e1] in DIFFERENT buckets — PRODUCT, not MAX.

    The old and the fixed algebra both compute denom = 100 * 200 = 20_000.
    The DIFFERENCE only manifests when classes share a bucket (test #3).

    PK-clamp check: composite_NDV(A) = NDV(x) for bucket (0,1) and
    NDV(p) for bucket (0,2) — single-key per bucket. NDV(x)=20 vs
    card(A)=10_000 → not PK. NDV(y)=100 vs card(B)=10_000 → not PK.
    No clamp; est stays at the analytic value.
    """
    var chain = JoinChain()
    # rel A: Tier-1 NDVs for x and p.
    var ts_a_names = List[String]()
    ts_a_names.append("x")
    ts_a_names.append("p")
    var ts_a_stats = List[ColumnStats]()
    var dc_x: Optional[Int] = 20
    var min_x: Optional[ScalarValue] = None
    var max_x: Optional[ScalarValue] = None
    var nc_x: Optional[Int] = None
    ts_a_stats.append(ColumnStats(dc_x^, min_x^, max_x^, nc_x^))
    var dc_p: Optional[Int] = 50
    var min_p: Optional[ScalarValue] = None
    var max_p: Optional[ScalarValue] = None
    var nc_p: Optional[Int] = None
    ts_a_stats.append(ColumnStats(dc_p^, min_p^, max_p^, nc_p^))
    var ts_a: Optional[TableStats] = TableStats(
        10_000, ts_a_names^, ts_a_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(0, "x", 10_000, ts_a^))

    # rel B: Tier-1 NDV for y.
    var ts_b_names = List[String]()
    ts_b_names.append("y")
    var ts_b_stats = List[ColumnStats]()
    var dc_y: Optional[Int] = 100
    var min_y: Optional[ScalarValue] = None
    var max_y: Optional[ScalarValue] = None
    var nc_y: Optional[Int] = None
    ts_b_stats.append(ColumnStats(dc_y^, min_y^, max_y^, nc_y^))
    var ts_b: Optional[TableStats] = TableStats(
        10_000, ts_b_names^, ts_b_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(1, "y", 10_000, ts_b^))

    # rel C: Tier-1 NDV for q.
    var ts_c_names = List[String]()
    ts_c_names.append("q")
    var ts_c_stats = List[ColumnStats]()
    var dc_q: Optional[Int] = 200
    var min_q: Optional[ScalarValue] = None
    var max_q: Optional[ScalarValue] = None
    var nc_q: Optional[Int] = None
    ts_c_stats.append(ColumnStats(dc_q^, min_q^, max_q^, nc_q^))
    var ts_c: Optional[TableStats] = TableStats(
        10_000, ts_c_names^, ts_c_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(2, "q", 10_000, ts_c^))

    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    chain.edges.append(_mk_edge(0, 2, "p", "q"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    # Two independent classes (different column pairs).
    #   class 0 = MAX(20, 100) = 100
    #   class 1 = MAX(50, 200) = 200
    assert_equal(tdom.num_classes(), 2)

    # Candidate {A=0} ⋈ {B=1, C=2}. Both e0 and e1 bridge.
    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1).union(RelationSet.singleton(2))
    var est = estimate_with_tdom(
        tdom, chain, left, right, 10_000, 10_000_000, provider
    )
    # PRODUCT across different buckets: denom = 100 * 200 = 20_000.
    # est = (10_000 * 10_000_000) / 20_000 = 5_000_000.
    assert_equal(
        est, 5_000_000,
        "PRODUCT across different relation-pair buckets (Q5 preservation)"
    )


# =============================================================================
# 3.6. FK-PK clamp — fires when Tier-1 composite-NDV saturates at |rel|
#       (Q9-restoration guard)
# =============================================================================


def test_fkpk_clamp_fires_with_tier1_pk_signal_mirrors_q9() raises:
    """Mirror Q9's lineitem⋈partsupp composite. With Tier-1-backed
    NDVs whose product saturates at |rel| on both sides, the FK-PK
    upper-bound clamp `est = min(est, max(L, R))` MUST fire (and
    must produce the algebraically correct FK-PK ceiling, NOT the
    cost-model formula's over-estimate).

    Setup (Q9-shaped scale ratios):
      L: |L|=6_000_000, NDV(la)=200_000, NDV(lb)=10_000 (Tier-1)
      R: |R|=  800_000, NDV(ra)=200_000, NDV(rb)=10_000 (Tier-1)
      e0: L.la = R.ra → class C0
      e1: L.lb = R.rb → class C1
      Same bucket (0, 1) — composite key.

    `build_tdom_graph` class build (Tier-1 cross-class MAX):
      class C0 TDOM = MAX(200K, 200K) = 200_000.
      class C1 TDOM = MAX(10K, 10K)   = 10_000.

    Bucket algebra: MAX-within-bucket = MAX(200K, 10K) = 200_000.
    Pre-clamp est = (6M * 800K) / 200K = 24_000_000  (Q9's over-estimate).

    composite_NDV(L) = MIN(200K * 10K, |L|=6M) = MIN(2e9, 6M) = 6M = |L| → PK Tier-1.
    composite_NDV(R) = MIN(200K * 10K, |R|=800K) = MIN(2e9, 800K) = 800K = |R| → PK Tier-1.
    pk_side = -2 (both); Tier-1 gate passes on either side → clamp fires.

    Bound = max(|L|, |R|) = 6_000_000. Clamped est = min(24M, 6M) = 6M.

    This is the Q9 fix: the clamp restores the true FK-PK cardinality
    (6M) over the cost-model's over-estimate (24M), so a DPccp plan-shape
    selector (not in this tree) can value the LEFT-DEEP-composite-leading
    plan over the BUSHY alternative.
    """
    var chain = JoinChain()
    # L: 6M rows, Tier-1 NDVs.
    var ts_l_names = List[String]()
    ts_l_names.append("la")
    ts_l_names.append("lb")
    var ts_l_stats = List[ColumnStats]()
    var dc_la: Optional[Int] = 200_000
    var min_la: Optional[ScalarValue] = None
    var max_la: Optional[ScalarValue] = None
    var nc_la: Optional[Int] = None
    ts_l_stats.append(ColumnStats(dc_la^, min_la^, max_la^, nc_la^))
    var dc_lb: Optional[Int] = 10_000
    var min_lb: Optional[ScalarValue] = None
    var max_lb: Optional[ScalarValue] = None
    var nc_lb: Optional[Int] = None
    ts_l_stats.append(ColumnStats(dc_lb^, min_lb^, max_lb^, nc_lb^))
    var ts_l: Optional[TableStats] = TableStats(
        6_000_000, ts_l_names^, ts_l_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(0, "la", 6_000_000, ts_l^))

    # R: 800K rows, Tier-1 NDVs.
    var ts_r_names = List[String]()
    ts_r_names.append("ra")
    ts_r_names.append("rb")
    var ts_r_stats = List[ColumnStats]()
    var dc_ra: Optional[Int] = 200_000
    var min_ra: Optional[ScalarValue] = None
    var max_ra: Optional[ScalarValue] = None
    var nc_ra: Optional[Int] = None
    ts_r_stats.append(ColumnStats(dc_ra^, min_ra^, max_ra^, nc_ra^))
    var dc_rb: Optional[Int] = 10_000
    var min_rb: Optional[ScalarValue] = None
    var max_rb: Optional[ScalarValue] = None
    var nc_rb: Optional[Int] = None
    ts_r_stats.append(ColumnStats(dc_rb^, min_rb^, max_rb^, nc_rb^))
    var ts_r: Optional[TableStats] = TableStats(
        800_000, ts_r_names^, ts_r_stats^, STATS_SOURCE_PARQUET_METADATA
    )
    chain.relations.append(_make_relation(1, "ra", 800_000, ts_r^))

    chain.edges.append(_mk_edge(0, 1, "la", "ra"))
    chain.edges.append(_mk_edge(0, 1, "lb", "rb"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.num_classes(), 2, "two independent equivalence classes")

    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    var est = estimate_with_tdom(
        tdom, chain, left, right, 6_000_000, 800_000, provider
    )
    # Algebra pre-clamp: MAX(200K, 10K) = 200K.
    # est = (6M * 800K) / 200K = 24M.
    # FK-PK clamp fires (Tier-1, both sides PK) → min(24M, max(6M, 800K)) = 6M.
    assert_equal(
        est, 6_000_000,
        "FK-PK clamp restores true cardinality (Q9 fix)",
    )


# =============================================================================
# 3.7. FK-PK clamp gate — does NOT fire under Tier-2 row-count fallback
#       (Q5 plan-shape preservation guard)
# =============================================================================


def test_fkpk_clamp_does_not_fire_under_tier2_only() raises:
    """Under Tier-2 row-count fallback (no Tier-1 NDV signal), the
    FK-PK clamp MUST NOT fire — even though Tier-2 trivially gives
    `NDV(col) == |rel|` for every column. The clamp gate
    (`_all_bucket_cols_have_hll_signal`) rejects Tier-2-only PK
    signals to avoid spuriously clamping every Tier-2 join pair.

    This is the Q5-preservation guarantee: TPC-H Q5's relations have
    no writer-emitted NDV stats on common DuckDB-emitted parquet
    fixtures, so Tier-2 row-count fallback drives every NDV signal.
    The FK-PK clamp must NOT touch the Q5 cost ranking — that
    invariant is locked in by tests #8-#11 below; this test makes the
    contract explicit at the unit level.

    Setup:
      L: card=6_000_000, NO table_stats → Tier-2 NDV(la) = 6M.
      R: card=  800_000, NO table_stats → Tier-2 NDV(ra) = 800K.
      Single bridging edge L.la = R.ra.

    composite_NDV(L) = MIN(NDV(la), |L|) = MIN(6M, 6M) = 6M = |L|
        → composite-NDV-PK predicate trivially satisfied.
    composite_NDV(R) = MIN(NDV(ra), |R|) = MIN(800K, 800K) = 800K = |R|
        → composite-NDV-PK predicate trivially satisfied.
    pk_side = -2 (both qualify by composite-NDV).
    BUT: from_hll=False on both sides → Tier-1 gate REJECTS → clamp
    does NOT fire.

    Class C0 TDOM under Tier-2 cross-class MIN = MIN(6M, 800K) = 800K.
    est = (6M * 800K) / 800K = 6_000_000. No clamp.
    """
    var chain = JoinChain()
    # No table_stats → Tier-2 path.
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "la", 6_000_000, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "ra", 800_000, ns2^))
    chain.edges.append(_mk_edge(0, 1, "la", "ra"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.num_classes(), 1)

    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    var est = estimate_with_tdom(
        tdom, chain, left, right, 6_000_000, 800_000, provider
    )
    # Tier-2 class TDOM = MIN(6M, 800K) = 800K.
    # est = (6M * 800K) / 800K = 6_000_000. Clamp does NOT fire under
    # Tier-2 only (the Q5 preservation contract).
    assert_equal(
        est, 6_000_000,
        "Tier-2-only NDV → clamp gate rejects → no clamp (Q5 preservation)",
    )
    # The call above cannot tell a rejected clamp from a fired one: est
    # equals max(L, R). With both cumulative cards at 8M the unclamped
    # estimate (8M * 8M) / 800K = 80M is above the clamp bound max(8M, 8M)
    # = 8M, so a gate that let Tier-2 through would return 8M here.
    var est_big = estimate_with_tdom(
        tdom, chain, left, right, 8_000_000, 8_000_000, provider
    )
    assert_equal(
        est_big, 80_000_000,
        "Tier-2-only NDV: the clamp must not cut 80M to max(L, R) = 8M",
    )


# =============================================================================
# 4. edge_bridges semantics — 4 boundary cases
# =============================================================================


def test_edge_bridges_cross_subset_returns_true() raises:
    """Edge with one endpoint in left_set and the other in right_set → True."""
    var edge = _mk_edge(0, 1, "x", "y")
    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    assert_true(edge_bridges(edge, left, right))
    # Symmetric: bridging is the same in reversed orientation.
    assert_true(edge_bridges(edge, right, left))


def test_edge_bridges_both_in_left_returns_false() raises:
    """Edge with BOTH endpoints in left_set → False (internal to left)."""
    var edge = _mk_edge(0, 1, "x", "y")
    var left = RelationSet.singleton(0).union(RelationSet.singleton(1))
    var right = RelationSet.singleton(2)
    assert_false(
        edge_bridges(edge, left, right),
        "edge internal to left_set does not bridge",
    )


def test_edge_bridges_both_in_right_returns_false() raises:
    """Edge with BOTH endpoints in right_set → False (internal to right)."""
    var edge = _mk_edge(0, 1, "x", "y")
    var left = RelationSet.singleton(2)
    var right = RelationSet.singleton(0).union(RelationSet.singleton(1))
    assert_false(
        edge_bridges(edge, left, right),
        "edge internal to right_set does not bridge",
    )


def test_edge_bridges_neither_endpoint_returns_false() raises:
    """Edge with NEITHER endpoint in either set → False (unreachable)."""
    var edge = _mk_edge(0, 1, "x", "y")
    var left = RelationSet.singleton(2)
    var right = RelationSet.singleton(3)
    assert_false(
        edge_bridges(edge, left, right),
        "edge with no endpoint in candidate pair does not bridge",
    )


# =============================================================================
# 5. Tie-break determinism
# =============================================================================


def test_tie_break_determinism_same_tdom_edges() raises:
    """Three SAME-TDOM edges (two of them bridge) MUST sort in deterministic
    order per the (left_relation, right_relation, edge_index) ascending
    tie-break contract. The result of `estimate_with_tdom` is the same
    regardless of insertion order — but we lock the determinism via repeated
    invocations: 100 runs must produce identical answers.

    We use 3 edges that all belong to ONE equivalence class (same TDOM),
    so the dedup picks only ONE for the denominator. The choice of WHICH
    edge contributes is irrelevant to the cost (same TDOM), but the
    determinism is locked in by the sort.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 100, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "z", 100, ns3^))
    var ns4: Optional[TableStats] = None
    chain.relations.append(_make_relation(3, "w", 100, ns4^))
    # Three edges, all in ONE class via transitive equality.
    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    chain.edges.append(_mk_edge(1, 2, "y", "z"))
    chain.edges.append(_mk_edge(2, 3, "z", "w"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.num_classes(), 1)
    assert_equal(tdom.classes[0].tdom(), 100)

    # Candidate {A,D} ⋈ {B,C}. Bridging edges: e0 (A=left,B=right),
    # e2 (D=left,C=right). Both belong to same class.
    var left = RelationSet.singleton(0).union(RelationSet.singleton(3))
    var right = RelationSet.singleton(1).union(RelationSet.singleton(2))

    var first = estimate_with_tdom(
        tdom, chain, left, right, 10_000, 10_000, provider
    )
    # Repeat 100 times; identical answer every time (determinism).
    for _ in range(100):
        var rep = estimate_with_tdom(
            tdom, chain, left, right, 10_000, 10_000, provider
        )
        assert_equal(rep, first, "estimate_with_tdom is deterministic")
    # (10000 * 10000) / 100 = 1,000,000.
    assert_equal(first, 1_000_000)


# =============================================================================
# 6. Leftover composite fallback
# =============================================================================


def test_leftover_composite_edge_uses_max_ndv_fallback() raises:
    """A leftover composite edge (len(left_keys) > 1) gets
    `edge_to_class[i] == -1` from `build_tdom_graph`. The pair cost's
    `estimate_with_tdom` dispatches it through `_max_ndv_across_keys_for_edge`
    (the legacy path).

    Setup:
      r0 = A, r1 = B. Composite edge e0: (A.x, A.y) = (B.p, B.q).
      Synthetic provider injects:
        A.x → 100, A.y → 50, B.p → 200, B.q → 25
      → MAX-NDV across keys = 200 (B.p).
    Candidate {A} ⋈ {B}. denom = 200. estimate = (1000*1000)/200 = 5000.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 1000, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "p", 1000, ns2^))
    chain.edges.append(_mk_edge2(0, 1, "x", "y", "p", "q"))

    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 100, True, TIER_PARQUET_METADATA)
    p.inject(0, "y", 50, True, TIER_PARQUET_METADATA)
    p.inject(1, "p", 200, True, TIER_PARQUET_METADATA)
    p.inject(1, "q", 25, True, TIER_PARQUET_METADATA)

    # Build the TdomGraph through the synthetic provider so the leftover
    # composite is correctly tagged class -1 (build_tdom_graph filters
    # by len(left_keys) > 1).
    var tdom = build_tdom_graph(chain, p)
    # The only edge is composite → class -1; no equivalence classes.
    assert_equal(tdom.num_classes(), 0)
    assert_equal(tdom.class_for_edge(0), -1)

    # has_classes_for returns False (no non-(-1) class on any bridging edge).
    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    assert_false(
        has_classes_for(tdom, chain, left, right),
        "all-leftover chain → no TDOM classes for this pair",
    )

    # But estimate_with_tdom on the same TdomGraph routes the composite
    # through `_max_ndv_across_keys_for_edge` and produces (L*R)/200.
    var est = estimate_with_tdom(
        tdom, chain, left, right, 1000, 1000, p
    )
    assert_equal(est, (1000 * 1000) // 200, "composite max-NDV fallback")


# =============================================================================
# 7. Saturation policy — near-overflow simulation
# =============================================================================


def test_near_overflow_numerator_uses_floor_div() raises:
    """Stress the saturation contract: numerator can be large (1e18; the
    Int64 max is ~9.22e18), but `estimate_with_tdom` itself does NOT apply
    saturating multiplication — the divide-after-multiply produces a
    correct result as long as the unsaturated product fits Int64.

    We pick `left_card=right_card=1_000_000_000` (1e9). Product = 1e18
    which fits Int64 (max ~9.22e18). With class TDOM = 1e6, estimate =
    1e18 / 1e6 = 1e12.

    This case validates that the divide saves us even when the numerator
    is near the Int64 ceiling. Larger inputs (1e10 * 1e10 = 1e20) WOULD
    overflow, and nothing saturates them (see the optimizer_tdom_cost.mojo
    header). This test calls estimate_with_tdom standalone.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    # 1e9 row relations; key NDV = 1e6 (synthetic injection).
    chain.relations.append(_make_relation(0, "x", 1_000_000_000, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 1_000_000_000, ns2^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 1_000_000, True, TIER_PARQUET_METADATA)
    p.inject(1, "y", 1_000_000, True, TIER_PARQUET_METADATA)

    var tdom = build_tdom_graph(chain, p)
    assert_equal(tdom.num_classes(), 1)
    # Tier-1 cross-class MAX → class TDOM = 1_000_000.
    assert_equal(tdom.classes[0].tdom(), 1_000_000)

    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    var est = estimate_with_tdom(
        tdom, chain, left, right,
        1_000_000_000, 1_000_000_000, p
    )
    # numerator = 1e18 (fits Int64). denom = 1e6. estimate = 1e12.
    assert_equal(est, 1_000_000_000_000)


# =============================================================================
# 8. Q5 worked-example cost — THE critical end-to-end validation
# =============================================================================
#
# The DP cost ranking under the TDOM cost model
# unwinds Q5's catastrophic fan-out plan by:
#   * Recognizing the cust↔supp↔nation edges as ONE equivalence class
#     (TDOM=25), so the fan-out plan's denominator is no longer
#     mis-inflated by triple-counting.
#   * Allowing the lineitem-supplier-early plan via per-column edge e0b
#     (TDOM=10K), which the per-column edge split made reachable.
#
# Critical pair costs (analytic):
#   * {lineitem} ⋈ {supplier} via e0b  →  (6_001_215 * 10_000) / 10_000 = 6_001_215
#   * {customer} ⋈ {supplier} via e2   →  (150_000 * 10_000) / 25 = 60_000_000
# Plan B (lineitem-early) has the smaller leading-pair cost; subsequent
# joins follow.
# =============================================================================


comptime R_LINEITEM: Int = 0
comptime R_ORDERS: Int = 1
comptime R_CUSTOMER: Int = 2
comptime R_SUPPLIER: Int = 3
comptime R_NATION: Int = 4
comptime R_REGION: Int = 5

comptime SF1_LINEITEM: Int = 6_001_215
comptime SF1_ORDERS: Int = 1_500_000
comptime SF1_CUSTOMER: Int = 150_000
comptime SF1_SUPPLIER: Int = 10_000
comptime SF1_NATION: Int = 25
comptime SF1_REGION: Int = 5


def _build_q5_chain_tier2_only() -> JoinChain:
    """Construct Q5's 6-relation chain WITHOUT Tier-1 stats. Provider
    falls through Tier-2 row-count on every column — the dominant
    production case for SF1 fixtures (DuckDB-emitted parquet carries
    no writer-NDV).
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(R_LINEITEM, "l_orderkey", SF1_LINEITEM, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(R_ORDERS, "o_orderkey", SF1_ORDERS, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(R_CUSTOMER, "c_custkey", SF1_CUSTOMER, ns3^))
    var ns4: Optional[TableStats] = None
    chain.relations.append(_make_relation(R_SUPPLIER, "s_suppkey", SF1_SUPPLIER, ns4^))
    var ns5: Optional[TableStats] = None
    chain.relations.append(_make_relation(R_NATION, "n_nationkey", SF1_NATION, ns5^))
    var ns6: Optional[TableStats] = None
    chain.relations.append(_make_relation(R_REGION, "r_regionkey", SF1_REGION, ns6^))
    # 6 per-column edges in chain-extractor emit order.
    chain.edges.append(_mk_edge(R_LINEITEM, R_ORDERS, "l_orderkey", "o_orderkey"))      # e0a
    chain.edges.append(_mk_edge(R_LINEITEM, R_SUPPLIER, "l_suppkey", "s_suppkey"))      # e0b
    chain.edges.append(_mk_edge(R_ORDERS, R_CUSTOMER, "o_custkey", "c_custkey"))        # e1
    chain.edges.append(_mk_edge(R_CUSTOMER, R_SUPPLIER, "c_nationkey", "s_nationkey"))  # e2
    chain.edges.append(_mk_edge(R_SUPPLIER, R_NATION, "s_nationkey", "n_nationkey"))    # e3
    chain.edges.append(_mk_edge(R_NATION, R_REGION, "n_regionkey", "r_regionkey"))      # e4
    return chain^


def test_q5_lineitem_supplier_early_cost_pair() raises:
    """The critical pair cost: {lineitem} ⋈ {supplier} via e0b.

    Class for e0b: {l_suppkey, s_suppkey}, TDOM = MIN(6M, 10K) = 10K.
    Pair cost = (6_001_215 * 10_000) / 10_000 = 6_001_215.

    This is the lineitem-early path that the per-column edge split made REACHABLE (the
    per-column edge e0b exists) and that the TDOM denominator
    keeps from being over-penalized vs. fan-out plans.
    """
    var chain = _build_q5_chain_tier2_only()
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    # 5 classes.
    assert_equal(tdom.num_classes(), 5)

    var left = RelationSet.singleton(R_LINEITEM)
    var right = RelationSet.singleton(R_SUPPLIER)
    var est = estimate_with_tdom(
        tdom, chain, left, right,
        SF1_LINEITEM, SF1_SUPPLIER, provider
    )
    # (6_001_215 * 10_000) / 10_000 = 6_001_215.
    assert_equal(
        est, SF1_LINEITEM,
        "lineitem-supplier pair cost is 6_001_215 (per design §6.4)",
    )


def test_q5_customer_supplier_fanout_cost_pair() raises:
    """The fan-out pair cost: {customer} ⋈ {supplier} via e2.

    Class for e2: {c_nationkey, s_nationkey, n_nationkey}, TDOM = MIN(150K, 10K, 25) = 25.
    Pair cost = (150_000 * 10_000) / 25 = 60_000_000.

    This is the catastrophic fan-out pair. The TDOM cost model
    correctly assigns it 60M cost — much higher than the
    lineitem-supplier-early pair's 6M. A DP enumerator (not in this tree)
    prefers the smaller-cost candidate.
    """
    var chain = _build_q5_chain_tier2_only()
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    var left = RelationSet.singleton(R_CUSTOMER)
    var right = RelationSet.singleton(R_SUPPLIER)
    var est = estimate_with_tdom(
        tdom, chain, left, right,
        SF1_CUSTOMER, SF1_SUPPLIER, provider
    )
    # (150_000 * 10_000) / 25 = 60_000_000.
    assert_equal(
        est, 60_000_000,
        "customer-supplier fan-out pair cost is 60M (per design §6.4)",
    )


def test_q5_lineitem_supplier_cheaper_than_customer_supplier() raises:
    """The plan-shape correctness check: the lineitem-supplier pair is
    SUBSTANTIALLY cheaper than the customer-supplier fan-out, so a DP
    enumerator (not in this tree) prefers the lineitem-early path.

    Cost ratio: 60M / 6M = 10× — the lineitem-supplier-early plan is
    an order of magnitude cheaper for the leading pair. This is the
    plan-shape rebalancing that the TDOM cost model enables.
    """
    var chain = _build_q5_chain_tier2_only()
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    var lineitem_supplier = estimate_with_tdom(
        tdom, chain,
        RelationSet.singleton(R_LINEITEM),
        RelationSet.singleton(R_SUPPLIER),
        SF1_LINEITEM, SF1_SUPPLIER, provider,
    )
    var customer_supplier = estimate_with_tdom(
        tdom, chain,
        RelationSet.singleton(R_CUSTOMER),
        RelationSet.singleton(R_SUPPLIER),
        SF1_CUSTOMER, SF1_SUPPLIER, provider,
    )
    assert_true(
        lineitem_supplier < customer_supplier,
        "DP cost: lineitem-supplier pair < customer-supplier pair",
    )
    # Sanity: the ratio is meaningful (10×, NOT a noise margin).
    assert_true(
        customer_supplier // lineitem_supplier >= 8,
        "Fan-out plan is at least 8× costlier than lineitem-early plan",
    )


def test_q5_nation_dedup_in_extended_pair() raises:
    """Specific dedup-mechanism check on Q5: the candidate pair
    {supplier, nation} ⋈ {customer}. Bridging edges:
      * e2 (c_nationkey=s_nationkey): supplier in left, customer in right → bridges.
        Class for e2 = C(nationkey), TDOM=25.
      * e3 (s_nationkey=n_nationkey): both supplier and nation in LEFT → does NOT
        bridge (test #4 boundary).
      * e1 (o_custkey=c_custkey): neither orders nor customer in left? customer is
        in right, orders is NOT in left → does NOT bridge.
    So only e2 contributes; denom = 25. estimate = (10000*25 * 150000) / 25.

    Now consider a SECOND candidate that bridges via MULTIPLE nation-class
    edges: {supplier} ⋈ {customer, nation}. Bridging edges:
      * e2 (c_nationkey=s_nationkey): supplier in left, customer in right → bridges.
      * e3 (s_nationkey=n_nationkey): supplier in left, nation in right → bridges.
      Both edges belong to class C(nationkey), TDOM=25. DEDUP → denom=25
      (NOT 25*25=625, which is what the legacy model would compute).
    estimate = (10000 * 150000 * 25) / 25 = same as if only one edge contributed.
    """
    var chain = _build_q5_chain_tier2_only()
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    # Candidate {supplier, nation} ⋈ {customer}. Use 10K * 25 = 250K for
    # the {supplier, nation} cumulative card; 150K for customer.
    var left_sn = RelationSet.singleton(R_SUPPLIER).union(RelationSet.singleton(R_NATION))
    var right_c = RelationSet.singleton(R_CUSTOMER)
    var est_1 = estimate_with_tdom(
        tdom, chain, left_sn, right_c,
        SF1_SUPPLIER * SF1_NATION, SF1_CUSTOMER, provider,
    )

    # Candidate {supplier} ⋈ {customer, nation}. Same physical join via
    # multiple bridging edges to the SAME class.
    var left_s = RelationSet.singleton(R_SUPPLIER)
    var right_cn = RelationSet.singleton(R_CUSTOMER).union(RelationSet.singleton(R_NATION))
    var est_2 = estimate_with_tdom(
        tdom, chain, left_s, right_cn,
        SF1_SUPPLIER, SF1_CUSTOMER * SF1_NATION, provider,
    )

    # Both have numerator = 10K * 25 * 150K = 3.75e10.
    # The dedup case: denom = 25 (one class). estimate = 1.5e9.
    # The non-dedup case (legacy) would multiply by 25 again: denom = 625, estimate = 6e7.
    # We assert est_2 reflects the dedup denominator (25, not 625).
    assert_equal(
        est_2, 10_000 * 150_000 * 25 // 25,
        "multi-edge same-class dedup: denom counts C(nationkey) ONCE",
    )
    # Sanity: est_1 (single bridging edge) and est_2 (two bridging edges, same class)
    # produce the same denominator (25). Numerators differ only by which side
    # carries the 25× multiplier — total numerator is identical.
    assert_equal(
        est_1, est_2,
        "Single-bridging-edge and multi-bridging-edge-same-class produce same denom",
    )


# =============================================================================
# has_classes_for behavioral check
# =============================================================================


def test_has_classes_for_returns_false_with_no_bridging() raises:
    """When NO edge bridges the candidate pair, `has_classes_for` returns
    False. A cost caller then falls through to the legacy
    estimate_join_cardinality_with_ndv (DPccp's `_cost_for_pair`, not in
    this tree, does; DPccp never enumerates a disconnected pair, so the
    fall-through is defensive).
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 100, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "z", 100, ns3^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))   # only edge: 0↔1.

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    # Pair {0} ⋈ {2}: no bridging edge → False.
    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(2)
    assert_false(has_classes_for(tdom, chain, left, right))


def test_has_classes_for_returns_true_with_class_bridging() raises:
    """When AT LEAST one bridging edge has a non-(-1) class, returns True."""
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 100, ns2^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    var left = RelationSet.singleton(0)
    var right = RelationSet.singleton(1)
    assert_true(has_classes_for(tdom, chain, left, right))


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
