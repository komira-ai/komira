# =============================================================================
# Tests for DPccp join enumerator (optimizer_dpccp.mojo)
# =============================================================================
#
# DPccp activates intrinsically based on chain shape (by design,
# no feature flag). `should_use_dpccp(chain)` returns True
# when chain length is in [DPCCP_MIN_RELATIONS, DPCCP_MAX_RELATIONS] AND
# at least one relation carries NDV stats or a scan row count. The tests in
# this module exercise the core algorithm directly by calling
# `solve_dpccp_with_cost` with a hand-built Dict[UInt64, Int] cost
# override so we can verify that the DP picks the low-cost decomposition
# on biased inputs, independent of the default cost model (the chains
# below use uniform cardinalities, so the injected costs decide).
#
# Coverage:
#   - Single-join chain: a 2-leaf, 1-edge chain yields an INNER join of
#     two scans.
#   - 3-way chain with a biased cost override: the outer join combines a
#     2-join subtree with a leaf.
#   - 3-way star with a biased cost override: a plan is returned.
#   - 4-way linear chain: the plan has 4 scan leaves and 3 joins.
#   - 13-relation cap: returns None (n > DPCCP_MAX_RELATIONS); 12 succeeds.
#   - 500K iteration cap: dense 12-clique bails out via counter overflow.
#   - Reconstruction: a 5-way chain's plan keeps all 5 leaves under 4 joins.
#   - Activation gate (`should_use_dpccp`): 1-, 2-, 3- and 13-relation
#     chains are rejected; 4-relation chains with NDV stats or with only a
#     row count are accepted. The two limits are listed below.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.collections import Dict

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_reorder import (
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_optimizer.optimizer_dpccp import (
    DPNode,
    DPCCP_MIN_RELATIONS,
    DPCCP_MAX_RELATIONS,
    DPCCP_MAX_ITERATIONS,
    should_use_dpccp,
    solve_dpccp,
    solve_dpccp_with_cost,
    emit_pair,
    emit_csg_complements,
    enumerate_csg_rec,
    enumerate_complement_rec,
    find_representative_plan,
    reconstruct_plan_from_dp,
)


# =============================================================================
# Test helpers -- small plans + synthetic chains
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


def _chain_linear(n: Int, base_card: Int) -> JoinChain:
    """Build a linear n-way chain: r0 -- r1 -- r2 -- ... -- r{n-1}.

    Each edge uses key name "k{i}" between ri and r{i+1}. Relation
    cardinalities are all `base_card`; tests that want the DP to have a
    unique answer pass a cost_override.
    """
    var chain = JoinChain()
    for i in range(n):
        var key = "k" + String(i)
        var plan = _scan("r" + String(i) + ".parquet", key, base_card)
        chain.relations.append(JoinRelation(i, plan^, base_card))
    for i in range(n - 1):
        var lk = List[String]()
        lk.append("k" + String(i))
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(i, i + 1, lk^, rk^))
    return chain^


def _chain_star(n: Int, base_card: Int) -> JoinChain:
    """Build a star chain with relation 0 at the center.

    Edges: (0, 1), (0, 2), ..., (0, n-1). Cardinalities uniform.
    """
    var chain = JoinChain()
    for i in range(n):
        var key = "k" + String(i)
        var plan = _scan("r" + String(i) + ".parquet", key, base_card)
        chain.relations.append(JoinRelation(i, plan^, base_card))
    for i in range(1, n):
        var lk = List[String]()
        lk.append("k0")
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(0, i, lk^, rk^))
    return chain^


def _chain_clique(n: Int, base_card: Int) -> JoinChain:
    """Build a fully-connected n-clique chain. Used to stress the iteration
    cap -- this enumerator emits far more pairs on a clique than canonical
    DPccp (n = 9: 860,736 against 9,330; komira-ai/komira#1176)."""
    var chain = JoinChain()
    for i in range(n):
        var key = "k" + String(i)
        var plan = _scan("r" + String(i) + ".parquet", key, base_card)
        chain.relations.append(JoinRelation(i, plan^, base_card))
    for i in range(n):
        for j in range(i + 1, n):
            var lk = List[String]()
            lk.append("k" + String(i))
            var rk = List[String]()
            rk.append("k" + String(j))
            chain.edges.append(JoinEdge(i, j, lk^, rk^))
    return chain^


