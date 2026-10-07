# =============================================================================
# Tests for DPccp row_count-only fallback
# =============================================================================
#
# The row-count fallback relaxes the
# `should_use_dpccp` activation gate to accept chains where AT LEAST ONE
# relation has either:
#   (a) writer-emitted `table_stats` (legacy NDV-aware path), OR
#   (b) a populated `row_count` on its underlying scan
#       (the fallback — a scan with a row count and no `table_stats`).
#
# Without a TDOM graph, `_cost_for_pair` synthesizes a row-count-only
# TableStats with `(NUM/DEN) * row_count` as the per-key NDV estimate;
# `solve_dpccp` always builds a TDOM graph and prices pairs through it.
#
# This file complements `test_optimizer_dpccp.mojo`; it focuses on the
# row-count fallback contract:
#   1. Activation: chain with row_count only (no NDV) → DPccp activates.
#   2. Activation: chain with NEITHER row_count NOR NDV → falls back to
#      greedy. The "genuinely no data" case must keep the greedy path.
#   3. Solve: row-count-only chains yield complete plans (every leaf,
#      n-1 joins); the join order is not asserted.
#   4. Constants: the ratio is pinned at NUM=1, DEN=10.
#   5. The general DPccp cases live in `test_optimizer_dpccp.mojo` and
#      are not duplicated here.
#
# Limits (of the gate and of its row-count fallback):
#   - DPccp must NOT activate on truly-no-stats plans (no relation has
#     `table_stats` and no scan carries a row count).
#   - Existing 1-rel / 2-rel / 3-rel rejections still hold (the fallback
#     does NOT lower `DPCCP_MIN_RELATIONS`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_CSV,
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
    DPCCP_MIN_RELATIONS,
    DPCCP_MAX_RELATIONS,
    ESTIMATED_DISTINCT_RATIO_NUM,
    ESTIMATED_DISTINCT_RATIO_DEN,
    should_use_dpccp,
    solve_dpccp,
)


# =============================================================================
# Test helpers
# =============================================================================


def _single_int_schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan_with_row_count(path: String, key: String, n: Int) -> LogicalPlan:
    """Parquet scan with row_count populated, NO table_stats.

    Models a scan with a row count and no column statistics.
    """
    var s = _single_int_schema(key)
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, s^, none_proj^, none_filt^, rc^
    )


def _scan_without_row_count(path: String, key: String) -> LogicalPlan:
    """Parquet scan with NO row_count and NO table_stats.

    Models the "genuinely no data" case: a plan built via
    `LogicalPlan.scan(...)` with no row count. The row-count activation gate must REJECT
    chains where every relation looks like this.
    """
    var s = _single_int_schema(key)
    var none_rc: Optional[Int] = None
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, s^, none_proj^, none_filt^, none_rc^
    )


def _table_stats_single_key(key: String, ndv: Int, row_count: Int) -> TableStats:
    """Build a TableStats with one key's NDV signal."""
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


def _build_chain_row_count_only(
    cards: List[Int]
) -> JoinChain:
    """Build a linear chain of len(cards) relations.

    Each relation has `row_count` populated (no `table_stats`). Edge i
    connects relation i and relation i+1 on key "k{i}".
    """
    var chain = JoinChain()
    var n = len(cards)
    for i in range(n):
        var key = "k" + String(i)
        var plan = _scan_with_row_count(
            "r" + String(i) + ".parquet", key, cards[i]
        )
        chain.relations.append(JoinRelation(i, plan^, cards[i]))
    for i in range(n - 1):
        var lk = List[String]()
        lk.append("k" + String(i))
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(i, i + 1, lk^, rk^))
    return chain^


def _build_chain_no_signal(n: Int, base_card: Int) -> JoinChain:
    """Build a linear chain where NO relation has row_count or NDV.

    `cardinality` on the JoinRelation still gets a default value
    because callers must pass a number, but the underlying scan plan
    has `row_count=None` so `_leaf_has_row_count` returns False.
    """
    var chain = JoinChain()
    for i in range(n):
        var key = "k" + String(i)
        var plan = _scan_without_row_count(
            "r" + String(i) + ".parquet", key
        )
        chain.relations.append(JoinRelation(i, plan^, base_card))
    for i in range(n - 1):
        var lk = List[String]()
        lk.append("k" + String(i))
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(i, i + 1, lk^, rk^))
    return chain^


