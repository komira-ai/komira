# =============================================================================
# Tests for the TDOM equivalence-set graph builder
# (src/komira_optimizer/optimizer_tdom.mojo)
# =============================================================================
#
# Acceptance tests. Validates that
# `build_tdom_graph` produces the equivalence-class membership + per-class
# TDOM values that mirror DuckDB's `InitEquivalentRelations` +
# `UpdateTotalDomains` (cardinality_estimator.cpp:73-128 + 479-509).
#
# Coverage:
#   1. Single-class basic — A.x=B.y, B.y=C.z transitively merges into 1 class.
#   2. Multi-class independent — A.x=B.y and C.p=D.q produce 2 disjoint classes.
#   3. Transitive merge — A.x=B.y, B.y=C.z, D.w=A.x merges into 1 class.
#   4. Two-class merge via bridge edge.
#   5. Leftover composite skip — len(left_keys) > 1 → edge_to_class[i] == -1.
#   6. Q5 worked example — 5 expected classes with known TDOMs (Tier-2 path).
#   7. Tier-1/Tier-2 dispatch via build — mixed provider behavior.
#
# Test fixtures construct synthetic `JoinChain` (relations + edges) directly
# and use `SyntheticColumnStatsProvider` for deterministic NDV injection.
# This is the canonical fixture builder — no Parquet I/O, no
# extract_join_chain dependency. The split tests validate the
# per-column edge emit path; this file validates the union-find /
# NDV-ingestion stage downstream.
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
    ColumnBinding,
    EquivalenceClass,
    TdomGraph,
    build_tdom_graph,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Plan-construction helpers
# =============================================================================


def _single_int_schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan(path: String, key: String, n: Int) -> LogicalPlan:
    """Minimal Scan with one INT64 column. The TDOM cost model only reads
    relation_id + cardinality + table_stats, so column-count is
    irrelevant for the graph builder."""
    var s = _single_int_schema(key)
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, s^, none_proj^, none_filt^, rc^
    )


def _table_stats_with_ndv(
    key: String, ndv: Int, row_count: Int
) -> TableStats:
    """Parquet-flavored TableStats with one distinct_count entry. Used to
    exercise the Tier-1 provider path."""
    var names = List[String]()
    names.append(key)
    var stats_list = List[ColumnStats]()
    var dc: Optional[Int] = ndv
    var min_v: Optional[ScalarValue] = None
    var max_v: Optional[ScalarValue] = None
    var nc: Optional[Int] = None
    stats_list.append(ColumnStats(dc^, min_v^, max_v^, nc^))
    return TableStats(
        row_count, names^, stats_list^, STATS_SOURCE_PARQUET_METADATA
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


def _count_alive_classes(tdom: TdomGraph) -> Int:
    """Helper: post-compaction all classes are alive, but the test
    occasionally double-checks the property anyway."""
    var n = 0
    for i in range(tdom.num_classes()):
        if len(tdom.classes[i].bindings) > 0:
            n += 1
    return n


def _class_containing(
    tdom: TdomGraph, relation_id: Int, column_name: String
) -> Int:
    """Find the class index for a specific (relation, column) binding.
    Returns -1 if no class contains the binding."""
    var b = ColumnBinding(relation_id, column_name)
    for i in range(tdom.num_classes()):
        if tdom.classes[i].contains(b):
            return i
    return -1


# =============================================================================
# 1. Single-class basic — transitive equality merges A.x = B.y and B.y = C.z
# =============================================================================


def test_single_class_transitive() raises:
    """Two edges sharing a binding (B.y) should produce ONE class with
    three bindings.

      Edge e0: A.x = B.y → new class {(A,x), (B,y)}
      Edge e1: B.y = C.z → extends existing (B.y matches) → {(A,x), (B,y), (C,z)}

    This is the foundational transitivity DuckDB encodes in
    cardinality_estimator.cpp:73-128.
    """
    var chain = JoinChain()
    # Three relations: A=0, B=1, C=2. Cardinalities chosen so MIN-across-
    # class = 50 (the bridge column's relation).
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 50, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "z", 200, ns3^))
    # e0: A.x = B.y
    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    # e1: B.y = C.z
    chain.edges.append(_mk_edge(1, 2, "y", "z"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 1, "single transitive class")
    assert_equal(len(tdom.classes[0].bindings), 3,
                 "all three bindings in the merged class")
    # All edges map to class 0.
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(1), 0)
    # TDOM = MIN(100, 50, 200) = 50 (Tier-2 row-count fallback).
    assert_equal(tdom.classes[0].tdom(), 50)
    # contributing_edges captures both edges.
    assert_equal(len(tdom.classes[0].contributing_edges), 2)