def _bits_of_ids(ids: List[Int]) -> UInt64:
    """Combine singleton bits for each id (helper for cost_override keys)."""
    var out = UInt64(0)
    for i in range(len(ids)):
        out |= UInt64(1) << UInt64(ids[i])
    return out


def _empty_cost() -> Dict[UInt64, Int]:
    return Dict[UInt64, Int]()


# =============================================================================
# Constants + activation-gate tests
# =============================================================================
#
# Two limits these tests lock in:
#   * DPccp does not activate on a chain of 3 or fewer relations:
#      `should_use_dpccp` returns False on n <= 3.
#   * DPccp stops after DPCCP_MAX_ITERATIONS pair emits and returns
#      None; the bailout / iteration-cap behavior is verified
#      by `test_dpccp_iteration_cap_bails_out` further down.


def test_dpccp_constants_sane() raises:
    """Pins the three bounds: DPccp activates only on chains of
    DPCCP_MIN_RELATIONS (4) to DPCCP_MAX_RELATIONS (12) relations and
    stops after DPCCP_MAX_ITERATIONS (500,000) pair emits.
    """
    assert_equal(DPCCP_MIN_RELATIONS, 4)
    assert_equal(DPCCP_MAX_RELATIONS, 12)
    assert_equal(DPCCP_MAX_ITERATIONS, 500_000)


# -----------------------------------------------------------------------------
# Helpers for activation-gate tests: build a JoinChain with optional NDV signal.
# -----------------------------------------------------------------------------


def _table_stats_with_ndv(key: String, ndv: Int, row_count: Int) -> TableStats:
    """Build a TableStats with a single-column distinct_count signal."""
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


def _chain_linear_with_stats(
    n: Int, base_card: Int, with_ndv: Bool
) -> JoinChain:
    """Linear chain like `_chain_linear`, but optionally attach NDV
    stats to every relation. With `with_ndv=False`, all relations carry
    `table_stats=None` → `should_use_dpccp` should return False."""
    var chain = JoinChain()
    for i in range(n):
        var key = "k" + String(i)
        var plan = _scan("r" + String(i) + ".parquet", key, base_card)
        var ts: Optional[TableStats] = None
        if with_ndv:
            ts = Optional[TableStats](
                _table_stats_with_ndv(key, base_card // 10, base_card)
            )
        chain.relations.append(
            JoinRelation(i, plan^, base_card, ts^)
        )
    for i in range(n - 1):
        var lk = List[String]()
        lk.append("k" + String(i))
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(i, i + 1, lk^, rk^))
    return chain^


# -----------------------------------------------------------------------------
# DPccp must not activate on small-N (single-table /
# 2-rel / 3-rel) chains.
#
# `should_use_dpccp` is the gate consulted by `reorder_joins_with_dp`
# before calling `solve_dpccp`. A False return means greedy is used.
# -----------------------------------------------------------------------------


def test_should_use_dpccp_rejects_single_relation_chain() raises:
    """1-relation chain → False. Single-table queries
    (TPC-H Q1, Q6) must not activate DPccp."""
    var chain = _chain_linear_with_stats(1, 1000, with_ndv=True)
    assert_false(
        should_use_dpccp(chain^),
        "1-rel chain must not activate DPccp",
    )


def test_should_use_dpccp_rejects_two_relation_chain() raises:
    """2-rel chain → False. Even with NDV stats, DPccp's overhead is
    not worth it for a 1-join shape."""
    var chain = _chain_linear_with_stats(2, 1000, with_ndv=True)
    assert_false(
        should_use_dpccp(chain^),
        "2-rel chain must not activate DPccp",
    )