def _count_scans(plan: LogicalPlan) -> Int:
    if plan.tag == PLAN_SCAN:
        return 1
    if plan.tag == PLAN_JOIN:
        return (
            _count_scans(plan.join_data_ref().left[])
            + _count_scans(plan.join_data_ref().right[])
        )
    return 0


def _count_joins(plan: LogicalPlan) -> Int:
    if plan.tag != PLAN_JOIN:
        return 0
    var c = 1
    c += _count_joins(plan.join_data_ref().left[])
    c += _count_joins(plan.join_data_ref().right[])
    return c


# =============================================================================
# Activation tests
# =============================================================================


def test_activates_on_4rel_chain_with_row_count_only() raises:
    """The row-count fallback headline contract: 4-relation chain with row_count
    populated on every leaf, no table_stats anywhere → should_use_dpccp
    returns True.

    Without the fallback such a chain fell through to greedy
    unconditionally; the fallback lets it reach DPccp's enumerator.
    """
    var cards: List[Int] = [1000, 200, 5000, 50]
    var chain = _build_chain_row_count_only(cards)
    assert_true(
        should_use_dpccp(chain^),
        "row-count fallback: 4-rel chain with row_count → DPccp activates",
    )


def test_activates_on_6rel_chain_with_row_count_only() raises:
    """6-relation linear chain with Q7-like cardinalities.

    Six relations, asymmetric cardinalities, row_count only; the test
    asserts that the gate opens.
    """
    var cards: List[Int] = [6000000, 400, 25, 1500000, 30000, 25]
    var chain = _build_chain_row_count_only(cards)
    assert_true(
        should_use_dpccp(chain^),
        "row-count fallback: 6-rel chain with Q7-like cardinalities → DPccp activates",
    )


def test_rejects_chain_with_no_row_count_no_ndv() raises:
    """4-relation chain where NO leaf has row_count and NO leaf has
    NDV stats → falls back to greedy.

    The "genuinely no data" case of the fallback's design: with
    neither signal on any leaf, `should_use_dpccp` returns False and the
    chain goes to greedy.
    """
    var chain = _build_chain_no_signal(4, 1000)
    assert_false(
        should_use_dpccp(chain^),
        "no row_count + no NDV → DPccp must NOT activate",
    )


def test_rejects_chain_with_no_signal_at_max_size() raises:
    """A larger no-signal chain still rejects. Tests that the size-bounds
    check does not accidentally short-circuit the no-signal check.
    """
    var chain = _build_chain_no_signal(DPCCP_MAX_RELATIONS, 1000)
    assert_false(
        should_use_dpccp(chain^),
        "12-rel no-signal chain → DPccp must NOT activate",
    )


def test_rejects_3rel_even_with_row_count() raises:
    """3-relation chain with row_count populated still rejected.

    The fallback does NOT lower DPCCP_MIN_RELATIONS. A 3-rel chain has only
    2 valid orderings; greedy converges immediately.
    """
    var chain = _build_chain_row_count_only([1000, 200, 5000])
    assert_false(
        should_use_dpccp(chain^),
        "row-count fallback does NOT relax DPCCP_MIN_RELATIONS",
    )


def test_rejects_oversize_chain_even_with_row_count() raises:
    """n > DPCCP_MAX_RELATIONS still rejected. The fallback does NOT raise the
    upper bound.
    """
    var n = DPCCP_MAX_RELATIONS + 1
    var cards = List[Int]()
    for i in range(n):
        cards.append(100 + i)
    var chain = _build_chain_row_count_only(cards)
    assert_false(
        should_use_dpccp(chain^),
        "row-count fallback does NOT raise DPCCP_MAX_RELATIONS",
    )


