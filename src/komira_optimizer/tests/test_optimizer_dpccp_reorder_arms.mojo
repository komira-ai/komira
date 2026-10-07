# =============================================================================
# optimizer_dpccp: the CROSS guards, the output-schema restore, the
# name-collision barrier and every arm of reorder_joins_with_dp
# =============================================================================
#
# test_q5_plan_shape drives `reorder_joins_with_dp` on one Q5-shaped INNER
# chain. This file reaches the rest of the driver: the greedy arm (short
# chains, and DPccp giving up on an iteration-capped clique), a keyless
# INNER join the extractor declines, the name-collision, residual and
# outer-join barriers, the seven single-child arms and a bare scan; the
# reorder fire counter on each arm; both synthesized-CROSS walks on every
# node kind; each verdict of `_restore_chain_output_schema`; and the
# chain-wide collision test through pierced projections and nested joins.
#
# Plans are compared by their leaf order: `_leaves` lists the first column
# name of every leaf, left to right, through joins and single-child nodes.
# Each test names the defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_GT, BIN_LT
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_ALGO_HASH,
)
from komira_async.runtime.sched_trace import (
    join_reorder_fire_count,
    join_reorder_fire_reset,
)
from komira_optimizer.optimizer_dpccp import (
    _plan_has_synthesized_cross,
    _plan_top_join_is_synthesized_cross,
    _restore_chain_output_schema,
    _chain_relations_share_column_name,
    reorder_joins_with_dp,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema(names: List[String]) -> Schema:
    var b = SchemaBuilder()
    for i in range(len(names)):
        b.add_field(Field(names[i], ArrowType.INT64, False))
    return b.build()


def _one(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _scan_cols(path: String, names: List[String], rows: Int = 10) -> LogicalPlan:
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc: Optional[Int] = rows
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names), proj^, filt^, rc^)


def _scan(name: String, rows: Int = 10) -> LogicalPlan:
    """One INT64 column `name`, `rows` rows."""
    return _scan_cols(name + ".parquet", _one(name), rows)


def _inner(var l: LogicalPlan, var r: LogicalPlan, lk: String, rk: String) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _one(lk), _one(rk), JOIN_INNER)


def _keyless(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, List[String](), List[String](), JOIN_INNER)


def _wrap(kind: Int, col: String, var child: LogicalPlan) -> LogicalPlan:
    """Kind 0..6: Filter, Project, Aggregate, Sort, Limit, Distinct, TopN
    over `child`, each naming column `col`."""
    if kind == 0:
        var pred = Expr.binary(BIN_GT, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(5)))
        return LogicalPlan.filter(pred^, child^)
    if kind == 1:
        var e = ExprArray()
        e.append(Expr.col_ref(col))
        return LogicalPlan.project(e^, child^)
    if kind == 2:
        var keys = ExprArray()
        keys.append(Expr.col_ref(col))
        var aggs = AggExprArray()
        var none_child: Optional[Expr] = None
        aggs.append(AggExpr(AGG_COUNT, none_child^, Optional[String](String("n"))))
        return LogicalPlan.aggregate(keys^, aggs^, child^)
    var desc = List[Bool]()
    desc.append(False)
    if kind == 3:
        return LogicalPlan.sort(_one(col), desc^, child^)
    if kind == 4:
        return LogicalPlan.limit(5, child^)
    if kind == 5:
        var none_cols: Optional[List[String]] = None
        return LogicalPlan.distinct(none_cols^, child^)
    return LogicalPlan.topn(_one(col), desc^, 5, child^)


def _wrap_tags() -> List[UInt8]:
    var tags = List[UInt8]()
    tags.append(PLAN_FILTER)
    tags.append(PLAN_PROJECT)
    tags.append(PLAN_AGGREGATE)
    tags.append(PLAN_SORT)
    tags.append(PLAN_LIMIT)
    tags.append(PLAN_DISTINCT)
    tags.append(PLAN_TOPN)
    return tags^


