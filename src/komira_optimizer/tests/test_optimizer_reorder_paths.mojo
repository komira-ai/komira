# =============================================================================
# optimizer_reorder: chain extraction paths, the greedy search and the
# reorder_joins entry point
# =============================================================================
#
# The welded reorder tests cover the per-column edge split and the
# leftover composite edge on two-leaf chains. This file reaches the other
# extraction paths (the three `extract_join_chain` refusals, Project
# piercing and its five refusals, residual joins and CROSS joins as leaves
# or flattened, the owner lookup of the leftover edge on each side, leaf
# stats found through a Filter or Project and capped by the post-filter
# card), the greedy search (seed, cheapest step, flipped keys, CROSS
# fallback, saturated product), and every arm of `reorder_joins`.
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
    JOIN_CROSS,
    JOIN_ALGO_HASH,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_optimizer.optimizer_reorder import (
    MAX_RELATIONS_FOR_REORDER,
    JoinChain,
    _is_rename_free_passthrough_project,
    _find_leaf_table_stats,
    extract_join_chain,
    greedy_join_order,
    reorder_joins,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema(var names: List[String]) -> Schema:
    var b = SchemaBuilder()
    for i in range(len(names)):
        b.add_field(Field(names[i], ArrowType.INT64, False))
    return b.build()


def _one(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _two(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _scan(name: String, n: Int) -> LogicalPlan:
    """One INT64 column `name`, `n` rows, no filter, no stats."""
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rows: Optional[Int] = Optional[Int](n)
    return LogicalPlan.scan(
        name + ".parquet", SOURCE_PARQUET, _schema(_one(name)), proj^, filt^, rows^
    )


def _scan_stats(name: String, n: Int, ndv: Int) -> LogicalPlan:
    """Like `_scan`, with table stats giving `name` an NDV of `ndv`."""
    var cols = List[ColumnStats]()
    cols.append(ColumnStats(Optional[Int](ndv)))
    var ts: Optional[TableStats] = Optional[TableStats](
        TableStats(n, _one(name), cols^, STATS_SOURCE_PARQUET_METADATA)
    )
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rows: Optional[Int] = Optional[Int](n)
    return LogicalPlan.scan(
        name + ".parquet", SOURCE_PARQUET, _schema(_one(name)), proj^, filt^, rows^, ts^
    )


def _inner(var l: LogicalPlan, var r: LogicalPlan, lk: String, rk: String) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, _one(lk), _one(rk), JOIN_INNER)


def _keyless(var l: LogicalPlan, var r: LogicalPlan, jt: UInt8) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, List[String](), List[String](), jt)


def _with_residual(
    var l: LogicalPlan, var r: LogicalPlan, jt: UInt8, lc: String, rc: String
) -> LogicalPlan:
    """A join carrying the residual `left.lc < right.rc` and no equi keys."""
    var pred = Expr.binary(BIN_LT, Expr.left(lc), Expr.right(rc))
    var residual: Optional[OwnedPointer[Expr]] = OwnedPointer(pred^)
    return LogicalPlan.join(
        l^, r^, List[String](), List[String](), jt,
        algo_hint=UInt8(0), residual=residual^,
    )


def _gt(name: String) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(5)))


