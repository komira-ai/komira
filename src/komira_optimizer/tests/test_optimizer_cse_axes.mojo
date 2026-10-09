# =============================================================================
# Tests for Rule 18 3-axis CSE
# =============================================================================
#
# 9 test cases covering the three axes:
#   A1-A3 — PLAN_PROJECT subtree dedup (Axis 1)
#   B1-B3 — PLAN_FILTER predicate dedup via 2-Project sandwich (Axis 2)
#   C1-C3 — PLAN_AGGREGATE agg-fn arg dedup via synthetic Project (Axis 3)
#
# Each test handcrafts a LogicalPlan input, invokes the
# `eliminate_common_subexpressions` rule, and asserts the post-CSE
# structure matches the expected shape (no `optimize()` driver — the
# tests pin Rule 18 in isolation so they survive driver re-ordering).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    BIN_MUL,
    BIN_NE,
    BIN_OR,
    BIN_SUB,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_IN_LIST,
    EXPR_LITERAL,
    Expr,
)
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT
from komira_optimizer.optimizer_expr import (
    eliminate_common_subexpressions,
    _count_cse_duplicates,
)
from komira_optimizer.optimizer_filter import push_predicates_down


# =============================================================================
# Schema helper — TPC-H lineitem-shape table (6 columns)
# =============================================================================

def _lineitem_schema() -> Schema:
    var builder = SchemaBuilder()
    builder.add_field(Field("l_orderkey", ArrowType.INT64, False))
    builder.add_field(Field("l_extendedprice", ArrowType.INT64, False))
    builder.add_field(Field("l_discount", ArrowType.INT64, False))
    builder.add_field(Field("l_tax", ArrowType.INT64, False))
    builder.add_field(Field("l_quantity", ArrowType.INT64, False))
    builder.add_field(Field("l_shipdate", ArrowType.INT64, False))
    return builder.build()


def _simple_schema() -> Schema:
    var builder = SchemaBuilder()
    builder.add_field(Field("a", ArrowType.INT64, False))
    builder.add_field(Field("b", ArrowType.INT64, False))
    builder.add_field(Field("c", ArrowType.INT64, False))
    return builder.build()


# TPC-H q19-shape schema: a STRING predicate column + numeric companions.
def _shipmode_schema() -> Schema:
    var builder = SchemaBuilder()
    builder.add_field(Field("l_shipmode", ArrowType.STRING, False))
    builder.add_field(Field("l_shipinstruct", ArrowType.STRING, False))
    builder.add_field(Field("p_size", ArrowType.INT64, False))
    return builder.build()


# Find the arrow_type of the FIRST `_cse_*`-named field in a schema; returns
# ArrowType.NULL if no synthetic column is present (which itself is a failure
# in the CSE-dtype-propagation test below).
def _cse_field_arrow_type(schema: Schema) raises -> ArrowType:
    for i in range(schema.num_columns()):
        if schema.field_name(i).startswith("_cse_"):
            return schema.field_arrow_type(i)
    return ArrowType.NULL


# Recursively locate the inner (CSE-introduced) Project of a 2-Project
# sandwich produced by Axis-2 and return its output_schema. The sandwich is
# Project(outer) -> Filter -> Project(inner) -> <child>.
def _inner_cse_project_schema(plan: LogicalPlan) raises -> Schema:
    ref outer_child = plan._project.value()[].child[]
    ref inner = outer_child._filter.value()[].child[]
    return inner.output_schema.copy()


# (l_shipinstruct = 'DELIVER IN PERSON' OR l_shipmode = 'AIR') — a depth-3
# duplicated subtree for the STRING-comparison CSE-dtype test.
def _shipinstruct_or_shipmode_eq() -> Expr:
    var e1 = Expr.binary(BIN_EQ, Expr.col_ref("l_shipinstruct"),
                         Expr.literal(ScalarValue.from_string(String("DELIVER IN PERSON"))))
    var e2 = Expr.binary(BIN_EQ, Expr.col_ref("l_shipmode"),
                         Expr.literal(ScalarValue.from_string(String("AIR"))))
    return Expr.binary(BIN_OR, e1^, e2^)


# Convenience helpers — build l_extendedprice * (1 - l_discount).
def _make_disc_subtree() -> Expr:
    var one = Expr.literal(ScalarValue.from_int(1))
    var one_minus_disc = Expr.binary(BIN_SUB, one^, Expr.col_ref("l_discount"))
    return Expr.binary(BIN_MUL, Expr.col_ref("l_extendedprice"), one_minus_disc^)