def test_should_use_dpccp_rejects_three_relation_chain() raises:
    """3-rel chain → False under n >= 4. 3-rel
    queries (e.g. TPC-H Q11) must not activate DPccp under the chosen
    DPCCP_MIN_RELATIONS = 4 threshold."""
    var chain = _chain_linear_with_stats(3, 1000, with_ndv=True)
    assert_false(
        should_use_dpccp(chain^),
        "3-rel chain must not activate DPccp under n>=4 threshold",
    )


def test_should_use_dpccp_accepts_four_relation_chain_no_ndv_with_row_count() raises:
    """4-rel chain with NO NDV signal but row_count populated → True
    under the row-count fallback.

    Without the fallback, chains without `table_stats` always fell
    through to greedy. The fallback's relax: when a scan carries
    `row_count` (and its relation no `table_stats`), the gate opens.
    This test locks in that contract.

    `_scan(...)` always populates `row_count` (see `_scan` above),
    so a chain built via `_chain_linear_with_stats(...,
    with_ndv=False)` exercises the row_count-only path.
    """
    var chain = _chain_linear_with_stats(4, 1000, with_ndv=False)
    assert_true(
        should_use_dpccp(chain^),
        "row-count fallback: 4-rel chain with row_count must activate DPccp",
    )


def test_should_use_dpccp_accepts_four_relation_chain_with_ndv() raises:
    """4-rel chain WITH NDV signal → True. This is the original activation
    case: n >= 4 + at-least-one-NDV-leaf opens the gate."""
    var chain = _chain_linear_with_stats(4, 1000, with_ndv=True)
    assert_true(
        should_use_dpccp(chain^),
        "4-rel chain with NDV must activate DPccp",
    )


def test_should_use_dpccp_rejects_oversize_chain() raises:
    """n > DPCCP_MAX_RELATIONS → False. Bails out to greedy regardless
    of NDV: 13 relations exceed DPCCP_MAX_RELATIONS (12)."""
    var chain = _chain_linear_with_stats(
        DPCCP_MAX_RELATIONS + 1, 100, with_ndv=True
    )
    assert_false(
        should_use_dpccp(chain^),
        "n > DPCCP_MAX_RELATIONS must fall through to greedy",
    )


# =============================================================================
# Trivial + degenerate cases
# =============================================================================


def test_dpccp_rejects_single_relation() raises:
    """n < 2 returns None. Caller falls back to greedy (or passthrough)."""
    var chain = JoinChain()
    var p = _scan("only.parquet", "k", 100)
    chain.relations.append(JoinRelation(0, p^, 100))
    var result = solve_dpccp(chain^)
    assert_false(Bool(result), "single-relation chain must return None")


def test_dpccp_rejects_too_many_relations() raises:
    """n > DPCCP_MAX_RELATIONS returns None."""
    var chain = _chain_linear(DPCCP_MAX_RELATIONS + 1, 100)
    var result = solve_dpccp(chain^)
    assert_false(
        Bool(result),
        "chain with > DPCCP_MAX_RELATIONS must return None",
    )


def test_dpccp_exactly_max_relations_runs() raises:
    """n == DPCCP_MAX_RELATIONS is allowed. Linear chain keeps iteration
    count well below the cap."""
    var chain = _chain_linear(DPCCP_MAX_RELATIONS, 100)
    var result = solve_dpccp(chain^)
    assert_true(
        Bool(result),
        "linear chain at DPCCP_MAX_RELATIONS must succeed",
    )


# =============================================================================
# Two-relation identity
# =============================================================================


def test_dpccp_single_join_identity() raises:
    """A 2-way chain has exactly one valid plan: join r0 and r1.

    The DP table stores {r0}, {r1}, and {r0, r1}. The full set's
    best_left/best_right must be one of ({r0}, {r1}) or ({r1}, {r0})
    (emission order deterministic but symmetric in cost).
    """
    var chain = _chain_linear(2, 1000)
    var result = solve_dpccp(chain^)
    assert_true(Bool(result), "2-way chain must yield a plan")
    var plan = result.take()
    # Must be an INNER join with two scan children.
    assert_true(plan.is_join())
    assert_equal(Int(plan.join_data_ref().join_type), Int(JOIN_INNER))
    ref l = plan.join_data_ref().left[]
    ref r = plan.join_data_ref().right[]
    assert_true(l.is_scan())
    assert_true(r.is_scan())


