# =============================================================================
# optimizer_dpccp_diagnostic: the trace of one DPccp solve, and the observer
# hooks in optimizer_dpccp that feed it
# =============================================================================
#
# The counts below are what this enumerator does (komira-ai/komira#1176: it
# repeats csg-cmp pairs on dense graphs). On the complete graph K4 it calls
# `emit_pair` 40 times; 18 of those score a partition of the full set, which
# has 7 distinct partitions, so 11 are repeats. A path of four relations
# repeats nothing (10 emits, 3 full-set candidates, 3 partitions); a star of
# four repeats each full-set partition once (15 emits, 6 candidates, 3
# partitions). A fix for #1176 changes the K4 and star rows here, with the
# iteration-cap rows of test_optimizer_dpccp_enumeration.
#
# Each test names the defect it catches.
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from komira_optimizer.optimizer_reorder import (
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
)
from komira_optimizer.optimizer_tdom import TdomGraph
from komira_optimizer.optimizer_dpccp import (
    DPNode,
    DPCCP_MAX_RELATIONS,
    _IterCounter,
    _build_neighbors,
    _seed_dp_base_relations,
    _run_dpccp_passes,
    emit_pair,
    solve_dpccp_observed,
    solve_dpccp_with_cost,
)
from komira_optimizer.optimizer_dpccp_observer import DPCandidate
from komira_optimizer.optimizer_dpccp_diagnostic import (
    DPccpTrace,
    solve_dpccp_with_dp_trace,
)


# =============================================================================
# Helpers
# =============================================================================


def _scan(name: String, rows: Int) -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc: Optional[Int] = rows
    return LogicalPlan.scan(name + ".parquet", SOURCE_PARQUET, b.build(), proj^, filt^, rc^)


def _chain_cards(cards: List[Int], ls: List[Int], rs: List[Int]) -> JoinChain:
    """Relations r0..r{n-1} (column k{i}, cardinality cards[i]), one edge
    k{ls[j]} = k{rs[j]} per index j."""
    var chain = JoinChain()
    for i in range(len(cards)):
        chain.relations.append(
            JoinRelation(i, _scan("k" + String(i), cards[i]), cards[i])
        )
    for j in range(len(ls)):
        var lk = List[String]()
        lk.append("k" + String(ls[j]))
        var rk = List[String]()
        rk.append("k" + String(rs[j]))
        chain.edges.append(JoinEdge(ls[j], rs[j], lk^, rk^))
    return chain^


def _chain(n: Int, ls: List[Int], rs: List[Int]) -> JoinChain:
    var cards = List[Int]()
    for _ in range(n):
        cards.append(100)
    return _chain_cards(cards, ls, rs)


def _k4() -> JoinChain:
    return _chain(4, [0, 0, 0, 1, 1, 2], [1, 2, 3, 2, 3, 3])


def _bits(ids: List[Int]) -> UInt64:
    var out = UInt64(0)
    for i in range(len(ids)):
        out |= UInt64(1) << UInt64(ids[i])
    return out


def _no_cost() -> Dict[UInt64, Int]:
    return Dict[UInt64, Int]()


# =============================================================================
# Counts: emits, scored pairs, candidates, repeats
# =============================================================================


