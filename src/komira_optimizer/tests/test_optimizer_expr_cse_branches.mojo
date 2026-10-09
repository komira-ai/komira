# =============================================================================
# Direct tests for the parts of `optimizer_expr`'s CSE rule and kernel
# template matcher that the moved tests (test_optimizer_cse_axes,
# test_cse_fingerprint_no_collapse, test_expr_kernel_template_coverage) do
# not reach: the CSE driver's walk over every node kind, the in-place entry
# point, the UDF and empty-input guards, every aggregate argument slot, the
# WHEN / IN_LIST / unary / cast arms of the subtree walkers, the duplicate
# counter, the synthetic-name generator, and the matcher's remaining arms.
#
# Plans and expressions are built in memory; no file is read. Each test names
# the defect it catches.
# =============================================================================

from std.collections import Dict
from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_STRING_OP,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_GT,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_ABS,
    STR_CONTAINS,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP, DTAG_I64, DTAG_F64
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_UNION,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_plan_ir.plan_helpers import _expr_fingerprint
from komira_kernels.expr_kernel_templates import (
    EXPR_TEMPLATE_INTERPRETED,
    EXPR_TEMPLATE_CAST_I64_TO_F64,
    EXPR_TEMPLATE_CAST_F64_TO_I64,
    EXPR_TEMPLATE_AND_BOOL,
    EXPR_TEMPLATE_OR_BOOL,
    EXPR_TEMPLATE_MUL_F64_COLLIT,
    EXPR_TEMPLATE_EQ_F64_COLLIT,
    EXPR_TEMPLATE_NE_F64_COLLIT,
    EXPR_TEMPLATE_ADD_I64_COLLIT,
    EXPR_TEMPLATE_EQ_I64_COLLIT,
    EXPR_TEMPLATE_NE_I64_COLLIT,
)
from komira_optimizer.optimizer_expr import (
    eliminate_common_subexpressions,
    eliminate_common_subexpressions_inplace,
    _count_cse_duplicates,
    _collect_subtree_fingerprints,
    _is_cse_eligible,
    _subtree_depth,
    _cse_synthetic_name,
    _CseNameCounter,
    _fnv1a_lower32,
    _u32_to_hex8,
    _sort_string_list,
    _collect_and_conjuncts_local,
    _match_expr_to_kernel_template,
    _match_arith_collit_f64,
    _match_arith_collit_i64,
    _match_cmp_collit_f64,
    _match_cmp_collit_i64,
)


# =============================================================================
# Builders
# =============================================================================