def _project(var exprs: ExprArray, var child: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.project(exprs^, child^)


def _cols(a: String, b: String) -> ExprArray:
    var e = ExprArray()
    e.append(Expr.col_ref(a))
    e.append(Expr.col_ref(b))
    return e^


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


def _extract(var plan: LogicalPlan) raises -> JoinChain:
    """The chain of `plan`; raises when extraction declines."""
    var maybe = extract_join_chain(plan^)
    if not maybe:
        raise Error("extract_join_chain declined")
    return maybe.take()


def _chain3() -> LogicalPlan:
    """(A(1000) JOIN B(10) ON a = b) JOIN C(100) ON b = c, leaves a,b,c.
    Greedy seeds B, takes C (max(10, 100) = 100 beats 1000), then A."""
    return _inner(_inner(_scan("a", 1000), _scan("b", 10), "a", "b"), _scan("c", 100), "b", "c")


def _chain(n: Int) -> LogicalPlan:
    """A left-deep INNER chain over k0..k{n-1}, each step k{i-1} = k{i}."""
    var acc = _scan("k0", 10)
    for i in range(1, n):
        acc = _inner(acc^, _scan("k" + String(i), 10), "k" + String(i - 1), "k" + String(i))
    return acc^


# =============================================================================
# extract_join_chain refusals
# =============================================================================


def test_extract_refuses_a_single_relation() raises:
    """Catches: the `< 2 relations` guard removed (greedy would build a
    one-leaf "chain")."""
    assert_false(Bool(extract_join_chain(_scan("a", 10))))


def test_extract_refuses_a_chain_without_edges() raises:
    """A keyless INNER join gives two leaves and no edge. Catches: the
    `0 edges` guard removed (greedy would CROSS the two sides)."""
    assert_false(Bool(extract_join_chain(_keyless(_scan("a", 10), _scan("b", 10), JOIN_INNER))))


def test_extract_relation_limit_boundary() raises:
    """64 relations extract; 65 do not. Catches: the limit check made
    `>=` (64 refused) or removed (a 65th id overflows the 64-bit set)."""
    assert_equal(MAX_RELATIONS_FOR_REORDER, 64)
    var at_limit = extract_join_chain(_chain(64))
    assert_true(Bool(at_limit))
    assert_equal(len(at_limit.value().relations), 64)
    assert_false(Bool(extract_join_chain(_chain(65))))


# =============================================================================
# Project piercing
# =============================================================================


def test_rename_free_project_is_pierced() raises:
    """Project(x, a) over Scan(a, x) is a reorder of the scan's columns:
    the leaf is the Scan. Catches: piercing removed (the leaf would be
    the Project)."""
    var p = _project(_cols("x", "a"), LogicalPlan.scan("a.parquet", SOURCE_PARQUET, _schema(_two("a", "x"))))
    var maybe = extract_join_chain(_inner(p^, _scan("b", 10), "a", "b"))
    assert_true(Bool(maybe))
    var chain = maybe.take()
    assert_equal(len(chain.relations), 2)
    assert_equal(len(chain.edges), 1)
    assert_equal(chain.relations[0].plan[].tag, PLAN_SCAN)


def test_projects_that_must_not_be_pierced() raises:
    """A non-Project, an empty Project, an alias, a column the child
    lacks, and a duplicated column all refuse. Catches: any of the five
    refusals removed."""
    assert_false(_is_rename_free_passthrough_project(_scan("a", 10)))
    var empty = _project(ExprArray(), _scan("a", 10))
    assert_false(_is_rename_free_passthrough_project(empty))
    var alias_e = ExprArray()
    alias_e.append(Expr.col_ref("a").alias("a2"))
    var aliased = _project(alias_e^, _scan("a", 10))
    assert_false(_is_rename_free_passthrough_project(aliased))
    var missing = _project(_cols("a", "zz"), LogicalPlan.scan("a.parquet", SOURCE_PARQUET, _schema(_two("a", "x"))))
    assert_false(_is_rename_free_passthrough_project(missing))
    var dup = _project(_cols("a", "a"), LogicalPlan.scan("a.parquet", SOURCE_PARQUET, _schema(_two("a", "x"))))
    assert_false(_is_rename_free_passthrough_project(dup))
    var ok = _project(_cols("x", "a"), LogicalPlan.scan("a.parquet", SOURCE_PARQUET, _schema(_two("a", "x"))))
    assert_true(_is_rename_free_passthrough_project(ok))


# =============================================================================
# Residual and CROSS joins inside a chain
# =============================================================================


def test_residual_inner_join_is_one_leaf() raises:
    """(A JOIN B residual) JOIN C ON a = c: the residual join stays whole.
    Catches: a residual join flattened (3 leaves, residual lost)."""
    var r = _with_residual(_scan("a", 10), _scan("b", 10), JOIN_INNER, "a", "b")
    var chain = _extract(_inner(r^, _scan("c", 10), "a", "c"))
    assert_equal(len(chain.relations), 2)
    assert_equal(chain.relations[0].plan[].tag, PLAN_JOIN)
    assert_true(chain.relations[0].plan[].join_data_ref().has_residual())


def test_plain_cross_join_is_flattened() raises:
    """(A x C) JOIN B ON a = b: A and C become separate leaves, one edge
    A-B. Catches: CROSS kept as an opaque leaf (2 relations)."""
    var x = _keyless(_scan("a", 10), _scan("c", 10), JOIN_CROSS)
    var chain = _extract(_inner(x^, _scan("b", 10), "a", "b"))
    assert_equal(len(chain.relations), 3)
    assert_equal(len(chain.edges), 1)
    assert_equal(chain.edges[0].left_relation, 0)
    assert_equal(chain.edges[0].right_relation, 2)


def test_residual_cross_join_is_one_leaf() raises:
    """A CROSS join carrying a residual is not flattened. Catches: the
    `not has_residual()` test dropped from the CROSS arm."""
    var x = _with_residual(_scan("a", 10), _scan("c", 10), JOIN_CROSS, "a", "c")
    var chain = _extract(_inner(x^, _scan("b", 10), "a", "b"))
    assert_equal(len(chain.relations), 2)
    assert_equal(chain.relations[0].plan[].tag, PLAN_JOIN)


# =============================================================================
# Leftover edge: owner lookup on each side
# =============================================================================


def test_leftover_edge_uses_the_left_owner() raises:
    """(A JOIN B ON a = b) JOIN C ON b = zz: zz is in no leaf, so the key
    goes to the leftover edge; its left end is B (id 1, the owner of b),
    its right end falls back to C. Catches: the left owner ignored (the
    edge would start at A, id 0)."""
    var left = _inner(_scan("a", 10), _scan("b", 10), "a", "b")
    var chain = _extract(_inner(left^, _scan("c", 10), "b", "zz"))
    assert_equal(len(chain.edges), 2)
    assert_equal(chain.edges[1].left_relation, 1)
    assert_equal(chain.edges[1].right_relation, 2)


def test_leftover_edge_uses_the_right_owner() raises:
    """A JOIN (C JOIN D ON c = d) ON zz = d: the right end is D (id 2),
    the left end falls back to A. Catches: the right owner ignored (the
    edge would end at C, id 1)."""
    var right = _inner(_scan("c", 10), _scan("d", 10), "c", "d")
    var chain = _extract(_inner(_scan("a", 10), right^, "zz", "d"))
    assert_equal(len(chain.edges), 2)
    assert_equal(chain.edges[1].left_relation, 0)
    assert_equal(chain.edges[1].right_relation, 2)


# =============================================================================
# Leaf table stats
# =============================================================================


def test_leaf_stats_are_found_through_a_filter_and_capped() raises:
    """Filter(a > 5) over Scan(a: 1000 rows, NDV 1000) is a 300-row leaf;
    its stats come through the Filter with NDV(a) capped to 300. A leaf
    without stats has none. Catches: the Filter arm of the stats walk
    removed (no stats) and the NDV cap skipped (1000)."""
    var f = LogicalPlan.filter(_gt("a"), _scan_stats("a", 1000, 1000))
    var chain = _extract(_inner(f^, _scan("b", 50), "a", "b"))
    ref r0 = chain.relations[0]
    assert_equal(r0.cardinality, 300)
    assert_true(Bool(r0.table_stats))
    assert_equal(r0.table_stats.value().column_distinct_count("a").value(), 300)
    assert_false(Bool(chain.relations[1].table_stats))


def test_find_leaf_table_stats_shapes() raises:
    """Scan with stats and Project over it: found. Scan without stats,
    Aggregate over a stats scan, and nodes whose payload is unset: none.
    Catches: the Project arm removed, the walk continuing below an
    Aggregate, and an unset payload dereferenced."""
    assert_true(Bool(_find_leaf_table_stats(_scan_stats("a", 10, 5))))
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    var p = _project(e^, _scan_stats("a", 10, 5))
    assert_true(Bool(_find_leaf_table_stats(p)))
    assert_false(Bool(_find_leaf_table_stats(_scan("a", 10))))
    var keys = ExprArray()
    keys.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    var none_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_child^, Optional[String](String("n"))))
    var agg = LogicalPlan.aggregate(keys^, aggs^, _scan_stats("a", 10, 5))
    assert_false(Bool(_find_leaf_table_stats(agg)))
    assert_false(Bool(_find_leaf_table_stats(LogicalPlan(PLAN_SCAN, _schema(_one("a"))))))
    assert_false(Bool(_find_leaf_table_stats(LogicalPlan(PLAN_FILTER, _schema(_one("a"))))))
    assert_false(Bool(_find_leaf_table_stats(LogicalPlan(PLAN_PROJECT, _schema(_one("a"))))))