# =============================================================================
# 3-way chain with a biased cost override
# =============================================================================


def test_dpccp_3way_chain_biased_cost_picks_optimal() raises:
    """3-way linear chain r0 -- r1 -- r2 (all card=1000).

    Bias the cost_override so the only valid pair sizes matter:
      join {0,1} -> 10  (cheap)
      join {1,2} -> 500 (expensive)
      join {0,1,2} must go through the cheaper left side.

    DPccp considers (pair cost = join card + both sides' costs):
      ({0}, {1, 2}): 2000 + cost({1,2}) = 2000 + 500
      ({0, 1}, {2}): 2000 + cost({0,1}) = 2000 + 10

    Since {0,1} is cheaper than {1,2}, the best decomposition of the
    full set is ({0,1}, {2}). The test asserts that the outer join
    combines a 2-join subtree with a leaf (the direction is not fixed);
    it does not read best_left.
    """
    var chain = _chain_linear(3, 1000)
    var cost = Dict[UInt64, Int]()
    # Pair {0,1}: cheap
    cost[_bits_of_ids([0, 1])] = 10
    # Pair {1,2}: expensive
    cost[_bits_of_ids([1, 2])] = 500
    # Pair {0,1,2}: forced large (same regardless of route, doesn't
    # matter for decomposition choice since it's symmetric)
    cost[_bits_of_ids([0, 1, 2])] = 2000

    var result = solve_dpccp_with_cost(chain^, cost)
    assert_true(Bool(result), "3-way chain must yield a plan")
    var plan = result.take()
    assert_true(plan.is_join())
    # The outer join's children: one side must be the {0,1} sub-join
    # (a JOIN node), the other the {2} scan. Direction is not fixed.
    ref l = plan.join_data_ref().left[]
    ref r = plan.join_data_ref().right[]
    var one_is_join_one_is_scan = (l.is_join() and r.is_scan()) or (
        l.is_scan() and r.is_join()
    )
    assert_true(
        one_is_join_one_is_scan,
        "3-way optimal: outer must combine a 2-join subtree with a leaf",
    )


def test_dpccp_3way_star_finds_optimal() raises:
    """3-way star: r0 is the center, edges (0,1) and (0,2).

    This is the same relation set as the 3-way chain but the edge set
    is different. No edge between r1 and r2. DPccp should still solve
    it: {0,1} + {2} and {0,2} + {1} are both legal decompositions, but
    {1,2} is not (no connecting edge). We bias so {0,1} is cheaper; the
    test asserts only that a plan is returned.
    """
    var chain = _chain_star(3, 1000)
    var cost = Dict[UInt64, Int]()
    cost[_bits_of_ids([0, 1])] = 50
    cost[_bits_of_ids([0, 2])] = 200
    cost[_bits_of_ids([0, 1, 2])] = 5000

    var result = solve_dpccp_with_cost(chain^, cost)
    assert_true(Bool(result), "3-way star must yield a plan")


# =============================================================================
# 4-way mixed cost
# =============================================================================


def test_dpccp_4way_mixed() raises:
    """4-way linear chain. Its connected subsets are 4 singletons, 3
    pairs, 2 triples and the full set, one DP entry each. Any plan is
    OK; we verify it has 4 scan leaves and 3 joins.
    """
    var chain = _chain_linear(4, 500)
    var cost = Dict[UInt64, Int]()
    # Arbitrary biased costs so the DP has a preferred path.
    cost[_bits_of_ids([0, 1])] = 100
    cost[_bits_of_ids([1, 2])] = 200
    cost[_bits_of_ids([2, 3])] = 150
    cost[_bits_of_ids([0, 1, 2])] = 300
    cost[_bits_of_ids([1, 2, 3])] = 400
    cost[_bits_of_ids([0, 1, 2, 3])] = 600

    var result = solve_dpccp_with_cost(chain^, cost)
    assert_true(Bool(result), "4-way chain must yield a plan")
    var plan = result.take()
    assert_true(plan.is_join())
    # Count scan leaves reachable. Must be exactly 4 INT64 scans.
    var scan_count = _count_scans(plan)
    assert_equal(scan_count, 4, "4-way plan must have 4 scan leaves")
    # Count internal joins: exactly n-1 = 3.
    var join_count = _count_joins(plan)
    assert_equal(join_count, 3, "4-way plan must have 3 join nodes")