# =============================================================================
# 2. Multi-class independent — disjoint column sets
# =============================================================================


def test_multi_class_independent() raises:
    """Two edges on DISJOINT columns produce two independent classes.

      Edge e0: A.x = B.y → class C0 {(A,x), (B,y)}
      Edge e1: C.p = D.q → class C1 {(C,p), (D,q)}

    No transitive bridge between them, so they stay separate.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 200, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "p", 300, ns3^))
    var ns4: Optional[TableStats] = None
    chain.relations.append(_make_relation(3, "q", 400, ns4^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    chain.edges.append(_mk_edge(2, 3, "p", "q"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 2, "two independent classes")
    # Each class has 2 bindings.
    assert_equal(len(tdom.classes[0].bindings), 2)
    assert_equal(len(tdom.classes[1].bindings), 2)
    # Each edge belongs to exactly one class.
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(1), 1)
    # Class 0 = MIN(100, 200) = 100; Class 1 = MIN(300, 400) = 300.
    var c_ax = _class_containing(tdom, 0, "x")
    assert_equal(tdom.classes[c_ax].tdom(), 100)
    var c_cp = _class_containing(tdom, 2, "p")
    assert_equal(tdom.classes[c_cp].tdom(), 300)


# =============================================================================
# 3. Transitive merge — multiple edges into the same class via shared binding
# =============================================================================


def test_transitive_chain_four_relations() raises:
    """A.x = B.y, B.y = C.z, D.w = A.x — three edges, one final class.

      e0: A.x = B.y    → new {(A,x), (B,y)}
      e1: B.y = C.z    → extends (B.y matches) → {(A,x), (B,y), (C,z)}
      e2: D.w = A.x    → extends (A.x matches) → {(A,x), (B,y), (C,z), (D,w)}
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 10, ns^))      # A
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 1000, ns2^))   # B
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "z", 500, ns3^))    # C
    var ns4: Optional[TableStats] = None
    chain.relations.append(_make_relation(3, "w", 100, ns4^))    # D
    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    chain.edges.append(_mk_edge(1, 2, "y", "z"))
    chain.edges.append(_mk_edge(3, 0, "w", "x"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 1, "all four relations one class")
    assert_equal(len(tdom.classes[0].bindings), 4)
    # All three edges map to class 0.
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(1), 0)
    assert_equal(tdom.class_for_edge(2), 0)
    # MIN(10, 1000, 500, 100) = 10.
    assert_equal(tdom.classes[0].tdom(), 10)


# =============================================================================
# 4. Two-class merge via bridge edge
# =============================================================================