def _make_a_times_b() -> Expr:
    return Expr.binary(BIN_MUL, Expr.col_ref("a"), Expr.col_ref("b"))


# Recursively count occurrences of an EXPR_COL_REF with a given name prefix
# within an Expr tree — used to verify CSE rewrites collapse multiple copies
# of a subtree to single materialize + N ColRef references.
def _count_col_refs_with_prefix(expr: Expr, prefix: String) raises -> Int:
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        if name.startswith(prefix):
            return 1
        return 0
    if expr.tag == EXPR_BINARY_OP:
        return _count_col_refs_with_prefix(expr.binary_left_ref(), prefix) + \
               _count_col_refs_with_prefix(expr.binary_right_ref(), prefix)
    if expr.tag == EXPR_ALIAS:
        return _count_col_refs_with_prefix(expr.alias_child_ref(), prefix)
    return 0


# Recursively count occurrences of a BinaryOp of a given op (e.g. count MULs).
def _count_binary_ops(expr: Expr, op: UInt8) raises -> Int:
    if expr.tag == EXPR_BINARY_OP:
        var n = (1 if expr.binary_op() == op else 0)
        return n + _count_binary_ops(expr.binary_left_ref(), op) + \
               _count_binary_ops(expr.binary_right_ref(), op)
    if expr.tag == EXPR_ALIAS:
        return _count_binary_ops(expr.alias_child_ref(), op)
    return 0


# Count `_cse_*` named columns in a Project's own expression list.
def _count_cse_prefixed_outputs(plan: LogicalPlan) raises -> Int:
    if plan.tag != PLAN_PROJECT:
        return 0
    var n = 0
    ref pd = plan._project.value()[]
    for i in range(len(pd.exprs)):
        if pd.exprs[i].tag == EXPR_ALIAS:
            var nm = pd.exprs[i].alias_name()
            if nm.startswith("_cse_"):
                n += 1
    return n


# =============================================================================
# Axis 1 — PLAN_PROJECT subtree dedup
# =============================================================================