def _leaves(plan: LogicalPlan, mut out: List[String]):
    if plan.tag == PLAN_JOIN:
        _leaves(plan.join_data_ref().left[], out)
        _leaves(plan.join_data_ref().right[], out)
    elif plan.tag == PLAN_FILTER:
        _leaves(plan.filter_data_ref().child[], out)
    elif plan.tag == PLAN_PROJECT:
        _leaves(plan.project_data_ref().child[], out)
    elif plan.tag == PLAN_AGGREGATE:
        _leaves(plan.aggregate_data_ref().child[], out)
    elif plan.tag == PLAN_SORT:
        _leaves(plan.sort_data_ref().child[], out)
    elif plan.tag == PLAN_LIMIT:
        _leaves(plan.limit_data_ref().child[], out)
    elif plan.tag == PLAN_DISTINCT:
        _leaves(plan.distinct_data_ref().child[], out)
    elif plan.tag == PLAN_TOPN:
        _leaves(plan.topn_data_ref().child[], out)
    else:
        out.append(plan.output_schema.field_name(0))


def _order(plan: LogicalPlan) -> String:
    """The leaf order as one string, e.g. "b,c,a"."""
    var out = List[String]()
    _leaves(plan, out)
    var s = String("")
    for i in range(len(out)):
        if i > 0:
            s += ","
        s += out[i]
    return s


def _names(plan: LogicalPlan) -> String:
    var s = String("")
    for i in range(plan.output_schema.num_columns()):
        if i > 0:
            s += ","
        s += plan.output_schema.field_name(i)
    return s


def _path(plan: LogicalPlan) -> String:
    return String(plan._scan.value()[].source_path)


def _chain3() -> LogicalPlan:
    """(A(1000) JOIN B(10) ON a = b) JOIN C(100) ON b = c. Three relations
    is below the DPccp minimum, so greedy orders it: B, then C, then A."""
    return _inner(_inner(_scan("a", 1000), _scan("b", 10), "a", "b"), _scan("c", 100), "b", "c")


def _chain(n: Int) -> LogicalPlan:
    """A left-deep INNER chain over k0..k{n-1}, each step k{i-1} = k{i}."""
    var acc = _scan("k0")
    for i in range(1, n):
        acc = _inner(acc^, _scan("k" + String(i)), "k" + String(i - 1), "k" + String(i))
    return acc^


# =============================================================================
# _plan_has_synthesized_cross / _plan_top_join_is_synthesized_cross
# =============================================================================


def test_synthesized_cross_walk_reaches_every_node_kind() raises:
    """A keyless join is found at the root, under either side of a keyed
    join, and under each of the seven single-child nodes; keyed plans,
    scans and payload-less nodes are clean; a join whose right key list
    alone is empty counts. Catches: any arm of the walk removed."""
    assert_true(_plan_has_synthesized_cross(_keyless(_scan("a"), _scan("b"))))
    assert_false(_plan_has_synthesized_cross(_inner(_scan("a"), _scan("b"), "a", "b")))
    assert_true(_plan_has_synthesized_cross(
        _inner(_keyless(_scan("a"), _scan("b")), _scan("c"), "a", "c")
    ))
    assert_true(_plan_has_synthesized_cross(
        _inner(_scan("c"), _keyless(_scan("a"), _scan("b")), "c", "a")
    ))
    var tags = _wrap_tags()
    for k in range(7):
        assert_true(_plan_has_synthesized_cross(_wrap(k, "a", _keyless(_scan("a"), _scan("b")))))
        assert_false(_plan_has_synthesized_cross(_wrap(k, "a", _scan("a"))))
        assert_false(_plan_has_synthesized_cross(LogicalPlan(tags[k], _schema(_one("a")))))
    assert_false(_plan_has_synthesized_cross(LogicalPlan(PLAN_JOIN, _schema(_one("a")))))
    assert_false(_plan_has_synthesized_cross(_scan("a")))
    var lopsided = _inner(_scan("a"), _scan("b"), "a", "b")
    lopsided._join.value()[].right_on = List[String]()
    assert_true(_plan_has_synthesized_cross(lopsided))