# =============================================================================
# greedy_join_order
# =============================================================================


def test_greedy_seeds_smallest_and_takes_cheapest_step() raises:
    """Chain a,b,c (cards 1000, 10, 100) becomes b,c,a; the last join's
    keys are flipped to b = a because the edge was written a = b.
    Catches: seeding by position (a first), taking the most expensive
    step (b,a,c), and unflipped keys."""
    var chain = _extract(_chain3())
    var out = greedy_join_order(chain^)
    assert_equal(_order(out), String("b,c,a"))
    ref top = out.join_data_ref()
    assert_equal(top.join_type, JOIN_INNER)
    assert_equal(top.left_on[0], String("b"))
    assert_equal(top.right_on[0], String("a"))


def test_greedy_cross_fallback_when_nothing_connects() raises:
    """(A(100) x C(5)) JOIN B(50) ON a = b: C seeds and connects to
    nothing, so the first step CROSSes C with A (position 0), then B
    joins on a = b. Catches: the fallback removed (no pick), and a
    keyless step emitted as an INNER join."""
    var x = _keyless(_scan("a", 100), _scan("c", 5), JOIN_CROSS)
    var chain = _extract(_inner(x^, _scan("b", 50), "a", "b"))
    var out = greedy_join_order(chain^)
    assert_equal(_order(out), String("c,a,b"))
    assert_equal(out.join_data_ref().join_type, JOIN_INNER)
    assert_equal(out.join_data_ref().left[].join_data_ref().join_type, JOIN_CROSS)