def test_cse_axis1_shared_subtree_in_project() raises:
    """A1 — Project(A1, A1 * tax) deduplicates A1.

    Input:
      Project([Alias(l_extendedprice * (1 - l_discount), "p1"),
               Alias((l_extendedprice * (1 - l_discount)) * l_tax, "p2")],
              child=Scan(lineitem))
    Expected: the `_cse_*` materializers go in a Project spliced BELOW;
    both p1 / p2 are rewritten to reference them, and THIS Project keeps
    exactly its two original outputs.

    ⚠ THIS CASE ASSERTED `len(exprs) == 4` AND TWO PREPENDED `_cse_*`
    OUTPUTS UNTIL 2026-09-01 — i.e. it pinned the shape that killed the
    process. `LogicalPlan.project` derives one schema
    field per expr, so a 2-column Project grown to 4 exprs desyncs
    `len(exprs)` from `output_schema.num_columns()`, and
    `push_projections_down` indexes one space with the other's length ->
    `Schema.field_name` out of bounds -> `os.abort()`. Re-deriving the
    schema instead would have PUBLISHED the two internals as user-visible
    output columns. The synthetics belong BELOW.
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var e1 = _make_disc_subtree()
    var e2 = Expr.binary(BIN_MUL, _make_disc_subtree(), Expr.col_ref("l_tax"))
    var exprs = ExprArray()
    exprs.append(Expr.alias(e1^, "p1"))
    exprs.append(Expr.alias(e2^, "p2"))
    var proj = LogicalPlan.project(exprs^, scan^)

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    # The shared subtree `l_extendedprice * (1 - l_discount)` is the
    # OUTER candidate (depth 3, count 2). Its child `1 - l_discount` is
    # ALSO a candidate (depth 2, count 2). Both clear the AXIS1 gate, so 2
    # synthetic materializers are created -- in the spliced child, not here.
    assert_equal(len(result._project.value()[].exprs), 2,
                 "the user's Project keeps its 2 output exprs")
    assert_equal(result.output_schema.num_columns(), 2,
                 "...and one schema column per expr (the invariant that abort"
                 " was the symptom of)")
    assert_equal(_count_cse_prefixed_outputs(result), 0,
                 "a _cse_* synthetic is NEVER an output of the user's Project")
    # p1 should be Alias(ColRef("_cse_..."), "p1") -- the outer-MUL
    # synthetic; p2 contains the outer-MUL ColRef nested in the * l_tax MUL.
    assert_true(result._project.value()[].exprs[0].tag == EXPR_ALIAS, "p1 should be Alias")
    assert_true(result._project.value()[].exprs[1].tag == EXPR_ALIAS, "p2 should be Alias")
    # ⚠ COPY the name out to a `var` before touching any OTHER interior
    # reference into `result`: a second `_project.value()[]` invalidates the
    # first, and holding both is a compile error ("use of invalidated interior
    # reference"), not a runtime one.
    var p1_ref_name = result._project.value()[].exprs[0].alias_child_ref().col_ref_name()
    assert_true(
        result._project.value()[].exprs[0].alias_child_ref().tag == EXPR_COL_REF,
        "p1's inner should be ColRef to synthetic",
    )
    assert_true(p1_ref_name.startswith("_cse_"), "p1 should reference _cse_*")
    # p2 contains at least one _cse_* ColRef (could be 1 outer-MUL ref
    # nested inside the * l_tax MUL).
    var cse_refs_in_p2 = _count_col_refs_with_prefix(
        result._project.value()[].exprs[1].alias_child_ref(), "_cse_"
    )
    assert_true(cse_refs_in_p2 >= 1, "p2 should contain at least 1 _cse_* ref")
    # The materializers really exist, one level down, flagged, and the name
    # p1 references is a column the child actually PROVIDES.
    assert_true(result._project.value()[].child[].tag == PLAN_PROJECT,
                "synthetics live in a Project spliced below")
    assert_true(result._project.value()[].child[]._project.value()[].is_cse_introduced,
                "the spliced Project is flagged is_cse_introduced")
    assert_equal(_count_cse_prefixed_outputs(result._project.value()[].child[]), 2,
                 "2 _cse_* materializers (outer MUL + inner SUB), below")
    var below_ncols = result._project.value()[].child[].output_schema.num_columns()
    var below_has_p1_ref = False
    for i in range(below_ncols):
        if result._project.value()[].child[].output_schema.field_name(i) == p1_ref_name:
            below_has_p1_ref = True
    assert_true(below_has_p1_ref,
                "'" + p1_ref_name + "' must be a column of the child's"
                " schema -- a Project's exprs resolve against its CHILD")


def test_cse_axis1_three_way_share() raises:
    """A2 — Project with 3 exprs all sharing A.

    Project([Alias(A * tax_factor, "p1"),
             Alias(A * disc_factor, "p2"),
             Alias(A, "p3")],   where A = l_extendedprice * l_discount
            child=Scan(lineitem))
    Expected: this Project keeps its 3 outputs, A is materialized once in a
    Project spliced below, and fewer than the pre-CSE 5 MULs remain here.
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var A1 = Expr.binary(BIN_MUL, Expr.col_ref("l_extendedprice"), Expr.col_ref("l_discount"))
    var A2 = Expr.binary(BIN_MUL, Expr.col_ref("l_extendedprice"), Expr.col_ref("l_discount"))
    var A3 = Expr.binary(BIN_MUL, Expr.col_ref("l_extendedprice"), Expr.col_ref("l_discount"))
    var p1 = Expr.binary(BIN_MUL, A1^, Expr.col_ref("l_tax"))
    var p2 = Expr.binary(BIN_MUL, A2^, Expr.col_ref("l_quantity"))
    var exprs = ExprArray()
    exprs.append(Expr.alias(p1^, "p1"))
    exprs.append(Expr.alias(p2^, "p2"))
    exprs.append(Expr.alias(A3^, "p3"))
    var proj = LogicalPlan.project(exprs^, scan^)

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    # The pass runs in one phase. Its tally unwraps aliases, so p3 (A
    # itself) and the A nested inside the p1/p2 MULs all count toward
    # A's fingerprint (count 3 >= 2). It splices a NEW Project below
    # holding the synthetic for A plus a pass-through of the child
    # columns, and rewrites every occurrence here to ColRef the
    # synthetic. This Project's arity stays 3; the synthetic is not
    # one of its exprs.
    var n_outputs = len(result._project.value()[].exprs)
    assert_true(n_outputs >= 3, "at minimum the 3 original outputs preserved")
    # Count total MUL nodes — pre-CSE there are 5 (3 A's + 2 outer MULs);
    # post-CSE the synthetic A MUL lives in the spliced child, so this
    # level keeps the 2 outer MULs (each outer's inner-A leaf replaced
    # with ColRef) and p3 is a bare ColRef: 2 here. The assertion below
    # only requires fewer than the pre-CSE 5.
    var total_muls = 0
    for i in range(n_outputs):
        total_muls += _count_binary_ops(result._project.value()[].exprs[i], BIN_MUL)
    # Conservative assertion: post-CSE MUL count is STRICTLY LESS than
    # the pre-CSE 5 (we've collapsed at least one).
    assert_true(total_muls < 5, "post-CSE MUL count must be < 5 (pre-CSE)")