def test_top_join_cross_looks_only_at_the_root_join() raises:
    """True for a keyless root join, also under each single-child node; a
    keyed root join with a CROSS below it is accepted; scans and
    payload-less nodes are not crosses. Catches: the guard descending
    into join children (it would reject plans the fallback relies on) and
    any single-child arm removed."""
    assert_true(_plan_top_join_is_synthesized_cross(_keyless(_scan("a"), _scan("b"))))
    assert_false(_plan_top_join_is_synthesized_cross(
        _inner(_keyless(_scan("a"), _scan("b")), _scan("c"), "a", "c")
    ))
    var tags = _wrap_tags()
    for k in range(7):
        assert_true(_plan_top_join_is_synthesized_cross(
            _wrap(k, "a", _keyless(_scan("a"), _scan("b")))
        ))
        assert_false(_plan_top_join_is_synthesized_cross(
            _wrap(k, "a", _inner(_scan("a"), _scan("b"), "a", "b"))
        ))
        assert_false(_plan_top_join_is_synthesized_cross(LogicalPlan(tags[k], _schema(_one("a")))))
    assert_false(_plan_top_join_is_synthesized_cross(LogicalPlan(PLAN_JOIN, _schema(_one("a")))))
    assert_false(_plan_top_join_is_synthesized_cross(_scan("a")))
    var lopsided = _inner(_scan("a"), _scan("b"), "a", "b")
    lopsided._join.value()[].right_on = List[String]()
    assert_true(_plan_top_join_is_synthesized_cross(lopsided))


# =============================================================================
# _restore_chain_output_schema
# =============================================================================


def _restore(got: List[String], want: List[String]) raises -> LogicalPlan:
    """Restore over a reordered scan `x` (columns `got`) and an unreordered
    scan `y` (columns `want`)."""
    return _restore_chain_output_schema(_scan_cols("x", got), _scan_cols("y", want))


def test_restore_keeps_the_reorder_when_names_match_or_permute() raises:
    """Same names in order, and a permutation, return the reordered plan
    untouched (a permutation is `restore_join_reorder_output_columns`'s to
    restore).
    Catches: a Project added on the common path, and a permutation read as
    a refusal."""
    var same = _restore(["a", "b"], ["a", "b"])
    assert_equal(same.tag, PLAN_SCAN)
    assert_equal(_path(same), "x")
    var perm = _restore(["b", "a"], ["a", "b"])
    assert_equal(perm.tag, PLAN_SCAN)
    assert_equal(_path(perm), "x")


def test_restore_declines_a_same_width_non_permutation() raises:
    """[a, c] against [a, b]: same width, not a permutation, and b is
    absent, so the unreordered plan comes back. Catches: the multiset check
    removed (the reorder would be kept with the wrong columns)."""
    var out = _restore(["a", "c"], ["a", "b"])
    assert_equal(out.tag, PLAN_SCAN)
    assert_equal(_path(out), "y")


def test_restore_narrows_a_widened_reorder_by_name() raises:
    """[c, b, a] against [a, b]: a by-name Project([a, b]) over the reordered
    plan. Catches: the widening left in place (an extra column in the
    answer) and the projection built in the reordered order."""
    var out = _restore(["c", "b", "a"], ["a", "b"])
    assert_equal(out.tag, PLAN_PROJECT)
    assert_equal(_names(out), "a,b")
    assert_equal(_path(out.project_data_ref().child[]), "x")


def test_restore_declines_when_a_name_is_missing() raises:
    """[a, c, d] against [a, b]: b has no column to project, so the reorder
    is abandoned. Catches: the per-name hit check removed (a Project over a
    column that does not exist)."""
    var out = _restore(["a", "c", "d"], ["a", "b"])
    assert_equal(out.tag, PLAN_SCAN)
    assert_equal(_path(out), "y")


# =============================================================================
# _chain_relations_share_column_name
# =============================================================================