def test_greedy_cross_product_saturates() raises:
    """((D(2^33) x A(2^31)) x C(2^33)) JOIN B(2^33) ON d = b. A seeds and
    CROSSes D; 2^31 * 2^33 saturates to 2^62, so no step beats the
    initial best and the next pick is position 0 (C), then B: a,d,c,b.
    Catches: the saturation guard removed: the product wraps to 0, B's
    step costs 2^33 and is taken before C (a,d,b,c)."""
    var big = 1 << 33
    var dx = _keyless(_scan("d", big), _scan("a", 1 << 31), JOIN_CROSS)
    var dxc = _keyless(dx^, _scan("c", big), JOIN_CROSS)
    var chain = _extract(_inner(dxc^, _scan("b", big), "d", "b"))
    assert_equal(len(chain.relations), 4)
    var out = greedy_join_order(chain^)
    assert_equal(_order(out), String("a,d,c,b"))


# =============================================================================
# reorder_joins
# =============================================================================


def test_reorder_joins_reorders_an_inner_chain() raises:
    """Catches: the INNER arm not applying greedy (a,b,c kept)."""
    assert_equal(_order(reorder_joins(_chain3())), String("b,c,a"))


def _wrap(kind: Int, var child: LogicalPlan) -> LogicalPlan:
    if kind == 0:
        return LogicalPlan.filter(_gt("a"), child^)
    if kind == 1:
        var e = ExprArray()
        e.append(Expr.col_ref("a"))
        return LogicalPlan.project(e^, child^)
    if kind == 2:
        var keys = ExprArray()
        keys.append(Expr.col_ref("a"))
        var aggs = AggExprArray()
        var none_child: Optional[Expr] = None
        aggs.append(AggExpr(AGG_COUNT, none_child^, Optional[String](String("n"))))
        return LogicalPlan.aggregate(keys^, aggs^, child^)
    var desc = List[Bool]()
    desc.append(False)
    if kind == 3:
        return LogicalPlan.sort(_one("a"), desc^, child^)
    if kind == 4:
        return LogicalPlan.limit(5, child^)
    if kind == 5:
        var none_cols: Optional[List[String]] = None
        return LogicalPlan.distinct(none_cols^, child^)
    return LogicalPlan.topn(_one("a"), desc^, 5, child^)