def test_bridge_merges_two_classes() raises:
    """Start with two independent classes; an edge whose endpoints sit in
    DIFFERENT classes merges them into one.

      e0: A.x = B.y    → class C0 {(A,x), (B,y)}
      e1: C.p = D.q    → class C1 {(C,p), (D,q)}
      e2: B.y = C.p    → bridges C0 and C1 → ONE class {(A,x),(B,y),(C,p),(D,q)}

    Validates the 2-classes-touching merge branch in
    `_find_classes_touching` + the union-find merge logic.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 200, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 100, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "p", 300, ns3^))
    var ns4: Optional[TableStats] = None
    chain.relations.append(_make_relation(3, "q", 400, ns4^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))   # C0
    chain.edges.append(_mk_edge(2, 3, "p", "q"))   # C1
    chain.edges.append(_mk_edge(1, 2, "y", "p"))   # bridge

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    # POST-MERGE: only one class survives (compaction drops empty slots).
    assert_equal(tdom.num_classes(), 1, "bridge merges two classes into one")
    assert_equal(len(tdom.classes[0].bindings), 4)
    # All three edges remap to the surviving class.
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(1), 0)
    assert_equal(tdom.class_for_edge(2), 0)
    # MIN(200, 100, 300, 400) = 100.
    assert_equal(tdom.classes[0].tdom(), 100)
    # contributing_edges has all 3.
    assert_equal(len(tdom.classes[0].contributing_edges), 3)


# =============================================================================
# 5. Leftover composite skip — edge_to_class[i] == -1
# =============================================================================


def test_leftover_composite_edge_not_in_class() raises:
    """A leftover composite edge (len(left_keys) > 1) does NOT participate
    in any equivalence class. Its `edge_to_class[i]` is -1; the bindings
    it carries do NOT appear in any class.

    The cost model's `_max_ndv_across_keys` dispatch handles
    these.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 200, ns2^))
    var ns3: Optional[TableStats] = None
    chain.relations.append(_make_relation(2, "z", 300, ns3^))
    # e0: per-column A.x = B.y → enters a class.
    chain.edges.append(_mk_edge(0, 1, "x", "y"))
    # e1: COMPOSITE (la, lb) = (ra, rb) — leftover-fallback shape.
    # Keys "la"/"lb" and "ra"/"rb" are entirely distinct from the
    # per-column edge's columns; they MUST NOT contribute to any class.
    chain.edges.append(_mk_edge2(0, 2, "la", "lb", "ra", "rb"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    # One class only (from e0).
    assert_equal(tdom.num_classes(), 1)
    # e0 maps to class 0; e1 maps to -1.
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(1), -1,
                 "leftover composite edge has no class")
    # The composite edge's keys do NOT appear in any class.
    assert_equal(_class_containing(tdom, 0, "la"), -1)
    assert_equal(_class_containing(tdom, 2, "ra"), -1)
    # The per-column edge's keys DO appear.
    assert_true(_class_containing(tdom, 0, "x") >= 0)
    assert_true(_class_containing(tdom, 1, "y") >= 0)


# =============================================================================
# 6. Q5 worked example — the load-bearing acceptance test
# =============================================================================
#
# 6 per-column edges over 6 SF1 base
# relations, 5 expected equivalence classes, TDOMs MIN-across-class on
# Tier-2 row-count input.
#
# Dense relation_id assignment:
#   R_LINEITEM=0, R_ORDERS=1, R_CUSTOMER=2, R_SUPPLIER=3,
#   R_NATION=4, R_REGION=5
#
# Edges (per-column):
#   e0a: lineitem.l_orderkey  = orders.o_orderkey
#   e0b: lineitem.l_suppkey   = supplier.s_suppkey
#   e1:  orders.o_custkey     = customer.c_custkey
#   e2:  customer.c_nationkey = supplier.s_nationkey
#   e3:  supplier.s_nationkey = nation.n_nationkey
#   e4:  nation.n_regionkey   = region.r_regionkey
#
# Expected post-build classes:
#   C(orderkey) = {l_orderkey, o_orderkey}, TDOM = MIN(6M, 1.5M) = 1.5M
#   C(suppkey)  = {l_suppkey, s_suppkey},   TDOM = MIN(6M, 10K)  = 10K
#   C(custkey)  = {o_custkey, c_custkey},   TDOM = MIN(1.5M, 150K) = 150K
#   C(nationkey)= {c_nationkey, s_nationkey, n_nationkey}, TDOM = 25
#   C(regionkey)= {n_regionkey, r_regionkey},              TDOM = 5
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
    """Construct the Q5 chain WITHOUT writer-NDV stats. Provider falls
    through Tier-2 row-count on every column: the case for parquet written
    without NDV statistics. The relations carry the SF1 row counts above
    and no TableStats."""
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
    # 6 per-column edges in split order.
    chain.edges.append(_mk_edge(R_LINEITEM, R_ORDERS, "l_orderkey", "o_orderkey"))
    chain.edges.append(_mk_edge(R_LINEITEM, R_SUPPLIER, "l_suppkey", "s_suppkey"))
    chain.edges.append(_mk_edge(R_ORDERS, R_CUSTOMER, "o_custkey", "c_custkey"))
    chain.edges.append(_mk_edge(R_CUSTOMER, R_SUPPLIER, "c_nationkey", "s_nationkey"))
    chain.edges.append(_mk_edge(R_SUPPLIER, R_NATION, "s_nationkey", "n_nationkey"))
    chain.edges.append(_mk_edge(R_NATION, R_REGION, "n_regionkey", "r_regionkey"))
    return chain^


def test_q5_worked_example_tier2_path() raises:
    """The Q5 acceptance test: 6 per-column edges + Tier-2 provider →
    EXACTLY 5 equivalence classes with the expected TDOMs.

    This is the LOAD-BEARING test — it pins the algorithm against the
    design's prediction, validated
    analytically. If this fails, the cost model breaks.
    """
    var chain = _build_q5_chain_tier2_only()
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 5,
                 "Q5 has 5 equivalence classes after union-find")
    # All 6 edges must belong to some class (no leftover composites
    # since all Q5 per-column edges are single-key).
    for i in range(6):
        assert_true(tdom.class_for_edge(i) >= 0,
                    "every Q5 per-column edge belongs to a class")

    # ---- C(orderkey) = {l_orderkey, o_orderkey} ----
    var c_ord = _class_containing(tdom, R_LINEITEM, "l_orderkey")
    assert_true(c_ord >= 0)
    assert_equal(_class_containing(tdom, R_ORDERS, "o_orderkey"), c_ord)
    assert_equal(len(tdom.classes[c_ord].bindings), 2)
    # TDOM = MIN(6M, 1.5M) = 1.5M
    assert_equal(tdom.classes[c_ord].tdom(), SF1_ORDERS)

    # ---- C(suppkey) = {l_suppkey, s_suppkey} ----
    var c_supp = _class_containing(tdom, R_LINEITEM, "l_suppkey")
    assert_true(c_supp >= 0)
    assert_equal(_class_containing(tdom, R_SUPPLIER, "s_suppkey"), c_supp)
    assert_equal(len(tdom.classes[c_supp].bindings), 2)
    # TDOM = MIN(6M, 10K) = 10K
    assert_equal(tdom.classes[c_supp].tdom(), SF1_SUPPLIER)

    # ---- C(custkey) = {o_custkey, c_custkey} ----
    var c_cust = _class_containing(tdom, R_ORDERS, "o_custkey")
    assert_true(c_cust >= 0)
    assert_equal(_class_containing(tdom, R_CUSTOMER, "c_custkey"), c_cust)
    assert_equal(len(tdom.classes[c_cust].bindings), 2)
    # TDOM = MIN(1.5M, 150K) = 150K
    assert_equal(tdom.classes[c_cust].tdom(), SF1_CUSTOMER)

    # ---- C(nationkey) = {c_nationkey, s_nationkey, n_nationkey} ----
    # This is the THREE-binding class — the load-bearing transitivity
    # check that distinguishes Q5's bug from a simpler shape.
    var c_nat = _class_containing(tdom, R_CUSTOMER, "c_nationkey")
    assert_true(c_nat >= 0)
    assert_equal(_class_containing(tdom, R_SUPPLIER, "s_nationkey"), c_nat)
    assert_equal(_class_containing(tdom, R_NATION, "n_nationkey"), c_nat)
    assert_equal(len(tdom.classes[c_nat].bindings), 3)
    # TDOM = MIN(150K, 10K, 25) = 25 — the win.
    assert_equal(tdom.classes[c_nat].tdom(), SF1_NATION)

    # ---- C(regionkey) = {n_regionkey, r_regionkey} ----
    var c_reg = _class_containing(tdom, R_NATION, "n_regionkey")
    assert_true(c_reg >= 0)
    assert_equal(_class_containing(tdom, R_REGION, "r_regionkey"), c_reg)
    assert_equal(len(tdom.classes[c_reg].bindings), 2)
    # TDOM = MIN(25, 5) = 5
    assert_equal(tdom.classes[c_reg].tdom(), SF1_REGION)