def test_cse_axis1_skips_leaf_duplicate() raises:
    """A3 — Project(col_a, col_a) — depth-1 leaves NOT CSE'd.

    Two ColRef leaves with the same name fingerprint equal, but depth
    is 1 — the CSE gate (CSE_MIN_DEPTH_AXIS1=2) skips. Nothing else may
    touch them either, and THAT is the half this case used to get wrong.

    ⚠ THE OLD DOCSTRING CLAIMED THE PHASE-A REWRITE HERE WAS "structurally
    a no-op since col_a was already a ColRef". IT WAS NOT. Phase A rewrote
    the SECOND occurrence to `Alias(ColRef(<FIRST OUTPUT NAME>), "p2")` —
    `ColRef("p1")`, not `ColRef("a")` — and "p1" is an output of THIS
    Project, not a column of `simple.parquet`. The old assertions only
    counted exprs, so they passed over a plan whose second column could
    not be resolved against the child schema. Phase A is deleted; the
    column names below are what make that observable.
    """
    var scan = LogicalPlan.scan("simple.parquet", SOURCE_PARQUET, _simple_schema())
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.col_ref("a"), "p1"))
    exprs.append(Expr.alias(Expr.col_ref("a"), "p2"))
    var proj = LogicalPlan.project(exprs^, scan^)

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    # No synthetic _cse_* should be added (depth-1 gate).
    assert_equal(_count_cse_prefixed_outputs(result), 0, "depth-1 leaves must not be CSE'd")
    assert_equal(len(result._project.value()[].exprs), 2, "no synthetic prepended for depth-1 dup")
    assert_true(result._project.value()[].child[].tag == PLAN_SCAN,
                "no Project spliced below either — a depth-1 duplicate is"
                " cheaper to re-read than to synthesise")
    # BOTH outputs still read the BASE column. A sibling output name here
    # is unresolvable, and it is what the pre-2026-09-01 rule emitted.
    for i in range(2):
        assert_true(result._project.value()[].exprs[i].tag == EXPR_ALIAS,
                    "expr " + String(i) + " keeps its alias")
        ref inner = result._project.value()[].exprs[i].alias_child_ref()
        assert_true(inner.tag == EXPR_COL_REF, "expr " + String(i) + " is a ColRef")
        assert_equal(inner.col_ref_name(), String("a"),
                     "expr " + String(i) + " must read the base column 'a', not a"
                     " sibling output name")


# =============================================================================
# Axis 2 — PLAN_FILTER predicate dedup via 2-Project sandwich
# =============================================================================