def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _f(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _ab() -> Expr:
    return _bin(BIN_MUL, _c("a"), _c("b"))


def _opaque() -> Expr:
    return Expr.string_op(STR_CONTAINS, _c("a"), String("x"))


def _when(var cond: Expr, var result: Expr, var default: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(cond^, result^))
    return Expr.when(cases^, default^)


def _in(var child: Expr) -> Expr:
    var vals: List[ScalarValue] = [ScalarValue.from_int(1), ScalarValue.from_int(2)]
    return Expr.in_list_node(child^, vals^)


def _schema(n0: String, n1: String, n2: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(n0, ArrowType.INT64, False))
    sb.add_field(Field(n1, ArrowType.INT64, False))
    sb.add_field(Field(n2, ArrowType.INT64, False))
    return sb.build()


def _scan_abc() -> LogicalPlan:
    return LogicalPlan.scan("l.parquet", SOURCE_PARQUET, _schema("a", "b", "c"))


def _scan_xyz() -> LogicalPlan:
    return LogicalPlan.scan("r.parquet", SOURCE_PARQUET, _schema("x", "y", "z"))


# Project([a, (a*b)+1 AS p, (a*b)+2 AS q]) over Scan(a,b,c): `a*b` (depth 2)
# occurs twice, so Axis 1 materializes it below.
def _dup_project_exprs() -> ExprArray:
    var exprs = ExprArray()
    exprs.append(_c("a"))
    exprs.append(Expr.alias(_bin(BIN_ADD, _ab(), _i(1)), "p"))
    exprs.append(Expr.alias(_bin(BIN_ADD, _ab(), _i(2)), "q"))
    return exprs^


# ((x*y)+1 > 0) AND ((x*y)+1 < 9): `(x*y)+1` (depth 3) occurs twice.
def _dup_predicate() -> Expr:
    var xy1 = _bin(BIN_ADD, _bin(BIN_MUL, _c("x"), _c("y")), _i(1))
    var xy2 = _bin(BIN_ADD, _bin(BIN_MUL, _c("x"), _c("y")), _i(1))
    return _bin(BIN_AND, _bin(BIN_GT, xy1^, _i(0)), _bin(BIN_LT, xy2^, _i(9)))


def _count_cse_projects(plan: LogicalPlan) raises -> Int:
    if plan.tag == PLAN_PROJECT:
        var own = 1 if plan._project.value()[].is_cse_introduced else 0
        return own + _count_cse_projects(plan._project.value()[].child[])
    if plan.tag == PLAN_FILTER:
        return _count_cse_projects(plan._filter.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        return _count_cse_projects(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        return _count_cse_projects(plan._join.value()[].left[]) + _count_cse_projects(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return _count_cse_projects(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return _count_cse_projects(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _count_cse_projects(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return _count_cse_projects(plan._topn.value()[].child[])
    if plan.tag == PLAN_UNION:
        var n = 0
        for k in range(len(plan._union.value()[].children)):
            n += _count_cse_projects(plan._union.value()[].children[k][])
        return n
    return 0


def _is_cse_ref(e: Expr) raises -> Bool:
    return e.tag == EXPR_COL_REF and e.col_ref_name().startswith("_cse_")


# =============================================================================
# CSE: driver and guards
# =============================================================================

def test_cse_driver_walks_every_node_kind() raises:
    """Catches: the in-place entry point or the driver dropping the
    recursion of any of Join (left or right), Sort, Limit, Distinct, TopN or
    Aggregate, so a duplicate under it is never materialized. The Aggregate
    on the path has no aggregates, which also runs the Axis 3 empty guard."""
    var left = LogicalPlan.project(_dup_project_exprs(), _scan_abc())
    var right = LogicalPlan.filter(_dup_predicate(), _scan_xyz())
    var gb = ExprArray()
    gb.append(_c("a"))
    var agg = LogicalPlan.aggregate(gb^, AggExprArray(), left^)
    var lon: List[String] = ["a"]
    var ron: List[String] = ["x"]
    var j = LogicalPlan.join(agg^, right^, lon^, ron^, JOIN_INNER)
    var sk: List[String] = ["a"]
    var sd: List[Bool] = [False]
    var s = LogicalPlan.sort(sk^, sd^, j^)
    var l = LogicalPlan.limit(10, s^)
    var d = LogicalPlan.distinct(None, l^)
    var tk: List[String] = ["a"]
    var td: List[Bool] = [False]
    var plan = LogicalPlan.topn(tk^, td^, 5, d^)
    assert_equal(_count_cse_projects(plan), 0, "no CSE Project before the rule")

    eliminate_common_subexpressions_inplace(plan)

    assert_true(plan.tag == PLAN_TOPN, "the root is unchanged")
    # 1 Project spliced under the left Project (Axis 1) + the 2-Project
    # sandwich around the right Filter (Axis 2).
    assert_equal(_count_cse_projects(plan), 3,
                 "both duplicates under the chain are materialized")


def test_cse_driver_leaves_unhandled_tag() raises:
    """Catches: the driver descending into a node kind it has no arm for
    (UNION here), which it does not do today."""
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(LogicalPlan.project(_dup_project_exprs(), _scan_abc())))
    var u = LogicalPlan.union(children^, _schema("a", "p", "q"))
    var out = eliminate_common_subexpressions(u^)
    assert_true(out.tag == PLAN_UNION, "the union is unchanged")
    assert_equal(_count_cse_projects(out), 0, "nothing below the union is rewritten")


def test_cse_axis1_empty_project_is_unchanged() raises:
    """Catches: the empty-Project guard turning into a splice (a Project of
    zero expressions has nothing to share)."""
    var proj = LogicalPlan.project(ExprArray(), _scan_abc())
    var out = eliminate_common_subexpressions(proj^)
    assert_true(out.tag == PLAN_PROJECT, "still a Project")
    assert_equal(len(out._project.value()[].exprs), 0, "still no expressions")
    assert_true(out._project.value()[].child[].tag == PLAN_SCAN, "no Project spliced below")


def test_cse_axis1_skips_udf_project() raises:
    """Catches: removing the UDF guard. A map-UDF Project's operator resolves
    its columns against THIS node's child, so a Project spliced under it
    would change what the UDF reads."""
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append(("a", DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append(("r", DTAG_F64))
    var udf = OwnedPointer(UdfData(
        kind=UDF_KIND_MAP,
        name=String("m"),
        input_columns=in_cols^,
        output_columns=out_cols^,
        operator_factory_id=UInt32(1),
        call_site_salt=UInt32(0),
    ))
    var plan = LogicalPlan.project_with_udf(_dup_project_exprs(), _scan_abc(), udf^)
    var out = eliminate_common_subexpressions(plan^)
    assert_true(out.has_udf(), "the UDF payload survives")
    assert_true(out._project.value()[].child[].tag == PLAN_SCAN, "no Project spliced below")
    assert_equal(_count_cse_projects(out), 0, "no CSE Project anywhere")
    assert_true(out._project.value()[].exprs[1].alias_child_ref().tag == EXPR_BINARY_OP,
                "the duplicated arithmetic is left in place")


# =============================================================================
# CSE: Axis 3 argument slots, and the duplicate counter's Aggregate arm
# =============================================================================

def test_cse_axis3_rewrites_every_arg_slot_and_keeps_aliases() raises:
    """Catches: Axis 3 tallying or rewriting only `child` (the second, third
    and fourth argument slots are separate fields); an alias dropped or
    invented; a COUNT(*) gaining an argument; group-by keys rewritten; and,
    in `_count_cse_duplicates`, an Aggregate arm that skips a slot."""
    var a0_child: Optional[Expr] = _bin(BIN_ADD, _ab(), _i(1))
    var a0_alias: Optional[String] = String("s1")
    var a0 = AggExpr(AGG_SUM, a0_child^, a0_alias^)
    a0.child1 = Optional[Expr](_bin(BIN_ADD, _ab(), _i(1)))
    a0.child2 = Optional[Expr](_bin(BIN_ADD, _ab(), _i(1)))
    a0.child3 = Optional[Expr](_bin(BIN_ADD, _ab(), _i(1)))
    var a1_child: Optional[Expr] = None
    var a1_alias: Optional[String] = None
    var a1 = AggExpr(AGG_COUNT, a1_child^, a1_alias^)
    var a2_child: Optional[Expr] = _bin(BIN_ADD, _c("c"), _i(1))
    var a2_alias: Optional[String] = String("s2")
    var a2 = AggExpr(AGG_SUM, a2_child^, a2_alias^)
    var aggs = AggExprArray()
    aggs.append(a0^)
    aggs.append(a1^)
    aggs.append(a2^)
    var gb = ExprArray()
    gb.append(_c("c"))
    var plan = LogicalPlan.aggregate(gb^, aggs^, _scan_abc())

    # `(a*b)+1` and `a*b` each occur 4 times: 3 + 3 extra copies; `c+1`
    # occurs once and adds nothing.
    assert_equal(_count_cse_duplicates(plan), 6, "every slot is tallied")

    var out = eliminate_common_subexpressions(plan^)

    assert_true(out.tag == PLAN_AGGREGATE, "still an Aggregate")
    assert_true(out._aggregate.value()[].child[].tag == PLAN_PROJECT, "a Project is spliced below")
    assert_true(out._aggregate.value()[].child[]._project.value()[].is_cse_introduced,
                "and flagged as CSE-introduced")
    assert_true(_is_cse_ref(out._aggregate.value()[].agg_exprs[0].child.value()), "slot 0 rewritten")
    assert_true(_is_cse_ref(out._aggregate.value()[].agg_exprs[0].child1.value()), "slot 1 rewritten")
    assert_true(_is_cse_ref(out._aggregate.value()[].agg_exprs[0].child2.value()), "slot 2 rewritten")
    assert_true(_is_cse_ref(out._aggregate.value()[].agg_exprs[0].child3.value()), "slot 3 rewritten")
    var n0 = out._aggregate.value()[].agg_exprs[0].child.value().col_ref_name()
    var n3 = out._aggregate.value()[].agg_exprs[0].child3.value().col_ref_name()
    assert_equal(n0, n3, "all slots name the one synthetic")
    assert_equal(out._aggregate.value()[].agg_exprs[0].alias_name.value(), String("s1"))
    assert_false(Bool(out._aggregate.value()[].agg_exprs[1].child), "COUNT(*) keeps no argument")
    assert_false(Bool(out._aggregate.value()[].agg_exprs[1].child1), "and no second argument")
    assert_false(Bool(out._aggregate.value()[].agg_exprs[1].alias_name), "and no alias")
    assert_equal(out._aggregate.value()[].group_by[0].col_ref_name(), String("c"),
                 "group-by keys are kept as they were")
    assert_true(out._aggregate.value()[].agg_exprs[2].child.value().tag == EXPR_BINARY_OP,
                "an argument with no duplicate is left as it was")


# =============================================================================
# CSE: WHEN / IN_LIST / unary / cast in the walkers and the rewriter
# =============================================================================

def test_cse_materializes_duplicated_when() raises:
    """Catches: WHEN dropped from the eligibility whitelist, from the depth
    walk or from the tally walk; any of these leaves both CASE outputs
    computed twice."""
    var exprs = ExprArray()
    exprs.append(_c("a"))
    exprs.append(Expr.alias(_when(_bin(BIN_GT, _c("a"), _i(1)), _bin(BIN_ADD, _c("a"), _i(1)), _i(0)), "w1"))
    exprs.append(Expr.alias(_when(_bin(BIN_GT, _c("a"), _i(1)), _bin(BIN_ADD, _c("a"), _i(1)), _i(0)), "w2"))
    var out = eliminate_common_subexpressions(LogicalPlan.project(exprs^, _scan_abc()))
    assert_true(_is_cse_ref(out._project.value()[].exprs[1].alias_child_ref()), "w1 reads a synthetic")
    assert_true(_is_cse_ref(out._project.value()[].exprs[2].alias_child_ref()), "w2 reads a synthetic")
    var w1 = out._project.value()[].exprs[1].alias_child_ref().col_ref_name()
    var w2 = out._project.value()[].exprs[2].alias_child_ref().col_ref_name()
    assert_equal(w1, w2, "the same one")


def test_cse_never_replaces_ineligible_when() raises:
    """Catches: a WHEN with an opaque condition treated as eligible (the
    whole CASE would be replaced by a synthetic the rule cannot honour). Its
    inner `a + 1` is still tallied, so a synthetic for that is made below."""
    var exprs = ExprArray()
    exprs.append(Expr.alias(_when(_opaque(), _bin(BIN_ADD, _c("a"), _i(1)), _i(0)), "w1"))
    exprs.append(Expr.alias(_when(_opaque(), _bin(BIN_ADD, _c("a"), _i(1)), _i(0)), "w2"))
    var out = eliminate_common_subexpressions(LogicalPlan.project(exprs^, _scan_abc()))
    assert_true(out._project.value()[].exprs[0].alias_child_ref().tag == EXPR_WHEN, "w1 is still a CASE")
    assert_true(out._project.value()[].exprs[1].alias_child_ref().tag == EXPR_WHEN, "w2 is still a CASE")


def test_cse_rewriter_arms() raises:
    """With `a*b` the one candidate, catches: the rewriter not recursing
    through NOT or CAST (the inner `a*b` would stay), a CAST rebuilt from its
    bare DType (its TIMESTAMP_MS target lost), the rewriter reaching into
    a WHEN or IN_LIST it documents as left whole, or rebuilding an opaque
    node."""
    var exprs = ExprArray()
    exprs.append(Expr.alias(_bin(BIN_ADD, _ab(), _i(1)), "p"))
    exprs.append(Expr.alias(_bin(BIN_ADD, _ab(), _i(2)), "q"))
    exprs.append(Expr.alias(_when(_bin(BIN_GT, _c("a"), _i(1)), _ab(), _i(0)), "w"))
    exprs.append(Expr.alias(_in(_ab()), "i"))
    exprs.append(Expr.alias(Expr.unary(UN_NOT, _bin(BIN_GT, _ab(), _i(1))), "n"))
    exprs.append(Expr.alias(Expr.cast_to_arrow(_ab(), ArrowType.TIMESTAMP_MS), "t"))
    exprs.append(Expr.alias(_opaque(), "o"))
    var out = eliminate_common_subexpressions(LogicalPlan.project(exprs^, _scan_abc()))

    assert_true(out._project.value()[].child[].tag == PLAN_PROJECT, "a Project is spliced below")
    assert_true(_is_cse_ref(out._project.value()[].exprs[0].alias_child_ref().binary_left_ref()),
                "p reads the synthetic")
    assert_true(out._project.value()[].exprs[2].alias_child_ref().tag == EXPR_WHEN, "w is still a CASE")
    # The WHEN is left whole: its `a*b` result is not replaced by the
    # synthetic. Catches a rewriter that recurses into WHEN results.
    assert_equal(out._project.value()[].exprs[2].alias_child_ref().when_num_cases(), 1, "w keeps its one case")
    assert_true(out._project.value()[].exprs[2].alias_child_ref().when_case_result_ref(0).tag == EXPR_BINARY_OP,
                "the a*b result inside the WHEN is left whole")
    assert_true(out._project.value()[].exprs[2].alias_child_ref().when_case_result_ref(0).binary_op() == BIN_MUL,
                "and is still the multiplication")
    assert_true(out._project.value()[].exprs[3].alias_child_ref().tag == EXPR_IN_LIST, "i is still an IN list")
    assert_true(out._project.value()[].exprs[3].alias_child_ref().in_list_child_ref().tag == EXPR_BINARY_OP,
                "and its operand is left whole")
    assert_true(out._project.value()[].exprs[4].alias_child_ref().tag == EXPR_UNARY_OP, "n is still a NOT")
    assert_true(_is_cse_ref(out._project.value()[].exprs[4].alias_child_ref().unary_child_ref().binary_left_ref()),
                "the a*b under NOT reads the synthetic")
    assert_true(out._project.value()[].exprs[5].alias_child_ref().tag == EXPR_CAST, "t is still a cast")
    assert_true(_is_cse_ref(out._project.value()[].exprs[5].alias_child_ref().cast_child_ref()),
                "the a*b under the cast reads the synthetic")
    assert_true(out._project.value()[].exprs[5].alias_child_ref().cast_target_arrow() == ArrowType.TIMESTAMP_MS,
                "the cast keeps its arrow target")
    assert_true(out._project.value()[].exprs[6].alias_child_ref().tag == EXPR_STRING_OP,
                "an opaque output is returned as is")


def test_eligibility_and_depth() raises:
    """Catches: a tag added to or dropped from the eligibility whitelist; an
    ineligible descendant in any position (binary side, unary, cast, alias,
    IN operand, WHEN condition, result or default) not rejected; an alias
    counted as a level; a depth that follows one side only."""
    assert_true(_is_cse_eligible(_c("a")))
    assert_true(_is_cse_eligible(Expr.col_idx(0)))
    assert_true(_is_cse_eligible(_i(1)))
    assert_true(_is_cse_eligible(_ab()))
    assert_true(_is_cse_eligible(Expr.unary(UN_NEGATE, _c("a"))))
    assert_true(_is_cse_eligible(Expr.cast(_c("a"), DType.float64)))
    assert_true(_is_cse_eligible(Expr.alias(_ab(), "x")))
    assert_true(_is_cse_eligible(_when(_bin(BIN_GT, _c("a"), _i(1)), _c("a"), _i(0))))
    assert_true(_is_cse_eligible(_in(_ab())))
    assert_false(_is_cse_eligible(_opaque()))
    assert_false(_is_cse_eligible(_bin(BIN_ADD, _c("a"), _opaque())))
    assert_false(_is_cse_eligible(_bin(BIN_ADD, _opaque(), _c("a"))))
    assert_false(_is_cse_eligible(Expr.unary(UN_NEGATE, _opaque())))
    assert_false(_is_cse_eligible(Expr.cast(_opaque(), DType.float64)))
    assert_false(_is_cse_eligible(Expr.alias(_opaque(), "x")))
    assert_false(_is_cse_eligible(_in(_opaque())))
    assert_false(_is_cse_eligible(_when(_opaque(), _c("a"), _i(0))))
    assert_false(_is_cse_eligible(_when(_bin(BIN_GT, _c("a"), _i(1)), _opaque(), _i(0))))
    assert_false(_is_cse_eligible(_when(_bin(BIN_GT, _c("a"), _i(1)), _c("a"), _opaque())))

    assert_equal(_subtree_depth(_c("a")), 1)
    assert_equal(_subtree_depth(Expr.col_idx(0)), 1)
    assert_equal(_subtree_depth(_i(1)), 1)
    assert_equal(_subtree_depth(_opaque()), 1)
    assert_equal(_subtree_depth(_bin(BIN_ADD, _ab(), _c("c"))), 3)
    assert_equal(_subtree_depth(_bin(BIN_ADD, _c("c"), _ab())), 3)
    assert_equal(_subtree_depth(Expr.unary(UN_NEGATE, _c("a"))), 2)
    assert_equal(_subtree_depth(Expr.cast(_c("a"), DType.float64)), 2)
    assert_equal(_subtree_depth(Expr.alias(_ab(), "x")), 2)
    assert_equal(_subtree_depth(_in(_ab())), 3)
    # WHEN = 1 + the deepest of condition, result and default.
    assert_equal(_subtree_depth(_when(_bin(BIN_GT, _c("a"), _i(1)), _c("a"),
                                      _bin(BIN_ADD, _ab(), _c("c")))), 4)
    assert_equal(_subtree_depth(_when(_bin(BIN_GT, _c("a"), _i(1)),
                                      _bin(BIN_ADD, _ab(), _c("c")), _i(0))), 4)
    assert_equal(_subtree_depth(_when(_bin(BIN_GT, _c("a"), _i(1)), _c("a"), _i(0))), 3)
    assert_equal(_subtree_depth(_when(_c("b"), _c("a"), _i(0))), 2)


def test_collect_subtree_fingerprints() raises:
    """Catches: an alias recorded as its own candidate; a nested duplicate
    not counted; the first-seen exemplar replaced by a later one; a wrong
    depth; the walk not descending through unary, cast, IN_LIST or WHEN, or
    descending into an opaque node."""
    var counts = Dict[String, Int]()
    var exemplars = ExprArray()
    var fp_to_exidx = Dict[String, Int]()
    var depths = Dict[String, Int]()
    var sum_ab = _bin(BIN_ADD, _c("a"), _c("b"))
    var whole = _bin(BIN_MUL, sum_ab.copy(), sum_ab.copy())
    var fp_sum = _expr_fingerprint(sum_ab)
    var fp_whole = _expr_fingerprint(whole)
    _collect_subtree_fingerprints(Expr.alias(whole.copy(), "x"), counts, exemplars, fp_to_exidx, depths)
    assert_equal(len(counts), 2, "only the product and the sum")
    assert_equal(counts[fp_sum], 2, "the sum occurs twice")
    assert_equal(counts[fp_whole], 1)
    assert_equal(depths[fp_sum], 2)
    assert_equal(depths[fp_whole], 3)
    assert_equal(fp_to_exidx[fp_whole], 0, "the outer node is seen first")
    assert_equal(len(exemplars), 2, "one exemplar per fingerprint")

    var c2 = Dict[String, Int]()
    var e2 = ExprArray()
    var x2 = Dict[String, Int]()
    var d2 = Dict[String, Int]()
    _collect_subtree_fingerprints(Expr.unary(UN_NEGATE, sum_ab.copy()), c2, e2, x2, d2)
    _collect_subtree_fingerprints(Expr.cast(sum_ab.copy(), DType.float64), c2, e2, x2, d2)
    _collect_subtree_fingerprints(_in(sum_ab.copy()), c2, e2, x2, d2)
    _collect_subtree_fingerprints(_when(_c("b"), sum_ab.copy(), _i(0)), c2, e2, x2, d2)
    _collect_subtree_fingerprints(_when(sum_ab.copy(), _c("a"), _i(0)), c2, e2, x2, d2)
    _collect_subtree_fingerprints(_when(_c("b"), _c("a"), sum_ab.copy()), c2, e2, x2, d2)
    assert_equal(c2[fp_sum], 6, "the sum is found under every eligible wrapper")

    var c3 = Dict[String, Int]()
    var e3 = ExprArray()
    var x3 = Dict[String, Int]()
    var d3 = Dict[String, Int]()
    _collect_subtree_fingerprints(Expr.string_op(STR_CONTAINS, sum_ab.copy(), String("x")), c3, e3, x3, d3)
    assert_equal(len(c3), 0, "nothing under an opaque node is tallied")


def test_count_cse_duplicates_project_filter_and_other() raises:
    """Catches: the Project arm counting an expression once per earlier match
    (the `break`) instead of once; the Filter arm counting a fingerprint's
    first occurrence; any other node kind reporting duplicates."""
    var exprs = ExprArray()
    exprs.append(_bin(BIN_ADD, _c("a"), _i(1)))
    exprs.append(_bin(BIN_ADD, _c("a"), _i(1)))
    exprs.append(_bin(BIN_ADD, _c("a"), _i(2)))
    exprs.append(_bin(BIN_ADD, _c("a"), _i(1)))
    assert_equal(_count_cse_duplicates(LogicalPlan.project(exprs^, _scan_abc())), 2)
    # `(x*y)+1` twice and `x*y` twice: 1 + 1.
    assert_equal(_count_cse_duplicates(LogicalPlan.filter(_dup_predicate(), _scan_xyz())), 2)
    assert_equal(_count_cse_duplicates(_scan_abc()), 0)


def test_collect_and_conjuncts_local() raises:
    """Catches: a nested AND not flattened, or an OR split as if it were AND."""
    var conj = ExprArray()
    _collect_and_conjuncts_local(_bin(BIN_AND, _bin(BIN_AND, _c("a"), _c("b")), _c("c")), conj)
    assert_equal(len(conj), 3)
    var disj = ExprArray()
    _collect_and_conjuncts_local(_bin(BIN_OR, _c("a"), _c("b")), disj)
    assert_equal(len(disj), 1)


# =============================================================================
# CSE: synthetic names
# =============================================================================

def test_synthetic_name_hash_hex_and_counter() raises:
    """Catches: a wrong FNV-1a basis or prime, the high instead of the low 32
    bits, hex digits out of order or unpadded, and a counter that does not
    advance (two candidates sharing a hash would get one name)."""
    assert_equal(Int(_fnv1a_lower32(String(""))), 0x84222325)
    assert_equal(Int(_fnv1a_lower32(String("a"))), 0x8601EC8C)
    assert_equal(Int(_fnv1a_lower32(String("foobar"))), 0xF73967E8)
    assert_equal(_u32_to_hex8(UInt32(0)), String("00000000"))
    assert_equal(_u32_to_hex8(UInt32(0x123)), String("00000123"))
    assert_equal(_u32_to_hex8(UInt32(0xDEADBEEF)), String("deadbeef"))
    var counter = _CseNameCounter()
    assert_equal(_cse_synthetic_name(String("a"), counter), String("_cse_8601ec8c_0"))
    assert_equal(_cse_synthetic_name(String("a"), counter), String("_cse_8601ec8c_1"))


def test_sort_string_list() raises:
    """Catches: an unstable or partial insertion sort (synthetic names follow
    this order, and EXPLAIN output and plan-cache keys rely on it)."""
    var xs: List[String] = ["c", "a", "b", "a"]
    _sort_string_list(xs)
    assert_equal(xs[0], String("a"))
    assert_equal(xs[1], String("a"))
    assert_equal(xs[2], String("b"))
    assert_equal(xs[3], String("c"))
    var empty = List[String]()
    _sort_string_list(empty)
    assert_equal(len(empty), 0)


# =============================================================================
# Kernel template matcher: arms the moved coverage test does not reach
# =============================================================================

def test_kernel_cast_targets() raises:
    """Catches: the FLOAT64 and INT64 cast IDs swapped, or a target outside
    the template set given an ID."""
    var to_f64 = _match_expr_to_kernel_template(Expr.cast(_c("x"), DType.float64))
    assert_equal(to_f64.value(), EXPR_TEMPLATE_CAST_I64_TO_F64)
    var to_i64 = _match_expr_to_kernel_template(Expr.cast(_c("x"), DType.int64))
    assert_equal(to_i64.value(), EXPR_TEMPLATE_CAST_F64_TO_I64)
    assert_false(Bool(_match_expr_to_kernel_template(Expr.cast(_c("x"), DType.int16))), "int16")
    assert_false(Bool(_match_expr_to_kernel_template(Expr.cast(_c("x"), DType.bool))), "bool")


def test_kernel_unary_outside_family() raises:
    """Catches: a unary op outside NOT/NEGATE/IS_NULL/IS_NOT_NULL given an ID."""
    assert_false(Bool(_match_expr_to_kernel_template(Expr.unary(UN_ABS, _c("x")))))


def test_kernel_and_or_need_predicate_operands() raises:
    """Catches: AND/OR matched when either side is a bare column, or refused
    when both sides are unary."""
    var gt = _bin(BIN_GT, _c("x"), _f(0.0))
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_AND, _c("b"), _c("c")))), "col and col")
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_AND, gt.copy(), _c("c")))), "pred and col")
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_OR, _c("b"), gt.copy()))), "col or pred")
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_OR, gt.copy(), _c("c")))), "pred or col")
    var and_u = _match_expr_to_kernel_template(
        _bin(BIN_AND, Expr.unary(UN_NOT, _c("b")), Expr.unary(UN_NOT, _c("c"))))
    assert_equal(and_u.value(), EXPR_TEMPLATE_AND_BOOL)
    var or_u = _match_expr_to_kernel_template(_bin(BIN_OR, Expr.unary(UN_NOT, _c("b")), gt.copy()))
    assert_equal(or_u.value(), EXPR_TEMPLATE_OR_BOOL)