def test_mixed_chain_one_relation_has_row_count() raises:
    """4-rel chain where only ONE relation has row_count and the others
    have neither → activates.

    The contract is "at least one relation carries signal", and
    `_leaf_has_row_count` walks each leaf independently. A single
    populated row_count is sufficient for activation.
    """
    var chain = JoinChain()
    var n = 4
    var key0 = "k0"
    chain.relations.append(JoinRelation(
        0, _scan_with_row_count("r0.parquet", key0, 1000)^, 1000
    ))
    for i in range(1, n):
        var key = "k" + String(i)
        chain.relations.append(JoinRelation(
            i,
            _scan_without_row_count("r" + String(i) + ".parquet", key)^,
            1000,
        ))
    for i in range(n - 1):
        var lk = List[String]()
        lk.append("k" + String(i))
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(i, i + 1, lk^, rk^))

    assert_true(
        should_use_dpccp(chain^),
        "1-leaf-with-row_count → DPccp activates",
    )


# =============================================================================
# Cost model tests (row_count-only fallback produces sensible ordering)
# =============================================================================


def test_solve_dpccp_produces_plan_on_row_count_only_chain() raises:
    """End-to-end: solve_dpccp on a 4-rel row-count-only chain returns
    a complete LogicalPlan with all leaves preserved.

    This exercises the cost model and reconstruction on a row-count-only
    chain (`solve_dpccp` does not consult the gate). The exact join
    order is not asserted, but
    the plan MUST be structurally complete: 4 scans, 3 join nodes.
    """
    var cards: List[Int] = [1000, 200, 5000, 50]
    var chain = _build_chain_row_count_only(cards)
    var result = solve_dpccp(chain^)
    assert_true(
        Bool(result),
        "row-count fallback: row_count-only chain must yield a plan",
    )
    var plan = result.take()
    assert_equal(_count_scans(plan), 4, "must preserve all leaves")
    assert_equal(_count_joins(plan), 3, "4-way plan needs 3 joins")


def test_solve_dpccp_produces_plan_on_6rel_q7_shape() raises:
    """6-rel chain with Q7-like cardinalities, end to end. The 6M lineitem leaf is the
    largest; the 25-row nation leaves are the smallest. The plan must
    be complete (6 scans, 5 joins) regardless of exact order.
    """
    var cards: List[Int] = [6000000, 400, 25, 1500000, 30000, 25]
    var chain = _build_chain_row_count_only(cards)
    var result = solve_dpccp(chain^)
    assert_true(
        Bool(result),
        "row-count fallback: 6-rel Q7-like chain must yield a plan",
    )
    var plan = result.take()
    assert_equal(_count_scans(plan), 6, "6-rel chain preserves 6 leaves")
    assert_equal(_count_joins(plan), 5, "6-way plan needs 5 joins")


# =============================================================================
# Constant-shape tests
# =============================================================================


def test_estimated_distinct_ratio_constants_published() raises:
    """The row-count fallback ratio is `1/10`. Pins both constants so a
    change to either fails here (a change to DEN would scale every
    row-count fallback estimate).
    """
    assert_equal(ESTIMATED_DISTINCT_RATIO_NUM, 1)
    assert_equal(ESTIMATED_DISTINCT_RATIO_DEN, 10)


# =============================================================================
# Mixed-source case
# =============================================================================


def test_mixed_chain_table_stats_takes_priority_over_row_count() raises:
    """Chain where one relation has explicit `table_stats` (the legacy
    path) and the rest have only `row_count`. Activation gate fires on
    EITHER signal.

    Asserts only that the gate opens; it does not observe which signal
    `should_use_dpccp` checks first. On `_cost_for_pair`'s no-TDOM path a
    relation's `table_stats` is used when present, and NDV is synthesized
    from `row_count` only when it is absent.
    """
    var chain = JoinChain()
    var n = 4
    var key0 = "k0"
    var ts0: Optional[TableStats] = Optional[TableStats](
        _table_stats_single_key(key0, 100, 1000)
    )
    chain.relations.append(JoinRelation(
        0, _scan_with_row_count("r0.parquet", key0, 1000)^, 1000, ts0^
    ))
    for i in range(1, n):
        var key = "k" + String(i)
        chain.relations.append(JoinRelation(
            i,
            _scan_with_row_count("r" + String(i) + ".parquet", key, 1000)^,
            1000,
        ))
    for i in range(n - 1):
        var lk = List[String]()
        lk.append("k" + String(i))
        var rk = List[String]()
        rk.append("k" + String(i))
        chain.edges.append(JoinEdge(i, i + 1, lk^, rk^))

    assert_true(
        should_use_dpccp(chain^),
        "table_stats + row_count → DPccp activates (either signal sufficient)",
    )


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