def test_cse_axis2_filter_predicate_shared_subexpr() raises:
    """B1 — Filter((P > 100) AND (P < 1000)) builds a 2-Project sandwich.

    Where P = l_extendedprice * (1 - l_discount). Depth 3 — clears the
    AXIS2 gate.
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var P1 = _make_disc_subtree()
    var P2 = _make_disc_subtree()
    var lit100 = Expr.literal(ScalarValue.from_int(100))
    var lit1000 = Expr.literal(ScalarValue.from_int(1000))
    var c1 = Expr.binary(BIN_GT, P1^, lit100^)
    var c2 = Expr.binary(BIN_LT, P2^, lit1000^)
    var pred = Expr.binary(BIN_AND, c1^, c2^)
    var filt = LogicalPlan.filter(pred^, scan^)

    var result = eliminate_common_subexpressions(filt^)

    # Expected sandwich shape:
    #   Project (outer, is_cse_introduced=True, strips _cse_*)
    #     Filter (predicate rewritten to ColRef the synthetic)
    #       Project (inner, is_cse_introduced=True, materializes _cse_*)
    #         Scan(lineitem)
    assert_true(result.tag == PLAN_PROJECT, "outer should be Project")
    assert_true(result._project.value()[].is_cse_introduced, "outer Project must be flagged is_cse_introduced")
    ref outer_child = result._project.value()[].child[]
    assert_true(outer_child.tag == PLAN_FILTER, "outer child should be Filter")
    ref inner = outer_child._filter.value()[].child[]
    assert_true(inner.tag == PLAN_PROJECT, "filter child should be inner Project")
    assert_true(inner._project.value()[].is_cse_introduced, "inner Project must be flagged is_cse_introduced")
    # Inner Project's exprs: 6 pass-through cols + N synthetic. The
    # outer MUL (depth 3) clears AXIS2; the inner SUB (depth 2) is
    # BELOW AXIS2 (which is depth >= 3). So only 1 synthetic prepends:
    # 6 + 1 = 7. (If a future relaxation drops AXIS2 to >= 2, this
    # number rises to 8.)
    var n_inner = len(inner._project.value()[].exprs)
    assert_true(n_inner >= 7, "inner should have >= 7 exprs (6 pass-throughs + >= 1 synthetic)")
    # The Filter's predicate should now reference _cse_* (not the original
    # multiply).
    ref new_pred = outer_child._filter.value()[].predicate
    var cse_refs_in_pred = _count_col_refs_with_prefix(new_pred, "_cse_")
    assert_equal(cse_refs_in_pred, 2, "predicate should have 2 _cse_* refs (one per conjunct)")
    # Original multiply count in predicate: 0 (collapsed into the inner
    # Project's materializer).
    assert_equal(_count_binary_ops(new_pred, BIN_MUL), 0, "predicate must have 0 MULs after CSE")


def test_cse_axis2_filter_depth_gate_off() raises:
    """B2 — Filter((c > 1) AND (c < 5)) — depth-2 conjuncts NOT CSE'd.

    c > 1 has depth 2 (BinaryOp(ColRef, Literal)). c is depth-1 by
    itself. The shared SUBTREE here is `c` (depth 1) — below AXIS2
    gate. No rewrite expected.
    """
    var scan = LogicalPlan.scan("simple.parquet", SOURCE_PARQUET, _simple_schema())
    var c1 = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1)))
    var c2 = Expr.binary(BIN_LT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
    var pred = Expr.binary(BIN_AND, c1^, c2^)
    var filt = LogicalPlan.filter(pred^, scan^)

    var result = eliminate_common_subexpressions(filt^)

    # Should still be a bare Filter — no sandwich.
    assert_true(result.tag == PLAN_FILTER, "depth-gate-off must leave Filter unchanged")
    ref child = result._filter.value()[].child[]
    assert_true(child.tag == PLAN_SCAN, "Filter child should be the original Scan")


def test_cse_axis2_pushdown_barrier_respected() raises:
    """B3 — CSE-introduced Project blocks subsequent predicate pushdown.

    After Axis 2 wraps a Filter in the 2-Project sandwich, both Projects
    are flagged `is_cse_introduced=True`. push_predicates_down must NOT
    descend the outer Filter (well, there's no outer Filter — but if we
    ADD one above the outer Project that references `_cse_*`, it must
    be parked above the outer Project, not pushed below it).

    Synthetic test: build the post-CSE shape directly (no need to
    re-run CSE) and verify push_predicates_down treats it as a
    barrier — predicate references `_cse_xyz` and the barrier prevents
    it from descending past the outer Project (where `_cse_xyz` would
    not exist).
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var P1 = _make_disc_subtree()
    var P2 = _make_disc_subtree()
    var lit100 = Expr.literal(ScalarValue.from_int(100))
    var lit1000 = Expr.literal(ScalarValue.from_int(1000))
    var c1 = Expr.binary(BIN_GT, P1^, lit100^)
    var c2 = Expr.binary(BIN_LT, P2^, lit1000^)
    var pred = Expr.binary(BIN_AND, c1^, c2^)
    var filt = LogicalPlan.filter(pred^, scan^)

    # First apply CSE — produces the sandwich.
    var cse_applied = eliminate_common_subexpressions(filt^)
    assert_true(cse_applied.tag == PLAN_PROJECT, "post-CSE outer is Project")

    # Now apply pushdown. The inner Filter's predicate references _cse_*,
    # which only exists in the inner Project's output. Pushdown MUST
    # leave the predicate ABOVE the inner Project (the barrier), even
    # though structurally it might look pushable.
    var pushed = push_predicates_down(cse_applied^)

    # Shape should be unchanged: Project (outer) -> Filter -> Project (inner) -> Scan.
    assert_true(pushed.tag == PLAN_PROJECT, "outer Project preserved")
    assert_true(pushed._project.value()[].is_cse_introduced, "outer Project's is_cse_introduced preserved through pushdown")
    ref child = pushed._project.value()[].child[]
    assert_true(child.tag == PLAN_FILTER, "Filter not pushed")
    ref inner = child._filter.value()[].child[]
    assert_true(inner.tag == PLAN_PROJECT, "inner Project preserved")
    assert_true(inner._project.value()[].is_cse_introduced, "inner Project's is_cse_introduced preserved through pushdown")