def test_k4_trace_reports_every_emit_and_every_repeat() raises:
    """K4, target the full set: one literal-edge pass, 40 emit calls, 40
    scored, completed; 18 full-set candidates (the first two both
    {0}|{1,2,3}), 7 distinct partitions, 11 repeats. Catches: the hook in
    `emit_pair` dropped (0 candidates), the target filter dropped (40),
    a repeated emit collapsed before it reaches the observer (7), and the
    distinct count not collapsing repeats (18). In a full solve
    `emit_pair` refuses nothing, so `emit_calls` equals `scored_pairs`
    here; test_refused_calls_count_as_emits_not_as_scored tells the two
    apart."""
    var trace = DPccpTrace(UInt64(15))
    _ = solve_dpccp_with_dp_trace(_k4(), _no_cost(), trace)
    assert_equal(len(trace.passes), 1)
    assert_false(trace.passes[0].allow_cross)
    assert_equal(trace.passes[0].emit_calls, UInt64(40))
    assert_equal(trace.passes[0].scored_pairs, 40)
    assert_true(trace.passes[0].completed)
    assert_equal(len(trace.candidates), 18)
    for i in range(len(trace.candidates)):
        assert_equal(trace.candidates[i].combined_bits(), UInt64(15))
        assert_false(trace.candidates[i].allow_cross)
    assert_equal(trace.candidates[0].left_set_bits, UInt64(1))
    assert_equal(trace.candidates[0].right_set_bits, UInt64(14))
    assert_equal(trace.candidates[1].left_set_bits, UInt64(1))
    assert_equal(trace.candidates[1].right_set_bits, UInt64(14))
    assert_equal(trace.distinct_target_partitions(), 7)
    assert_equal(trace.repeated_target_emits(), 11)


def test_path_repeats_nothing_and_star_repeats() raises:
    """Path 0-1-2-3: 10 emits, 3 full-set candidates, 3 partitions, no
    repeat. Star centred on 0: 15 emits, 6 candidates, 3 partitions, 3
    repeats. Catches: a repeat count that is not candidates minus
    partitions, and a trace that invents repeats on a sparse graph."""
    var path = DPccpTrace(UInt64(15))
    _ = solve_dpccp_with_dp_trace(_chain(4, [0, 1, 2], [1, 2, 3]), _no_cost(), path)
    assert_equal(path.passes[0].emit_calls, UInt64(10))
    assert_equal(len(path.candidates), 3)
    assert_equal(path.distinct_target_partitions(), 3)
    assert_equal(path.repeated_target_emits(), 0)
    var star = DPccpTrace(UInt64(15))
    _ = solve_dpccp_with_dp_trace(_chain(4, [0, 0, 0], [1, 2, 3]), _no_cost(), star)
    assert_equal(star.passes[0].emit_calls, UInt64(15))
    assert_equal(len(star.candidates), 6)
    assert_equal(star.distinct_target_partitions(), 3)
    assert_equal(star.repeated_target_emits(), 3)


def test_target_below_the_full_set() raises:
    """K4, target {0,1,2}: 4 candidates ({0}|{1,2} twice, {0,1}|{2},
    {0,2}|{1}), 3 partitions. Catches: the target ignored in favour of
    the full set."""
    var trace = DPccpTrace(_bits([0, 1, 2]))
    _ = solve_dpccp_with_dp_trace(_k4(), _no_cost(), trace)
    assert_equal(len(trace.candidates), 4)
    assert_equal(trace.distinct_target_partitions(), 3)
    assert_equal(trace.candidates[2].left_set_bits, _bits([0, 1]))
    assert_equal(trace.candidates[2].right_set_bits, _bits([2]))


def test_distinct_partitions_ignore_orientation() raises:
    """Fed {0}|{1,2,3}, its mirror {1,2,3}|{0}, {0,1}|{2,3}, and a pair of
    another set: 3 target candidates, 2 partitions; the other pair counts
    as scored but is not a candidate. Catches: the orientation not
    normalised (3 partitions) and a non-target pair recorded."""
    var trace = DPccpTrace(UInt64(15))
    trace.on_pass_begin(False)
    trace.on_pair_scored(DPCandidate(1, 14, 1.0, 1, 0.0, 0.0, 1, 1, False))
    trace.on_pair_scored(DPCandidate(14, 1, 1.0, 1, 0.0, 0.0, 1, 1, False))
    trace.on_pair_scored(DPCandidate(3, 12, 1.0, 1, 0.0, 0.0, 1, 1, False))
    trace.on_pair_scored(DPCandidate(1, 2, 1.0, 1, 0.0, 0.0, 1, 1, False))
    assert_equal(trace.passes[0].scored_pairs, 4)
    assert_equal(len(trace.candidates), 3)
    assert_equal(trace.distinct_target_partitions(), 2)
    assert_equal(trace.repeated_target_emits(), 1)