def test_kernel_collit_outside_op_family() raises:
    """Catches: `%` with a literal, or a bool literal, given an arithmetic or
    comparison ID."""
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_MOD, _c("x"), _f(2.0)))), "f64 %")
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_MOD, _c("x"), _i(2)))), "i64 %")
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_MOD, _i(2), _c("x")))), "literal % col")
    assert_false(Bool(_match_expr_to_kernel_template(
        _bin(BIN_EQ, _c("x"), Expr.literal(ScalarValue.from_bool(True))))), "bool literal")


def test_kernel_literal_on_left() raises:
    """Catches: a commutative op (MUL, EQ, NE for F64; ADD, EQ, NE for I64 and
    an INT32 literal) refused with the literal on the left, or a
    non-commutative one (SUB) or a string literal matched there."""
    assert_equal(_match_expr_to_kernel_template(_bin(BIN_MUL, _f(2.0), _c("x"))).value(),
                 EXPR_TEMPLATE_MUL_F64_COLLIT)
    assert_equal(_match_expr_to_kernel_template(_bin(BIN_EQ, _f(2.0), _c("x"))).value(),
                 EXPR_TEMPLATE_EQ_F64_COLLIT)
    assert_equal(_match_expr_to_kernel_template(_bin(BIN_NE, _f(2.0), _c("x"))).value(),
                 EXPR_TEMPLATE_NE_F64_COLLIT)
    assert_equal(_match_expr_to_kernel_template(_bin(BIN_ADD, _i(2), _c("x"))).value(),
                 EXPR_TEMPLATE_ADD_I64_COLLIT)
    assert_equal(_match_expr_to_kernel_template(
        _bin(BIN_ADD, Expr.literal(ScalarValue.from_int32(2)), _c("x"))).value(),
                 EXPR_TEMPLATE_ADD_I64_COLLIT)
    assert_equal(_match_expr_to_kernel_template(_bin(BIN_EQ, _i(2), _c("x"))).value(),
                 EXPR_TEMPLATE_EQ_I64_COLLIT)
    assert_equal(_match_expr_to_kernel_template(_bin(BIN_NE, _i(2), _c("x"))).value(),
                 EXPR_TEMPLATE_NE_I64_COLLIT)
    assert_false(Bool(_match_expr_to_kernel_template(_bin(BIN_SUB, _i(2), _c("x")))), "i64 2 - x")
    assert_false(Bool(_match_expr_to_kernel_template(
        _bin(BIN_EQ, Expr.literal(ScalarValue.from_string(String("s"))), _c("x")))), "string literal")


def test_kernel_op_maps_reject_other_ops() raises:
    """Catches: an op map returning a real template ID for an op outside its
    family (the matcher guards each call, so only a direct call shows it)."""
    assert_equal(_match_arith_collit_f64(BIN_MOD), EXPR_TEMPLATE_INTERPRETED)
    assert_equal(_match_arith_collit_i64(BIN_GT), EXPR_TEMPLATE_INTERPRETED)
    assert_equal(_match_cmp_collit_f64(BIN_ADD), EXPR_TEMPLATE_INTERPRETED)
    assert_equal(_match_cmp_collit_i64(BIN_MUL), EXPR_TEMPLATE_INTERPRETED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