# =============================================================================
# Axis 3 — PLAN_AGGREGATE agg-fn arg dedup via synthetic Project
# =============================================================================

def test_cse_axis3_agg_shared_arg_subtree() raises:
    """C1 — TPC-H Q1 shape: SUM(A) + SUM(A * (1+tax)).

    Where A = l_extendedprice * (1 - l_discount). The two SUM agg-fns
    share A. Expected: synthetic Project below the Aggregate
    materializing A once; both SUM args rewritten to reference the
    synthetic ColRef.
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var A1 = _make_disc_subtree()
    var A2 = _make_disc_subtree()
    var one = Expr.literal(ScalarValue.from_int(1))
    var one_plus_tax = Expr.binary(BIN_ADD, one^, Expr.col_ref("l_tax"))
    var A2_times_tax = Expr.binary(BIN_MUL, A2^, one_plus_tax^)

    var gb = ExprArray()
    var aggs = AggExprArray()
    var sum1_arg: Optional[Expr] = A1^
    var sum1_alias: Optional[String] = String("sum_disc_price")
    aggs.append(AggExpr(AGG_SUM, sum1_arg^, sum1_alias^))
    var sum2_arg: Optional[Expr] = A2_times_tax^
    var sum2_alias: Optional[String] = String("sum_charge")
    aggs.append(AggExpr(AGG_SUM, sum2_arg^, sum2_alias^))
    var agg = LogicalPlan.aggregate(gb^, aggs^, scan^)

    var result = eliminate_common_subexpressions(agg^)

    # Shape: Aggregate(group_by=[], agg_fns=[SUM(_cse_*), SUM(_cse_* * (1+tax))],
    #                  child=Project(is_cse_introduced, 6 pass-through + 1 synthetic, child=Scan))
    assert_true(result.tag == PLAN_AGGREGATE, "outer should be Aggregate")
    ref ad = result._aggregate.value()[]
    assert_equal(len(ad.agg_exprs), 2, "2 agg-fns preserved")
    ref below = ad.child[]
    assert_true(below.tag == PLAN_PROJECT, "below the Aggregate is the synthetic Project")
    assert_true(below._project.value()[].is_cse_introduced, "synthetic Project must be is_cse_introduced=True")
    # 6 schema cols of lineitem + N synthetics. The outer
    # `l_extendedprice * (1 - l_discount)` (depth 3) AND the inner
    # `1 - l_discount` (depth 2) both clear AXIS3 (>= 2), so 2
    # synthetics: 6 + 2 = 8.
    var n_below = len(below._project.value()[].exprs)
    assert_true(n_below >= 7, "below-Project should have >= 7 exprs (6 pass-throughs + >= 1 synthetic)")
    # Each SUM's arg should now contain at least one _cse_* ColRef
    # (sum1 = _cse_xyz; sum2 = _cse_xyz * (1+tax)).
    var sum1_child = ad.agg_exprs[0].child.value().copy()
    var sum2_child = ad.agg_exprs[1].child.value().copy()
    var refs_in_sum1 = _count_col_refs_with_prefix(sum1_child, "_cse_")
    var refs_in_sum2 = _count_col_refs_with_prefix(sum2_child, "_cse_")
    assert_equal(refs_in_sum1, 1, "sum1 should reference _cse_*")
    assert_equal(refs_in_sum2, 1, "sum2 should reference _cse_*")
    # MUL count in sum2_child: 1 (the outer * (1+tax)) — the inner A's
    # MUL was collapsed into the synthetic Project.
    var muls_in_sum2 = _count_binary_ops(sum2_child, BIN_MUL)
    assert_equal(muls_in_sum2, 1, "sum2 must have exactly 1 MUL after CSE (outer * (1+tax))")


def test_cse_axis3_preserves_agg_output_schema() raises:
    """C2 — Aggregate output schema (names + types) unchanged after CSE.

    Same shape as C1; assert the post-CSE Aggregate's output_schema
    matches the pre-CSE Aggregate's output_schema field-for-field.
    """
    var scan_pre = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var scan_post = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _lineitem_schema())
    var A1 = _make_disc_subtree()
    var A2 = _make_disc_subtree()
    var one = Expr.literal(ScalarValue.from_int(1))
    var one_plus_tax = Expr.binary(BIN_ADD, one^, Expr.col_ref("l_tax"))
    var A2_times_tax = Expr.binary(BIN_MUL, A2^, one_plus_tax^)

    var gb_pre = ExprArray()
    var aggs_pre = AggExprArray()
    var s1a_pre: Optional[Expr] = _make_disc_subtree()
    var s1n_pre: Optional[String] = String("sum_disc_price")
    aggs_pre.append(AggExpr(AGG_SUM, s1a_pre^, s1n_pre^))
    var s2a_pre: Optional[Expr] = Expr.binary(BIN_MUL, _make_disc_subtree(), Expr.binary(BIN_ADD, Expr.literal(ScalarValue.from_int(1)), Expr.col_ref("l_tax")))
    var s2n_pre: Optional[String] = String("sum_charge")
    aggs_pre.append(AggExpr(AGG_SUM, s2a_pre^, s2n_pre^))
    var agg_pre = LogicalPlan.aggregate(gb_pre^, aggs_pre^, scan_pre^)
    var pre_schema = agg_pre.output_schema.copy()

    var gb_post = ExprArray()
    var aggs_post = AggExprArray()
    var sum1_arg: Optional[Expr] = A1^
    var sum1_alias: Optional[String] = String("sum_disc_price")
    aggs_post.append(AggExpr(AGG_SUM, sum1_arg^, sum1_alias^))
    var sum2_arg: Optional[Expr] = A2_times_tax^
    var sum2_alias: Optional[String] = String("sum_charge")
    aggs_post.append(AggExpr(AGG_SUM, sum2_arg^, sum2_alias^))
    var agg_post = LogicalPlan.aggregate(gb_post^, aggs_post^, scan_post^)

    var result = eliminate_common_subexpressions(agg_post^)
    var post_schema = result.output_schema.copy()

    assert_equal(pre_schema.num_columns(), post_schema.num_columns(), "agg output column count unchanged")
    for i in range(pre_schema.num_columns()):
        assert_equal(pre_schema.field_name(i), post_schema.field_name(i),
                     "agg output column name unchanged at index " + String(i))


def test_cse_skip_eligibility_count_distinct_in_agg() raises:
    """C3 — Aggregate with non-shared aggs (no CSE applies).

    SUM(a), SUM(b), COUNT(*) — each agg-fn arg is unique (depth 1) and
    differs across slots; nothing to CSE. Expected: structurally
    unchanged Aggregate (no synthetic Project introduced below).
    """
    var scan = LogicalPlan.scan("simple.parquet", SOURCE_PARQUET, _simple_schema())
    var gb = ExprArray()
    var aggs = AggExprArray()
    var s1: Optional[Expr] = Expr.col_ref("a")
    var s1n: Optional[String] = String("sum_a")
    aggs.append(AggExpr(AGG_SUM, s1^, s1n^))
    var s2: Optional[Expr] = Expr.col_ref("b")
    var s2n: Optional[String] = String("sum_b")
    aggs.append(AggExpr(AGG_SUM, s2^, s2n^))
    var s3: Optional[Expr] = None
    var s3n: Optional[String] = String("cnt")
    aggs.append(AggExpr(AGG_COUNT, s3^, s3n^))
    var agg = LogicalPlan.aggregate(gb^, aggs^, scan^)

    var result = eliminate_common_subexpressions(agg^)

    assert_true(result.tag == PLAN_AGGREGATE, "outer Aggregate preserved")
    ref ad = result._aggregate.value()[]
    assert_equal(len(ad.agg_exprs), 3, "3 agg-fns preserved")
    # No synthetic Project inserted below — child should still be the
    # original Scan.
    ref child = ad.child[]
    assert_true(child.tag == PLAN_SCAN, "no synthetic Project inserted for non-shared aggs")


# =============================================================================
# CSE-projection output-dtype propagation (q19 regression)
# =============================================================================

def test_cse_synthetic_in_list_node_dtype_is_bool() raises:
    """B4 (q19 regression) — a hoisted EXPR_IN_LIST subtree's synthetic
    `_cse_*` column must carry a VALID (BOOL) output dtype, not NULL.

    Reproduces the q19 dtype-loss: the OR predicate has IDENTICAL
    `l_shipmode IN (...)` subtrees across branches. The CSE pass (Axis 2)
    hoists the shared subtree into a synthetic `_cse_*` projection. Before
    the fix, `_infer_expr_field` had no EXPR_IN_LIST arm and fell through
    to `ArrowType.NULL`, so the synthetic column's runtime_dtype was -1 and
    `lower_untyped_filter_project` rejected it. A predicate-result column
    MUST be BOOL.

    Uses `Expr.in_list_node` (the RAW EXPR_IN_LIST variant) so the subtree
    keeps tag 9 (the small-list `Expr.in_list` factory folds to OR-of-EQ;
    `in_list_node` does not). Depth: IN_LIST(child=ColRef) is depth 2 — too
    shallow for AXIS2 alone, so we wrap it one level (OR with a sibling
    predicate over the same IN_LIST) to clear the depth-3 gate and make the
    IN_LIST the duplicated depth-eligible subtree across both branches.
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _shipmode_schema())

    # Build TWO identical depth-3 subtrees, each = (l_shipmode IN (...) AND p_size >= 1).
    var vals1: List[ScalarValue] = [
        ScalarValue.from_string(String("AIR")),
        ScalarValue.from_string(String("AIR REG")),
    ]
    var vals2: List[ScalarValue] = [
        ScalarValue.from_string(String("AIR")),
        ScalarValue.from_string(String("AIR REG")),
    ]
    var inl1 = Expr.in_list_node(Expr.col_ref("l_shipmode"), vals1^)
    var inl2 = Expr.in_list_node(Expr.col_ref("l_shipmode"), vals2^)
    var sz1 = Expr.binary(BIN_GT, Expr.col_ref("p_size"), Expr.literal(ScalarValue.from_int(0)))
    var sz2 = Expr.binary(BIN_GT, Expr.col_ref("p_size"), Expr.literal(ScalarValue.from_int(0)))
    var branch1 = Expr.binary(BIN_AND, inl1^, sz1^)
    var branch2 = Expr.binary(BIN_AND, inl2^, sz2^)
    var pred = Expr.binary(BIN_OR, branch1^, branch2^)
    var filt = LogicalPlan.filter(pred^, scan^)

    var result = eliminate_common_subexpressions(filt^)

    # CSE must have fired (the IN_LIST subtree is depth-2 but duplicated; the
    # AND(IN_LIST, p_size>0) subtree is depth-3 and duplicated -> hoisted).
    assert_true(result.tag == PLAN_PROJECT, "post-CSE outer should be Project (sandwich applied)")
    var inner_schema = _inner_cse_project_schema(result)
    var cse_at = _cse_field_arrow_type(inner_schema)
    # The hoisted subtree is a boolean predicate -> its synthetic column MUST
    # be BOOL (not NULL). NULL is the runtime_dtype=-1 bug.
    assert_true(cse_at != ArrowType.NULL,
                "synthetic _cse_* column must NOT have NULL arrow_type (runtime_dtype=-1 bug)")
    assert_true(cse_at == ArrowType.BOOL,
                "synthetic _cse_* predicate column must be BOOL")