def test_chain_collision_through_nested_joins_and_pierced_projects() raises:
    """A and B share `v` directly, through a rename-free Project over their
    join, and two levels apart ((A JOIN B) JOIN C with A and C sharing);
    disjoint names do not collide. Catches: the nested-join descent or the
    Project pierce removed (the barrier would miss a collision the solver
    still sees)."""
    var ab = _inner(_scan_cols("A", ["a", "v"]), _scan_cols("B", ["b", "w"]), "a", "b")
    assert_false(_chain_relations_share_column_name(ab))
    var shared = _inner(_scan_cols("A", ["a", "v"]), _scan_cols("B", ["b", "v"]), "a", "b")
    assert_true(_chain_relations_share_column_name(shared))
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    e.append(Expr.col_ref("b"))
    var pierced = LogicalPlan.project(
        e^, _inner(_scan_cols("A", ["a", "v"]), _scan_cols("B", ["b", "v"]), "a", "b")
    )
    assert_true(_chain_relations_share_column_name(pierced))
    var deep = _inner(
        _inner(_scan_cols("A", ["a", "v"]), _scan_cols("B", ["b", "w"]), "a", "b"),
        _scan_cols("C", ["c", "v"]),
        "b",
        "c",
    )
    assert_true(_chain_relations_share_column_name(deep))


def test_chain_collision_treats_residual_and_outer_joins_as_leaves() raises:
    """A residual INNER join and a LEFT join are single relations, so their
    own operands' shared `v` is not a chain collision. Catches: the
    residual or join-type check removed from the descent."""
    var pred = Expr.binary(BIN_LT, Expr.left("a"), Expr.right("b"))
    var residual: Optional[OwnedPointer[Expr]] = OwnedPointer(pred^)
    var resid = LogicalPlan.join(
        _scan_cols("A", ["a", "v"]), _scan_cols("B", ["b", "v"]),
        List[String](), List[String](), JOIN_INNER,
        algo_hint=UInt8(0), residual=residual^,
    )
    assert_false(_chain_relations_share_column_name(resid))
    var left = LogicalPlan.join(
        _scan_cols("A", ["a", "v"]), _scan_cols("B", ["b", "v"]), _one("a"), _one("b"), JOIN_LEFT
    )
    assert_false(_chain_relations_share_column_name(left))


# =============================================================================
# reorder_joins_with_dp
# =============================================================================


def test_reorder_short_chain_goes_to_greedy_and_fires() raises:
    """Three relations: greedy orders B, C, A, and the permuted output is
    left as is (no Project). The driver reorders the inner (A JOIN B)
    first, so the fire counter moves once per INNER node: 2. Catches: the
    greedy arm removed, a Project added over a permutation, and the greedy
    arm's fire (the decision pin, read through komira_async's sched_trace)
    dropped."""
    join_reorder_fire_reset()
    var out = reorder_joins_with_dp(_chain3())
    assert_equal(_order(out), "b,c,a")
    assert_equal(out.tag, PLAN_JOIN)
    assert_equal(join_reorder_fire_count(), UInt64(2))


def test_reorder_four_chain_goes_to_dpccp_and_fires() raises:
    """Four relations with row counts: the two inner nodes (two and three
    relations) go to greedy, the root to DPccp; every leaf survives and the
    counter moves once per INNER node: 3. Catches: the DPccp arm's fire
    dropped (2) and a leaf lost in reconstruction."""
    join_reorder_fire_reset()
    var out = reorder_joins_with_dp(_chain(4))
    var leaves = List[String]()
    _leaves(out, leaves)
    assert_equal(len(leaves), 4)
    assert_equal(join_reorder_fire_count(), UInt64(3))


def _balanced(lo: Int, hi: Int) -> LogicalPlan:
    """A balanced INNER tree over k{lo}..k{hi-1}; the halves join on
    k{mid-1} = k{mid}, so every key is in one equivalence class."""
    if hi - lo == 1:
        return _scan("k" + String(lo))
    var mid = (lo + hi) // 2
    return _inner(
        _balanced(lo, mid), _balanced(mid, hi), "k" + String(mid - 1), "k" + String(mid)
    )


