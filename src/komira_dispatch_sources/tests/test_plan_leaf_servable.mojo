# =============================================================================
# test_plan_leaf_servable.mojo -- the leaf-servability pre-gates, branch by
#   branch.
# =============================================================================
#
# SUBJECT: `_subtree_all_leaf_scans_servable` and the in-memory filter envelope
# under it (`_inmem_pushed_filter_servable`, `_pushed_filter_is_arith_value`).
#   1. the leaves: parquet admits; CSV declines; an in-memory scan admits
#      unfiltered, admits a filter in the envelope and declines one outside it;
#   2. the walk: every descended node admits over a parquet leaf and declines
#      over a CSV leaf; a join needs both sides; any other node declines; a node
#      whose payload is missing declines;
#   3. the envelope: each accepted predicate shape, and the refusals next to
#      it (a literal on the left, a NEGATE, a function of an expression, a
#      non-BOOL literal, a MOD on the right).
# A defect that widens the envelope (admitting a shape the in-memory leaf's
# evaluator raises on) fails section 3's refusals; one that narrows it fails
# its admissions.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_AND,
    BIN_DIV,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_MOD,
    BIN_MUL,
    BIN_NE,
    BIN_OR,
    BIN_SUB,
    STR_LIKE,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NEGATE,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    SOURCE_CSV,
    SOURCE_IN_MEMORY,
    SOURCE_PARQUET,
    JOIN_INNER,
)

from komira_dispatch_sources.plan_leaf_servable import (
    _inmem_pushed_filter_servable,
    _is_servable_inmem_leaf,
    _pushed_filter_is_arith_value,
    _subtree_all_leaf_scans_servable,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    return sb.build()


def _parquet() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _schema())


def _csv() -> LogicalPlan:
    return LogicalPlan.scan(String("t.csv"), SOURCE_CSV, _schema())


def _inmem(var filter: Optional[Expr] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("t_mem"), SOURCE_IN_MEMORY, _schema(), filter=filter^
    )


def _k() -> Expr:
    return Expr.col_ref(String("k"))


def _int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _k_gt_1() -> Expr:
    return Expr.binary(BIN_GT, _k(), _int(1))


# --- 1. the leaves ----------------------------------------------------------


def test_leaves() raises:
    assert_true(_subtree_all_leaf_scans_servable(_parquet()), "parquet scan")
    assert_false(_subtree_all_leaf_scans_servable(_csv()), "CSV scan declines")
    assert_true(_subtree_all_leaf_scans_servable(_inmem()), "unfiltered in-mem")
    assert_true(
        _subtree_all_leaf_scans_servable(_inmem(_k_gt_1())),
        "in-mem with k > 1 pushed",
    )
    assert_false(
        _subtree_all_leaf_scans_servable(_inmem(_int(1))),
        "in-mem with a non-BOOL literal filter declines",
    )
    assert_true(_is_servable_inmem_leaf(_inmem()), "the leaf predicate itself")
    assert_false(_is_servable_inmem_leaf(_parquet()), "parquet is not in-mem")
    assert_false(
        _is_servable_inmem_leaf(LogicalPlan.filter(_k_gt_1(), _inmem())),
        "a FILTER node is not a leaf",
    )
    assert_false(
        _is_servable_inmem_leaf(LogicalPlan(PLAN_SCAN, _schema())),
        "a SCAN with no payload",
    )


# --- 2. the walk ------------------------------------------------------------


def _wrap(kind: Int, var child: LogicalPlan) -> LogicalPlan:
    if kind == 0:
        return LogicalPlan.filter(_k_gt_1(), child^)
    if kind == 1:
        var exprs = ExprArray()
        exprs.append(_k())
        return LogicalPlan.project(exprs^, child^)
    if kind == 2:
        var gb = ExprArray()
        gb.append(_k())
        var ax = AggExprArray()
        ax.append(AggExpr(AGG_COUNT, Optional[Expr](), None))
        return LogicalPlan.aggregate(gb^, ax^, child^)
    if kind == 3:
        return LogicalPlan.sort([String("k")], [False], child^)
    if kind == 4:
        return LogicalPlan.topn([String("k")], [False], 3, child^)
    if kind == 5:
        return LogicalPlan.distinct(None, child^)
    return LogicalPlan.limit(3, child^)


def test_each_descended_node_follows_its_child() raises:
    for kind in range(6):
        assert_true(
            _subtree_all_leaf_scans_servable(_wrap(kind, _parquet())),
            String("node kind ", kind, " over parquet"),
        )
        assert_false(
            _subtree_all_leaf_scans_servable(_wrap(kind, _csv())),
            String("node kind ", kind, " over CSV"),
        )
    # nested: a sort over a filter over an in-mem leaf
    assert_true(
        _subtree_all_leaf_scans_servable(_wrap(3, _wrap(0, _inmem())))
    )


def _join(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, [String("k")], [String("k")], JOIN_INNER)


def test_a_join_needs_both_sides() raises:
    assert_true(_subtree_all_leaf_scans_servable(_join(_parquet(), _inmem())))
    assert_false(_subtree_all_leaf_scans_servable(_join(_csv(), _parquet())))
    assert_false(_subtree_all_leaf_scans_servable(_join(_parquet(), _csv())))