def test_reorder_joins_descends_every_single_child_node() raises:
    """Filter, Project, Aggregate, Sort, Limit, Distinct and TopN over the
    chain: each keeps its tag and its child is reordered. Catches: any of
    the seven arms removed (that child would keep a,b,c)."""
    var tags = List[UInt8]()
    tags.append(PLAN_FILTER)
    tags.append(PLAN_PROJECT)
    tags.append(PLAN_AGGREGATE)
    tags.append(PLAN_SORT)
    tags.append(PLAN_LIMIT)
    tags.append(PLAN_DISTINCT)
    tags.append(PLAN_TOPN)
    for k in range(7):
        var out = reorder_joins(_wrap(k, _chain3()))
        assert_equal(out.tag, tags[k])
        assert_equal(_order(out), String("b,c,a"))


def test_reorder_joins_leaves_a_scan_alone() raises:
    """Catches: the leaf fall-through changing a scan."""
    var out = reorder_joins(_scan("a", 10))
    assert_equal(out.tag, PLAN_SCAN)
    assert_equal(_order(out), String("a"))


def test_reorder_joins_outer_join_is_a_barrier() raises:
    """LEFT(chain, D(1)) ON a = d with a HASH hint: the chain under it is
    reordered, D stays on the right, and type, keys and hint survive.
    Catches: a LEFT join pulled into the chain (D, the smallest, would
    seed it), and the hint dropped in the rebuild."""
    var j = LogicalPlan.join(
        _chain3(), _scan("d", 1), _one("a"), _one("d"), JOIN_LEFT, JOIN_ALGO_HASH
    )
    var out = reorder_joins(j^)
    assert_equal(_order(out), String("b,c,a,d"))
    ref jd = out.join_data_ref()
    assert_equal(jd.join_type, JOIN_LEFT)
    assert_equal(jd.algo_hint, JOIN_ALGO_HASH)
    assert_equal(jd.left_on[0], String("a"))
    assert_false(jd.has_residual())


def test_reorder_joins_keeps_a_residual() raises:
    """INNER(chain, D) with a residual is a barrier; the rebuilt join keeps
    its residual. Catches: the residual dropped in the rebuild, and a
    residual join flattened into the chain."""
    var j = _with_residual(_chain3(), _scan("d", 1), JOIN_INNER, "a", "d")
    var out = reorder_joins(j^)
    assert_equal(_order(out), String("b,c,a,d"))
    assert_equal(out.join_data_ref().join_type, JOIN_INNER)
    assert_true(out.join_data_ref().has_residual())


def test_reorder_joins_keeps_a_keyless_inner_join() raises:
    """INNER(A(1000), B(10)) with no keys: extraction declines and the
    rebuilt join comes back unchanged. Catches: the declined path
    removed (greedy would seed B and CROSS: b,a)."""
    var out = reorder_joins(_keyless(_scan("a", 1000), _scan("b", 10), JOIN_INNER))
    assert_equal(_order(out), String("a,b"))
    assert_equal(out.join_data_ref().join_type, JOIN_INNER)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