# =============================================================================
# 7. Tier-1/Tier-2 dispatch via build — mixed provider behavior
# =============================================================================


def test_tier1_tier2_dispatch_through_build() raises:
    """Construct a chain where ONE relation has writer-NDV (Tier 1) and
    ANOTHER doesn't (Tier 2). Verify that per-class `hll_ndv` /
    `no_hll_ndv` fields are populated correctly post-build.

    Shape:
      r0 (A): has TableStats with distinct_count(x) = 7  → Tier 1 hit
      r1 (B): table_stats = None                          → Tier 2 fallback
      edge: A.x = B.y

    Expected post-build EquivalenceClass:
      hll_ndv = Some(7)   (Tier-1 contribution)
      no_hll_ndv = Some(B.cardinality)  (Tier-2 contribution)
      tdom() = hll_ndv (Tier-1 wins)
    """
    var chain = JoinChain()
    var ts = Optional[TableStats](_table_stats_with_ndv("x", 7, 100))
    chain.relations.append(_make_relation(0, "x", 100, ts^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 50, ns2^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 1)
    ref c = tdom.classes[0]
    # Mixed dispatch produces BOTH hll_ndv and no_hll_ndv populated.
    assert_true(Bool(c.hll_ndv), "Tier-1 contribution populated hll_ndv")
    assert_equal(c.hll_ndv.value(), 7)
    assert_true(Bool(c.no_hll_ndv), "Tier-2 contribution populated no_hll_ndv")
    assert_equal(c.no_hll_ndv.value(), 50)
    # tdom() prefers hll_ndv (HLL-backed signal is stronger than
    # row-count heuristic).
    assert_equal(c.tdom(), 7)


def test_tier2_only_uses_no_hll_path() raises:
    """When NO column has Tier-1 signal, hll_ndv stays None and
    no_hll_ndv carries the MIN-across-class. tdom() returns the
    no_hll_ndv value.

    This pins the all-Tier-2 case (no writer NDV, as in the Q5 chain
    above): every binding is Tier-2, and the cost model rides entirely on
    the row-count heuristic.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 50, ns2^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 1)
    ref c = tdom.classes[0]
    assert_false(Bool(c.hll_ndv), "no Tier-1 contributors → hll_ndv None")
    assert_true(Bool(c.no_hll_ndv))
    assert_equal(c.no_hll_ndv.value(), 50)
    assert_equal(c.tdom(), 50)


def test_synthetic_provider_drives_build() raises:
    """SyntheticColumnStatsProvider feeds build_tdom_graph through the
    SAME trait surface as DefaultColumnStatsProvider. This validates
    the cost-model-unit-test injection mechanism end-to-end.

    Pin: inject custkey NDVs via the synthetic provider; verify the
    class's TDOM is the MAX of the injected Tier-1 NDVs (the hll_ndv
    merge takes the MAX). Cardinalities on the
    JoinRelations are deliberately set to LARGE values to prove the
    synthetic injection takes priority over relation.cardinality (the
    synthetic provider has no awareness of JoinRelation; it returns
    only what's injected, falling back to the safe sentinel
    (ndv=1, from_hll=False) on misses)."""
    var chain = JoinChain()
    # Cardinalities deliberately huge to exclude row-count fallback.
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "c_custkey", 999_999, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "o_custkey", 999_999, ns2^))
    chain.edges.append(_mk_edge(0, 1, "c_custkey", "o_custkey"))

    var p = SyntheticColumnStatsProvider()
    # Inject custkey NDVs — both Tier-1 flagged; the merged hll_ndv is
    # their MAX (1.5M), not the MIN (150K).
    p.inject(0, "c_custkey", 150_000, True, TIER_PARQUET_METADATA)
    p.inject(1, "o_custkey", 1_500_000, True, TIER_PARQUET_METADATA)

    var tdom = build_tdom_graph(chain, p)
    assert_equal(tdom.num_classes(), 1)
    ref c = tdom.classes[0]
    # Tier-1 path: hll_ndv = MAX(150K, 1.5M) = 1.5M (MAX across the class is
    # the conservative HLL-merge upper bound — see optimizer_tdom.mojo
    # `_ingest_provider_value` AUDIT comment).
    assert_true(Bool(c.hll_ndv))
    assert_equal(c.hll_ndv.value(), 1_500_000)
    assert_equal(c.tdom(), 1_500_000)


# =============================================================================
# Edge index / class_for_edge sanity
# =============================================================================


def test_class_for_edge_out_of_range_returns_minus_one() raises:
    """`class_for_edge` is defensive against bad indices."""
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "x", 100, ns^))
    var ns2: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "y", 200, ns2^))
    chain.edges.append(_mk_edge(0, 1, "x", "y"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(-1), -1)
    assert_equal(tdom.class_for_edge(99), -1)


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