# =============================================================================
# What each candidate carries, and what the table kept
# =============================================================================


def test_candidate_fields_and_the_kept_partition() raises:
    """Path 0-1-2 (cards 30, 50, 70) with injected costs {1,2} = 200,
    {0,1} = 300, the full set = 1000: the full-set candidates are
    {0}|{1,2} (cost 1200 = 1000 + 0 + 200; cards 30 and 200) and then
    {0,1}|{2} (cost 1300 = 1000 + 300 + 0; cards 300 and 70); the table
    keeps {0}|{1,2}, and the trace's plan is the solver's. Catches: any
    two fields swapped, the cost not the sum the table compares, the
    final table not handed back (no entry), and a trace solve that
    differs from `solve_dpccp_with_cost`."""
    var chain = _chain_cards([30, 50, 70], [0, 1], [1, 2])
    var cost = Dict[UInt64, Int]()
    cost[_bits([1, 2])] = 200
    cost[_bits([0, 1])] = 300
    cost[UInt64(7)] = 1000
    var trace = DPccpTrace(UInt64(7))
    var plan = solve_dpccp_with_dp_trace(chain, cost, trace)
    assert_equal(len(trace.candidates), 2)
    ref a = trace.candidates[0]
    assert_equal(a.left_set_bits, _bits([0]))
    assert_equal(a.right_set_bits, _bits([1, 2]))
    assert_equal(a.join_card, 1000)
    assert_equal(a.cost, Float64(1200.0))
    assert_equal(a.left_cost, Float64(0.0))
    assert_equal(a.right_cost, Float64(200.0))
    assert_equal(a.left_card, 30)
    assert_equal(a.right_card, 200)
    ref b = trace.candidates[1]
    assert_equal(b.left_set_bits, _bits([0, 1]))
    assert_equal(b.right_set_bits, _bits([2]))
    assert_equal(b.cost, Float64(1300.0))
    assert_equal(b.left_cost, Float64(300.0))
    assert_equal(b.right_cost, Float64(0.0))
    assert_equal(b.left_card, 300)
    assert_equal(b.right_card, 70)
    var kept = trace.entry_for(UInt64(7))
    assert_true(Bool(kept))
    assert_equal(kept.value().best_left.bits, _bits([0]))
    assert_equal(kept.value().best_right.bits, _bits([1, 2]))
    assert_false(Bool(trace.entry_for(_bits([0, 2]))))
    var solved = solve_dpccp_with_cost(chain, cost)
    assert_true(Bool(plan))
    assert_true(Bool(solved))
    assert_equal(String(plan.value()), String(solved.value()))


def test_k4_table_keeps_the_first_cheapest_candidate() raises:
    """K4 under the solver's own cost model: the full-set entry is the
    first candidate of least cost (a later pair replaces it only when
    strictly cheaper), so repeats never change the table. Catches: the
    trace and the table disagreeing about which partition won."""
    var trace = DPccpTrace(UInt64(15))
    _ = solve_dpccp_with_dp_trace(_k4(), _no_cost(), trace)
    assert_equal(len(trace.candidates), 18)
    var best = 0
    for i in range(1, len(trace.candidates)):
        if trace.candidates[i].cost < trace.candidates[best].cost:
            best = i
    var kept = trace.entry_for(UInt64(15)).value().copy()
    assert_equal(kept.best_left.bits, trace.candidates[best].left_set_bits)
    assert_equal(kept.best_right.bits, trace.candidates[best].right_set_bits)
    assert_equal(kept.cost, trace.candidates[best].cost)


# =============================================================================
# Passes: the cross-product pass and the iteration cap
# =============================================================================


