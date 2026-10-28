# =============================================================================
# test_optimizer_dpccp_tie_order -- the total order on DP join candidates
# (`optimizer_cost_order.dp_pair_beats`) and DPccp's use of it
# =============================================================================
#
# Two candidates for one relation set can have the same Float64 cost. The
# order breaks that tie on the relation-set bits, so the join tree chosen does
# not depend on which candidate the enumerator emitted first. The unit tests
# call the order directly, in both argument orders; the solver test builds a
# four-cycle whose two cheapest decompositions tie, with the higher-bits one
# emitted first.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.collections import Dict

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_JOIN, PLAN_SCAN, SOURCE_PARQUET
from komira_optimizer.optimizer_reorder import JoinRelation, JoinEdge, JoinChain
from komira_optimizer.optimizer_dpccp import solve_dpccp_with_cost
from komira_optimizer.optimizer_cost_order import dp_pair_beats


# -----------------------------------------------------------------------------
# The order itself
# -----------------------------------------------------------------------------


def test_lower_cost_wins_whatever_the_bits() raises:
    """A strictly cheaper candidate replaces the entry even with higher bits;
    a strictly dearer one does not even with lower bits.

    Defect caught: a tie-break consulted before the cost (bits decide every
    comparison)."""
    assert_true(dp_pair_beats(99.0, 9, 6, 100.0, 3, 12))
    assert_false(dp_pair_beats(101.0, 3, 12, 100.0, 9, 6))


def test_equal_cost_lower_left_bits_wins_in_both_orders() raises:
    """At an equal cost, `({0,1}, {2,3})` (left bits 3) beats
    `({0,3}, {1,2})` (left bits 9) whichever is the incumbent.

    Defect caught: the first candidate keeping the entry on a tie (strict
    `<` on cost alone), or the tie broken towards the higher bits."""
    assert_true(dp_pair_beats(205.0, 3, 12, 205.0, 9, 6))
    assert_false(dp_pair_beats(205.0, 9, 6, 205.0, 3, 12))


def test_equal_cost_and_left_bits_falls_to_right_bits() raises:
    """With the cost and the left bits equal, the lower right bits win, and
    the same candidate does not beat itself.

    Defect caught: the last comparison dropped (an equal-left tie keeps the
    incumbent regardless) or made non-strict (a candidate replaces its own
    entry)."""
    assert_true(dp_pair_beats(7.0, 1, 2, 7.0, 1, 6))
    assert_false(dp_pair_beats(7.0, 1, 6, 7.0, 1, 2))
    assert_false(dp_pair_beats(7.0, 1, 2, 7.0, 1, 2))


def test_nan_cost_is_a_tie_not_a_winner() raises:
    """A NaN cost compares neither lower nor higher, so the bits decide.

    Defect caught: a NaN that wins (or loses) every comparison, which would
    make the result depend on where the NaN sits in the emission order."""
    var nan = Float64(0.0) / Float64(0.0)
    assert_true(dp_pair_beats(nan, 3, 12, 205.0, 9, 6))
    assert_false(dp_pair_beats(nan, 9, 6, 205.0, 3, 12))


# -----------------------------------------------------------------------------
# DPccp uses it
# -----------------------------------------------------------------------------


def _scan(path: String, key: String) -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(key, ArrowType.INT64, False))
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(path, SOURCE_PARQUET, b.build(), none_proj^, none_filt^, Optional[Int](1000))


def _edge(l: Int, r: Int) -> JoinEdge:
    var lk = List[String]()
    lk.append("k" + String(l))
    var rk = List[String]()
    rk.append("k" + String(r))
    return JoinEdge(l, r, lk^, rk^)


def _four_cycle() -> JoinChain:
    """r0 - r1 - r2 - r3 - r0, every relation 1000 rows."""
    var chain = JoinChain()
    for i in range(4):
        chain.relations.append(JoinRelation(i, _scan("r" + String(i), "k" + String(i)), 1000))
    chain.edges.append(_edge(0, 1))
    chain.edges.append(_edge(1, 2))
    chain.edges.append(_edge(2, 3))
    chain.edges.append(_edge(0, 3))
    return chain^


def _bits(ids: List[Int]) -> UInt64:
    var out = UInt64(0)
    for i in range(len(ids)):
        out |= UInt64(1) << UInt64(ids[i])
    return out


def _shape(p: LogicalPlan) -> String:
    """Join tree as nested parentheses over scan paths: `((r0,r3),(r1,r2))`."""
    if p.tag == PLAN_SCAN:
        return p._scan.value()[].source_path
    if p.tag == PLAN_JOIN:
        return "(" + _shape(p._join.value()[].left[]) + "," + _shape(p._join.value()[].right[]) + ")"
    return "?"


def test_dpccp_breaks_an_equal_cost_tie_on_relation_bits() raises:
    """Injected join cardinalities make the two cheapest decompositions of
    the full set tie at cost 5 + 100:

        ({0,1,3}, {2}): 5 + cost({0,1,3}) = 5 + (50 + 50)
        ({0,3}, {1,2}): 5 + 50 + 50

    and every other decomposition costs 5 + 1,050. The enumerator emits
    `({0,1,3}, {2})` first (it grows the csg {0,1} before it reaches {0,3}).
    The order picks left bits 9 (`{0,3}`) over 11 (`{0,1,3}`): the bushy
    tree `((r0,r3),(r1,r2))`.

    Defect caught: `emit_pair` keeping the first-emitted candidate on a tie,
    which answers `(((r0,r1),r3),r2)` and changes when the enumeration order
    does (komira-ai/komira#1176)."""
    var cost = Dict[UInt64, Int]()
    cost[_bits([0, 1])] = 50
    cost[_bits([0, 3])] = 50
    cost[_bits([1, 2])] = 50
    cost[_bits([2, 3])] = 1000
    cost[_bits([0, 1, 3])] = 50
    cost[_bits([0, 1, 2])] = 1000
    cost[_bits([1, 2, 3])] = 1000
    cost[_bits([0, 2, 3])] = 1000
    cost[_bits([0, 1, 2, 3])] = 5
    var result = solve_dpccp_with_cost(_four_cycle(), cost)
    assert_true(Bool(result), "the four-cycle must yield a plan")
    var plan = result.take()
    assert_equal(_shape(plan), "((r0,r3),(r1,r2))")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