def test_other_nodes_and_missing_payloads_decline() raises:
    assert_false(
        _subtree_all_leaf_scans_servable(_wrap(6, _parquet())),
        "LIMIT is not walked",
    )
    var tags: List[UInt8] = [
        PLAN_SCAN,
        PLAN_FILTER,
        PLAN_PROJECT,
        PLAN_AGGREGATE,
        PLAN_SORT,
        PLAN_TOPN,
        PLAN_DISTINCT,
        PLAN_JOIN,
    ]
    for t in tags:
        assert_false(
            _subtree_all_leaf_scans_servable(LogicalPlan(t, _schema())),
            String("tag ", Int(t), " with no payload"),
        )


# --- 3. the in-memory filter envelope ---------------------------------------


def test_comparisons() raises:
    var ops: List[UInt8] = [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]
    for op in ops:
        assert_true(
            _inmem_pushed_filter_servable(Expr.binary(op, _k(), _int(5))),
            String("col CMP literal, op ", Int(op)),
        )
    assert_true(
        _inmem_pushed_filter_servable(
            Expr.binary(BIN_LT, Expr.col_idx(0), Expr.col_ref(String("s")))
        ),
        "col_idx CMP col_ref",
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.binary(BIN_GT, _int(5), _k())),
        "a literal on the left",
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.binary(BIN_ADD, _k(), _int(5))),
        "an arithmetic root is not a predicate",
    )


def test_arithmetic_right_hand_sides() raises:
    var ops: List[UInt8] = [BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV]
    for op in ops:
        var rhs = Expr.binary(op, Expr.cast(_k(), DType.float64), _int(2))
        assert_true(
            _inmem_pushed_filter_servable(Expr.binary(BIN_GT, _k(), rhs^)),
            String("col > CAST(col) op literal, op ", Int(op)),
        )
    assert_false(
        _pushed_filter_is_arith_value(Expr.binary(BIN_MOD, _k(), _int(2))),
        "MOD is not in the value set",
    )
    assert_false(
        _pushed_filter_is_arith_value(Expr.binary(BIN_ADD, _k(), _k_gt_1())),
        "a comparison under ADD is not a value",
    )
    assert_false(
        _pushed_filter_is_arith_value(Expr.unary(UN_NEGATE, _k())),
        "NEGATE is not in the value set",
    )
    assert_false(
        _inmem_pushed_filter_servable(
            Expr.binary(BIN_EQ, _k(), Expr.binary(BIN_MOD, _k(), _int(2)))
        ),
        "col = col % 2 declines",
    )


def test_conjunctions_and_unary() raises:
    var ok = _k_gt_1()
    var bad = Expr.binary(BIN_GT, _int(5), _k())
    assert_true(
        _inmem_pushed_filter_servable(Expr.binary(BIN_AND, ok.copy(), ok.copy()))
    )
    assert_true(
        _inmem_pushed_filter_servable(Expr.binary(BIN_OR, ok.copy(), ok.copy()))
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.binary(BIN_AND, ok.copy(), bad.copy())),
        "AND with a refused right side",
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.binary(BIN_OR, bad.copy(), ok.copy())),
        "OR with a refused left side",
    )
    assert_true(_inmem_pushed_filter_servable(Expr.unary(UN_NOT, ok.copy())))
    assert_false(_inmem_pushed_filter_servable(Expr.unary(UN_NOT, bad.copy())))
    assert_true(_inmem_pushed_filter_servable(Expr.unary(UN_IS_NULL, _k())))
    assert_true(
        _inmem_pushed_filter_servable(Expr.unary(UN_IS_NOT_NULL, Expr.col_idx(1)))
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.unary(UN_IS_NULL, _int(1))),
        "IS NULL of a literal",
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.unary(UN_IS_NOT_NULL, ok.copy())),
        "IS NOT NULL of an expression",
    )
    assert_false(
        _inmem_pushed_filter_servable(Expr.unary(UN_NEGATE, _k())),
        "NEGATE is not a predicate",
    )


def test_string_in_list_regexp_and_literals() raises:
    var s = Expr.col_ref(String("s"))
    assert_true(
        _inmem_pushed_filter_servable(Expr.string_op(STR_LIKE, s.copy(), "%a%"))
    )
    assert_false(
        _inmem_pushed_filter_servable(
            Expr.string_op(STR_LIKE, Expr.cast(_k(), DType.float64), "%a%")
        ),
        "a string op over an expression",
    )
    var vals: List[ScalarValue] = [ScalarValue.from_int64(1)]
    assert_true(_inmem_pushed_filter_servable(Expr.in_list_node(_k(), vals.copy())))
    assert_false(
        _inmem_pushed_filter_servable(
            Expr.in_list_node(Expr.cast(_k(), DType.float64), vals.copy())
        ),
        "IN over an expression",
    )
    assert_true(_inmem_pushed_filter_servable(Expr.regexp_like(s.copy(), "a+")))
    assert_false(
        _inmem_pushed_filter_servable(Expr.regexp_like(Expr.cast(_k(), DType.float64), "a+")),
        "REGEXP over an expression",
    )
    assert_true(
        _inmem_pushed_filter_servable(
            Expr.literal(ScalarValue.from_bool(False))
        ),
        "the folded `col IN ()`",
    )
    assert_false(
        _inmem_pushed_filter_servable(
            Expr.literal(ScalarValue.from_string(String("x")))
        ),
        "a STRING literal",
    )
    assert_false(_inmem_pushed_filter_servable(_k()), "a bare column")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