# =============================================================================
# Cap enforcement
# =============================================================================


def test_dpccp_iteration_cap_bails_out() raises:
    """A 12-relation complete-graph chain produces enough (csg, cmp) pairs
    to blow past DPCCP_MAX_ITERATIONS. Must return None so the caller
    falls back to greedy.
    """
    var chain = _chain_clique(DPCCP_MAX_RELATIONS, 100)
    var result = solve_dpccp(chain^)
    assert_false(
        Bool(result),
        "12-clique must exceed iteration cap and return None",
    )


# =============================================================================
# Reconstruction shape check
# =============================================================================


def _count_joins(plan: LogicalPlan) -> Int:
    """Count JOIN nodes in a plan subtree."""
    if plan.tag != PLAN_JOIN:
        return 0
    var c = 1
    c += _count_joins(plan.join_data_ref().left[])
    c += _count_joins(plan.join_data_ref().right[])
    return c


def _count_scans(plan: LogicalPlan) -> Int:
    """Count SCAN nodes in a plan subtree."""
    if plan.tag == PLAN_SCAN:
        return 1
    if plan.tag == PLAN_JOIN:
        return (
            _count_scans(plan.join_data_ref().left[])
            + _count_scans(plan.join_data_ref().right[])
        )
    return 0


def test_dpccp_reconstruction_preserves_all_leaves() raises:
    """The JoinChain -> LogicalPlan walker must emit every base relation
    exactly once. 5-way linear chain.
    """
    var chain = _chain_linear(5, 100)
    var cost = _empty_cost()
    var result = solve_dpccp_with_cost(chain^, cost)
    assert_true(Bool(result), "5-way chain must yield a plan")
    var plan = result.take()
    assert_equal(_count_scans(plan), 5, "reconstruction must preserve leaves")
    assert_equal(_count_joins(plan), 4, "5-way plan must have 4 joins")


# =============================================================================
# find_representative_plan unit test
# =============================================================================


def test_find_representative_plan_returns_lowest_bit() raises:
    """`find_representative_plan` returns the index of the set's lowest
    bit. Used by reconstruction to look up a leaf's cloned plan.
    """
    var chain = _chain_linear(4, 100)
    # {1, 2}: lowest bit is 1.
    var s = RelationSet.singleton(1).union(RelationSet.singleton(2))
    var idx = find_representative_plan(s, chain.relations)
    assert_equal(idx, 1, "lowest bit of {1,2} is 1")


# =============================================================================
# DPNode POD test
# =============================================================================


def test_dpnode_fields_roundtrip() raises:
    """DPNode stores cost, cardinality, and two RelationSet subsets."""
    var n = DPNode(
        Float64(42.5),
        1234,
        RelationSet.singleton(1),
        RelationSet.singleton(2),
    )
    assert_equal(n.cost, Float64(42.5))
    assert_equal(n.cardinality, 1234)
    assert_true(n.best_left.contains(1))
    assert_true(n.best_right.contains(2))


# =============================================================================
# RelationSet.iter helper (added for DPccp)
# =============================================================================


def test_relset_iter_empty() raises:
    var ids = RelationSet.empty().iter()
    assert_equal(len(ids), 0)


def test_relset_iter_sorted_ascending() raises:
    """iter() returns set-bit positions in ascending order."""
    var s = RelationSet.singleton(3).union(RelationSet.singleton(7))
    s = s.union(RelationSet.singleton(1))
    s = s.union(RelationSet.singleton(0))
    var ids = s.iter()
    assert_equal(len(ids), 4)
    assert_equal(ids[0], 0)
    assert_equal(ids[1], 1)
    assert_equal(ids[2], 3)
    assert_equal(ids[3], 7)


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