def test_reorder_falls_back_to_greedy_when_dpccp_gives_up() raises:
    """Twelve relations on one key class: at the root the derived
    transitive edges make a 12-clique, DPccp overflows its iteration cap
    and returns None, and the driver emits greedy's plan with all twelve
    leaves. (Balanced, so the inner nodes stay small.) Catches: the None
    from DPccp taken as a plan, and a leaf lost on the fallback."""
    var out = reorder_joins_with_dp(_balanced(0, 12))
    assert_equal(out.tag, PLAN_JOIN)
    var leaves = List[String]()
    _leaves(out, leaves)
    assert_equal(len(leaves), 12)


def test_reorder_keeps_a_keyless_inner_join() raises:
    """INNER(A(1000), B(10)) with no keys: the extractor declines and the
    rebuilt join returns as it was, without a fire. Catches: the declined
    path removed (greedy would seed B: b,a)."""
    join_reorder_fire_reset()
    var out = reorder_joins_with_dp(_keyless(_scan("a", 1000), _scan("b", 10)))
    assert_equal(_order(out), "a,b")
    assert_equal(join_reorder_fire_count(), UInt64(0))


def test_reorder_name_collision_is_a_barrier() raises:
    """A(1000) [a, v] JOIN B(10) [b, v]: the shared `v` makes the join a
    barrier, so greedy does not put B first. Catches: the collision
    barrier removed (b,a with `v` silently naming the other relation)."""
    join_reorder_fire_reset()
    var j = _inner(_scan_cols("A", ["a", "v"], 1000), _scan_cols("B", ["b", "v"], 10), "a", "b")
    var out = reorder_joins_with_dp(j^)
    assert_equal(_order(out), "a,b")
    assert_equal(join_reorder_fire_count(), UInt64(0))


def test_reorder_outer_and_residual_joins_are_barriers() raises:
    """LEFT(chain, D) with a HASH hint and INNER(chain, D) with a residual:
    the chain under each is reordered, D stays on the right, and the join
    type, hint and residual survive. Catches: an outer or residual join
    pulled into the chain, and the hint or residual dropped in the
    rebuild."""
    var left = LogicalPlan.join(
        _chain3(), _scan("d", 1), _one("a"), _one("d"), JOIN_LEFT, JOIN_ALGO_HASH
    )
    var out = reorder_joins_with_dp(left^)
    assert_equal(_order(out), "b,c,a,d")
    assert_equal(out.join_data_ref().join_type, JOIN_LEFT)
    assert_equal(out.join_data_ref().algo_hint, JOIN_ALGO_HASH)
    assert_false(out.join_data_ref().has_residual())
    var pred = Expr.binary(BIN_LT, Expr.left("a"), Expr.right("d"))
    var residual: Optional[OwnedPointer[Expr]] = OwnedPointer(pred^)
    var resid = LogicalPlan.join(
        _chain3(), _scan("d", 1), List[String](), List[String](), JOIN_INNER,
        algo_hint=UInt8(0), residual=residual^,
    )
    var out2 = reorder_joins_with_dp(resid^)
    assert_equal(_order(out2), "b,c,a,d")
    assert_equal(out2.join_data_ref().join_type, JOIN_INNER)
    assert_true(out2.join_data_ref().has_residual())


def test_reorder_descends_every_single_child_node() raises:
    """Filter, Project, Aggregate, Sort, Limit, Distinct and TopN over the
    chain: each keeps its tag and its child is reordered; a bare scan is
    returned as is. Catches: any of the seven arms removed (that child
    would keep a,b,c) and the leaf fall-through changing a scan."""
    var tags = _wrap_tags()
    for k in range(7):
        var out = reorder_joins_with_dp(_wrap(k, "a", _chain3()))
        assert_equal(out.tag, tags[k])
        assert_equal(_order(out), "b,c,a")
    var scan = reorder_joins_with_dp(_scan("a"))
    assert_equal(scan.tag, PLAN_SCAN)
    assert_equal(_order(scan), "a")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