def test_cross_pass_is_a_second_report() raises:
    """Components {0,1} and {2,3}: the literal-edge pass (2 emits)
    completes without a full-set entry, the cross-product pass runs on the
    complete graph (40 emits) and its 18 full-set candidates carry
    `allow_cross`; the table handed back is the cross pass's (it has the
    full set). Catches: the pass flag not passed to the observer, a
    candidate's `allow_cross` not set, and the first pass's table returned
    in place of the replayed one."""
    var trace = DPccpTrace(UInt64(15))
    _ = solve_dpccp_with_dp_trace(_chain(4, [0, 2], [1, 3]), _no_cost(), trace)
    assert_equal(len(trace.passes), 2)
    assert_false(trace.passes[0].allow_cross)
    assert_equal(trace.passes[0].emit_calls, UInt64(2))
    assert_true(trace.passes[0].completed)
    assert_true(trace.passes[1].allow_cross)
    assert_equal(trace.passes[1].emit_calls, UInt64(40))
    assert_equal(trace.passes[1].scored_pairs, 40)
    assert_true(trace.passes[1].completed)
    assert_equal(len(trace.candidates), 18)
    for i in range(len(trace.candidates)):
        assert_true(trace.candidates[i].allow_cross)
    assert_true(Bool(trace.entry_for(UInt64(15))))


def test_cross_pass_overflow_is_reported() raises:
    """Twelve relations and no edges: the first pass emits nothing and
    completes; the cross pass stops at the iteration cap (500,001 calls)
    and there is no plan. Catches: the overflow reported as a completed
    pass."""
    var trace = DPccpTrace(UInt64(1))
    var none_edges = List[Int]()
    var plan = solve_dpccp_with_dp_trace(
        _chain(DPCCP_MAX_RELATIONS, none_edges, none_edges), _no_cost(), trace
    )
    assert_false(Bool(plan))
    assert_equal(len(trace.passes), 2)
    assert_equal(trace.passes[0].emit_calls, UInt64(0))
    assert_true(trace.passes[0].completed)
    assert_false(trace.passes[1].completed)
    assert_equal(trace.passes[1].emit_calls, UInt64(500_001))


def _one_pass(chain: JoinChain, cap: Int, drop_bits: UInt64) raises -> DPccpTrace:
    """One literal-edge pass over `chain` (four relations) with iteration
    cap `cap`, the base relations seeded, then the entry `drop_bits`
    removed from the table (0: none)."""
    var nb = _build_neighbors(4, chain.edges)
    var dp = Dict[UInt64, DPNode]()
    _seed_dp_base_relations(4, chain, dp)
    if drop_bits != UInt64(0):
        _ = dp.pop(drop_bits)
    var counter = _IterCounter(UInt64(cap))
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var trace = DPccpTrace(UInt64(15))
    _ = _run_dpccp_passes(
        4, chain, nb, dp, counter, _no_cost(), none_tdom, cache, False, trace
    )
    return trace^


def _capped(cap: Int) raises -> DPccpTrace:
    return _one_pass(_k4(), cap, UInt64(0))


def test_pass_end_reports_each_overflow_return() raises:
    """K4 with cap 9 stops after the first enumerator (10 calls), cap 26
    after the csg extension (27 calls); both reports say not completed.
    Catches: either overflow return reporting `completed`, or reporting a
    count other than the counter's."""
    var t9 = _capped(9)
    assert_equal(len(t9.passes), 1)
    assert_equal(t9.passes[0].emit_calls, UInt64(10))
    assert_false(t9.passes[0].completed)
    var t26 = _capped(26)
    assert_equal(t26.passes[0].emit_calls, UInt64(27))
    assert_false(t26.passes[0].completed)


# =============================================================================
# The guards in emit_pair, and the reset
# =============================================================================


def test_refused_calls_count_as_emits_not_as_scored() raises:
    """Path 0-1-2-3, one pass over a table seeded without relation 3: the
    enumeration does not read the table, so the pass still makes its 10
    `emit_pair` calls, but every pair whose side contains relation 3 has
    no DP entry and is refused. Scored are {0}|{1}, {1}|{2}, {0}|{1,2}
    and {0,1}|{2}: 4 scored pairs, none of the full set, and the pass
    completes. Catches: the report's `emit_calls` read from anything but
    the iteration counter (the scored count would give 4), and a refused
    call reaching `on_pair_scored` (more than 4)."""
    var trace = _one_pass(_chain(4, [0, 1, 2], [1, 2, 3]), 500_000, _bits([3]))
    assert_equal(len(trace.passes), 1)
    assert_equal(trace.passes[0].emit_calls, UInt64(10))
    assert_equal(trace.passes[0].scored_pairs, 4)
    assert_true(trace.passes[0].completed)
    assert_equal(len(trace.candidates), 0)