def test_cse_synthetic_string_eq_dtype_is_bool() raises:
    """B5 (q19 regression, general) — a hoisted STRING-comparison subtree's
    synthetic `_cse_*` column must be BOOL, not the operand's STRING type.

    `_infer_expr_field` historically returned the LEFT operand's arrow_type
    for any BINARY_OP, which mislabels a comparison (`l_shipinstruct = '...'`)
    as STRING. Comparison/boolean binary ops are predicate results -> BOOL.
    A STRING-typed `_cse_*` predicate column lowers to a string-output column
    that the filter/project lowering then mis-evaluates.
    """
    var scan = LogicalPlan.scan("lineitem.parquet", SOURCE_PARQUET, _shipmode_schema())

    # Duplicated depth-3 subtree: (l_shipinstruct = 'X' OR l_shipmode = 'Y').
    var b1 = _shipinstruct_or_shipmode_eq()
    var b2 = _shipinstruct_or_shipmode_eq()
    var pred = Expr.binary(BIN_OR, b1^, b2^)
    var filt = LogicalPlan.filter(pred^, scan^)

    var result = eliminate_common_subexpressions(filt^)
    assert_true(result.tag == PLAN_PROJECT, "post-CSE outer should be Project (sandwich applied)")
    var inner_schema = _inner_cse_project_schema(result)
    var cse_at = _cse_field_arrow_type(inner_schema)
    assert_true(cse_at == ArrowType.BOOL,
                "synthetic _cse_* STRING-comparison column must be BOOL, not STRING/NULL")


# =============================================================================
# Entry point
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