def test_refused_pairs_are_not_scored() raises:
    """A pair with no DP entry on one side, and a pair with no edge
    outside a cross pass, are refused before the observer hears of them;
    the valid pair is scored. Catches: the hook moved above either
    guard."""
    var chain = _chain(3, [0], [1])
    var dp = Dict[UInt64, DPNode]()
    _seed_dp_base_relations(3, chain, dp)
    var missing = Dict[UInt64, DPNode]()
    missing[UInt64(1)] = DPNode(Float64(0.0), 10, RelationSet.empty(), RelationSet.empty())
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var trace = DPccpTrace(UInt64(3))
    trace.on_pass_begin(False)
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, missing,
        _no_cost(), none_tdom, cache, trace,
    )
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(2), chain, dp,
        _no_cost(), none_tdom, cache, trace,
    )
    assert_equal(trace.passes[0].scored_pairs, 0)
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, dp,
        _no_cost(), none_tdom, cache, trace,
    )
    assert_equal(trace.passes[0].scored_pairs, 1)
    assert_equal(len(trace.candidates), 1)


def test_each_solve_starts_from_an_empty_trace() raises:
    """K4 traced twice into one trace still reads 18 candidates and one
    pass; then a one-relation chain (not enumerated) leaves the trace
    empty and returns no plan, as does a chain over the relation bound.
    Catches: the reset dropped (36 candidates, two passes) and a stale
    table surviving a solve that does not enumerate."""
    var trace = DPccpTrace(UInt64(15))
    _ = solve_dpccp_with_dp_trace(_k4(), _no_cost(), trace)
    _ = solve_dpccp_with_dp_trace(_k4(), _no_cost(), trace)
    assert_equal(len(trace.candidates), 18)
    assert_equal(len(trace.passes), 1)
    var none_edges = List[Int]()
    assert_false(Bool(solve_dpccp_with_dp_trace(_chain(1, none_edges, none_edges), _no_cost(), trace)))
    assert_equal(len(trace.candidates), 0)
    assert_equal(len(trace.passes), 0)
    assert_equal(len(trace.dp), 0)
    _ = solve_dpccp_with_dp_trace(_k4(), _no_cost(), trace)
    assert_false(Bool(solve_dpccp_with_dp_trace(
        _chain(DPCCP_MAX_RELATIONS + 1, none_edges, none_edges), _no_cost(), trace
    )))
    assert_equal(len(trace.dp), 0)


def test_observed_solve_clears_the_table_it_is_handed() raises:
    """`solve_dpccp_observed` handed a table holding a stale entry: a
    one-relation chain (not enumerated) returns it empty, and a K4 solve
    returns the 15 subsets of its own table without the stale key 1 << 20.
    Catches: the clear at entry dropped (a stale entry would survive and
    could steer the reconstruction)."""
    var none_edges = List[Int]()
    var stale = DPNode(Float64(0.0), 1, RelationSet.empty(), RelationSet.empty())
    var dp = Dict[UInt64, DPNode]()
    dp[UInt64(1) << UInt64(20)] = stale.copy()
    var trace = DPccpTrace(UInt64(15))
    assert_false(Bool(solve_dpccp_observed(
        _chain(1, none_edges, none_edges), _no_cost(), dp, trace
    )))
    assert_equal(len(dp), 0)
    dp[UInt64(1) << UInt64(20)] = stale.copy()
    assert_true(Bool(solve_dpccp_observed(_k4(), _no_cost(), dp, trace)))
    assert_equal(len(dp), 15)
    assert_false(Bool(dp.get(UInt64(1) << UInt64(20))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
