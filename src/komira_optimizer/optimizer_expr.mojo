# =============================================================================
# Optimizer expression rules
# =============================================================================
#
# Rule 5: Constant folding — evaluate expressions with no column references
#   at plan time (Literal(2) + Literal(3) -> Literal(5))
#
# Rule 9: Predicate simplification — simplify boolean expressions
#   (x AND TRUE -> x, NOT NOT x -> x, etc.)
#
# Rule 18: Common subexpression elimination (CSE) — hoist a subtree repeated
#   within one Project's outputs, one Filter's AND-conjuncts or one
#   Aggregate's aggregate-function arguments into a synthetic Project below
#   the node, and reference it by column
#   (`eliminate_common_subexpressions`)
#
# Rule 21: IN clause rewrite — collapse an OR chain of equalities on one
#   column (col = 1 OR col = 2) into one IN list (`rewrite_in_clauses`)
#
# Also here: the matcher from an Expr to a kernel template id
# (`_match_expr_to_kernel_template`).
# =============================================================================

from std.collections import Dict, Set
from std.memory import OwnedPointer

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.scalar_value import ScalarValue
# UdfData import removed — CSE no longer
# threads UDF aggs through aggregate-rewriting.
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_STRING_OP,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_EXTRACT,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)
from komira_plan_expr.agg_expr import AggExpr
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
)
from komira_plan_ir.plan_helpers import (
    _copy_schema,
    _copy_expr_array,
    _copy_agg_expr_array,
    _expr_fingerprint,
    _collect_expr_columns,
    _take_filter_child,
    _take_project_child,
    _take_aggregate_child,
    _take_join_left,
    _take_join_right,
    _take_sort_child,
    _take_limit_child,
    _take_distinct_child,
    _take_topn_child,
)
# Tier 1 Expr → kernel template
# matcher. The matcher reads from this comptime registry of stable template
# IDs (0 = INTERPRETED, 1..36 = phase-3.a-active templates). New templates
# added in 3.b extend the ID space.
from komira_kernels.expr_kernel_templates import (
    EXPR_TEMPLATE_INTERPRETED,
    EXPR_TEMPLATE_ADD_F64_COLCOL,
    EXPR_TEMPLATE_SUB_F64_COLCOL,
    EXPR_TEMPLATE_MUL_F64_COLCOL,
    EXPR_TEMPLATE_DIV_F64_COLCOL,
    EXPR_TEMPLATE_ADD_I64_COLCOL,
    EXPR_TEMPLATE_SUB_I64_COLCOL,
    EXPR_TEMPLATE_MUL_I64_COLCOL,
    EXPR_TEMPLATE_DIV_I64_COLCOL,
    EXPR_TEMPLATE_ADD_F32_COLCOL,
    EXPR_TEMPLATE_SUB_F32_COLCOL,
    EXPR_TEMPLATE_MUL_F32_COLCOL,
    EXPR_TEMPLATE_DIV_F32_COLCOL,
    EXPR_TEMPLATE_ADD_I32_COLCOL,
    EXPR_TEMPLATE_SUB_I32_COLCOL,
    EXPR_TEMPLATE_MUL_I32_COLCOL,
    EXPR_TEMPLATE_DIV_I32_COLCOL,
    EXPR_TEMPLATE_ADD_F64_COLLIT,
    EXPR_TEMPLATE_SUB_F64_COLLIT,
    EXPR_TEMPLATE_MUL_F64_COLLIT,
    EXPR_TEMPLATE_DIV_F64_COLLIT,
    EXPR_TEMPLATE_ADD_I64_COLLIT,
    EXPR_TEMPLATE_SUB_I64_COLLIT,
    EXPR_TEMPLATE_MUL_I64_COLLIT,
    EXPR_TEMPLATE_DIV_I64_COLLIT,
    EXPR_TEMPLATE_GT_F64_COLLIT,
    EXPR_TEMPLATE_GE_F64_COLLIT,
    EXPR_TEMPLATE_LT_F64_COLLIT,
    EXPR_TEMPLATE_LE_F64_COLLIT,
    EXPR_TEMPLATE_EQ_F64_COLLIT,
    EXPR_TEMPLATE_NE_F64_COLLIT,
    EXPR_TEMPLATE_GT_I64_COLLIT,
    EXPR_TEMPLATE_GE_I64_COLLIT,
    EXPR_TEMPLATE_LT_I64_COLLIT,
    EXPR_TEMPLATE_LE_I64_COLLIT,
    EXPR_TEMPLATE_EQ_I64_COLLIT,
    EXPR_TEMPLATE_NE_I64_COLLIT,
    # Phase 3.b additions (IDs 37..65).
    EXPR_TEMPLATE_CAST_F64_TO_F32,
    EXPR_TEMPLATE_CAST_F32_TO_F64,
    EXPR_TEMPLATE_CAST_I64_TO_I32,
    EXPR_TEMPLATE_CAST_I32_TO_I64,
    EXPR_TEMPLATE_CAST_F64_TO_I64,
    EXPR_TEMPLATE_CAST_I64_TO_F64,
    EXPR_TEMPLATE_CAST_I32_TO_F64,
    EXPR_TEMPLATE_CAST_F32_TO_I64,
    EXPR_TEMPLATE_IS_NULL_F64,
    EXPR_TEMPLATE_IS_NOT_NULL_F64,
    EXPR_TEMPLATE_IS_NULL_F32,
    EXPR_TEMPLATE_IS_NOT_NULL_F32,
    EXPR_TEMPLATE_IS_NULL_I64,
    EXPR_TEMPLATE_IS_NOT_NULL_I64,
    EXPR_TEMPLATE_IS_NULL_I32,
    EXPR_TEMPLATE_IS_NOT_NULL_I32,
    EXPR_TEMPLATE_AND_BOOL,
    EXPR_TEMPLATE_OR_BOOL,
    EXPR_TEMPLATE_NOT_BOOL,
    EXPR_TEMPLATE_NEGATE_F64,
    EXPR_TEMPLATE_NEGATE_F32,
    EXPR_TEMPLATE_NEGATE_I64,
    EXPR_TEMPLATE_NEGATE_I32,
    EXPR_TEMPLATE_MOD_I64_COLCOL,
    EXPR_TEMPLATE_MOD_I32_COLCOL,
)


# =============================================================================
# Rule 5: Constant Folding
# =============================================================================

def fold_constants(var plan: LogicalPlan) -> LogicalPlan:
    """Apply constant folding to all expressions in the plan tree.

    Wrapper around `fold_constants_inplace` for legacy `var -> ret` callers.
    """
    fold_constants_inplace(plan)
    return plan^


def fold_constants_inplace(mut plan: LogicalPlan):
    """In-place constant folding (avoids an O(n^2) tree rebuild).

    Recurses through OwnedPointer-held children IN PLACE (no allocation),
    and mutates predicate / expression fields directly. The Expr-level
    `_fold_expr` is still consume-and-return (Expr is the unit of
    transformation), but no new LogicalPlan node is constructed -- the
    existing OwnedPointer wrappers and Schema fields are reused.

    DuckDB pattern reference:
    `duckdb/src/optimizer/expression_rewriter.cpp:63-72`
    (`VisitOperator` mutates the operator in place).
    """
    if plan.tag == PLAN_SCAN:
        if plan._scan and plan._scan.value()[].filter:
            var old_filter = plan._scan.value()[].filter.value().copy()
            var folded = _fold_expr(old_filter^)
            plan._scan.value()[].filter = folded^

    elif plan.tag == PLAN_FILTER:
        fold_constants_inplace(plan._filter.value()[].child[])
        var pred_copy = plan._filter.value()[].predicate.copy()
        var folded_pred = _fold_expr(pred_copy^)
        plan._filter.value()[].predicate = folded_pred^

    elif plan.tag == PLAN_PROJECT:
        fold_constants_inplace(plan._project.value()[].child[])
        # Fold each expression in place. ExprArray rebuild is local to
        # the ProjectData; no parent Schema rebuild.
        var new_exprs = ExprArray()
        for i in range(len(plan._project.value()[].exprs)):
            var expr_copy = plan._project.value()[].exprs[i].copy()
            new_exprs.append(_fold_expr(expr_copy^))
        plan._project.value()[].exprs = new_exprs^

    elif plan.tag == PLAN_AGGREGATE:
        fold_constants_inplace(plan._aggregate.value()[].child[])
        _rewrite_agg_and_residual_sites[_SITE_RULE_FOLD](plan)

    elif plan.tag == PLAN_JOIN:
        fold_constants_inplace(plan._join.value()[].left[])
        fold_constants_inplace(plan._join.value()[].right[])
        _rewrite_agg_and_residual_sites[_SITE_RULE_FOLD](plan)

    elif plan.tag == PLAN_SORT:
        fold_constants_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        fold_constants_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        fold_constants_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        fold_constants_inplace(plan._topn.value()[].child[])
    # PLAN_PARTITION_BY / PLAN_PARTITION_TOPN / PLAN_ASOF_JOIN: untouched
    # by the original; preserve that behavior.


def _fold_expr(var expr: Expr) -> Expr:
    """Recursively fold constant expressions.

    Evaluates binary operations on two literals at plan time.
    Simplifies logical operations with TRUE/FALSE operands.
    """
    if expr.tag == EXPR_BINARY_OP:
        var left = _fold_expr(expr.binary_left().copy())
        var right = _fold_expr(expr.binary_right().copy())
        var op = expr.binary_op()

        # Both operands are literals -- evaluate at plan time
        if left.tag == EXPR_LITERAL and right.tag == EXPR_LITERAL:
            var lv = left.literal_value()
            var rv = right.literal_value()

            # Integer arithmetic
            if lv.is_int() and rv.is_int():
                # ⛔⛔ AN OVERFLOWING FOLD IS NOT FOLDED (2026-09-25).
                # This used to be plain `Int64` arithmetic, so `SELECT
                # 9223372036854775807 + 1` answered -9223372036854775808 (and
                # `* 2` answered -2) with a success code -- MEASURED at the SQL
                # door, over a parquet relation and FROM-less alike -- while
                # the same `+` over a COLUMN raises DuckDB's `Out of Range
                # Error: Overflow in addition of INT64 (...)!` (the checked
                # kernels). The fold is done in 128 bits
                # and an out-of-range result leaves the node UNFOLDED, so the
                # checked runtime kernel -- the one place that owns the error
                # sentence -- raises it. A fold that fits is unchanged.
                if op == BIN_ADD or op == BIN_SUB or op == BIN_MUL:
                    var a = lv.int_val.cast[DType.int128]()
                    var b = rv.int_val.cast[DType.int128]()
                    var r = a * b
                    if op == BIN_ADD:
                        r = a + b
                    elif op == BIN_SUB:
                        r = a - b
                    if (
                        r > Int64.MAX.cast[DType.int128]()
                        or r < Int64.MIN.cast[DType.int128]()
                    ):
                        return Expr.binary(op, left^, right^)
                    return Expr.literal(
                        ScalarValue.from_int(Int(r.cast[DType.int64]()))
                    )
                elif op == BIN_EQ:
                    return Expr.literal(ScalarValue.from_bool(lv.int_val == rv.int_val))
                elif op == BIN_NE:
                    return Expr.literal(ScalarValue.from_bool(lv.int_val != rv.int_val))
                elif op == BIN_LT:
                    return Expr.literal(ScalarValue.from_bool(lv.int_val < rv.int_val))
                elif op == BIN_LE:
                    return Expr.literal(ScalarValue.from_bool(lv.int_val <= rv.int_val))
                elif op == BIN_GT:
                    return Expr.literal(ScalarValue.from_bool(lv.int_val > rv.int_val))
                elif op == BIN_GE:
                    return Expr.literal(ScalarValue.from_bool(lv.int_val >= rv.int_val))

            # Float arithmetic
            if lv.is_float() and rv.is_float():
                if op == BIN_ADD:
                    return Expr.literal(ScalarValue.from_float(lv.float_val + rv.float_val))
                elif op == BIN_SUB:
                    return Expr.literal(ScalarValue.from_float(lv.float_val - rv.float_val))
                elif op == BIN_MUL:
                    return Expr.literal(ScalarValue.from_float(lv.float_val * rv.float_val))

            # Boolean logic: TRUE AND x -> x, FALSE AND x -> FALSE, etc
            if lv.is_bool() and rv.is_bool():
                if op == BIN_AND:
                    return Expr.literal(ScalarValue.from_bool(lv.bool_val and rv.bool_val))
                elif op == BIN_OR:
                    return Expr.literal(ScalarValue.from_bool(lv.bool_val or rv.bool_val))

        # Partial folding: TRUE AND x -> x, x AND TRUE -> x, etc
        if op == BIN_AND:
            if _is_bool_literal(left, True):
                return right^
            if _is_bool_literal(right, True):
                return left^
            if _is_bool_literal(left, False):
                return Expr.literal(ScalarValue.from_bool(False))
            if _is_bool_literal(right, False):
                return Expr.literal(ScalarValue.from_bool(False))

        if op == BIN_OR:
            if _is_bool_literal(left, True):
                return Expr.literal(ScalarValue.from_bool(True))
            if _is_bool_literal(right, True):
                return Expr.literal(ScalarValue.from_bool(True))
            if _is_bool_literal(left, False):
                return right^
            if _is_bool_literal(right, False):
                return left^

        return Expr.binary(op, left^, right^)

    elif expr.tag == EXPR_UNARY_OP:
        var child = _fold_expr(expr.unary_child().copy())
        var op = expr.unary_op()

        # NOT on a boolean literal
        if child.tag == EXPR_LITERAL:
            var cv = child.literal_value()
            if cv.is_bool() and op == UN_NOT:
                return Expr.literal(ScalarValue.from_bool(not cv.bool_val))
            if cv.is_int() and op == UN_NEGATE:
                # ⛔ -(INT64_MIN) IS NOT AN INT64 (the unary case of the binary fix,
                # 2026-09-25). The binary arm above leaves an overflowing fold
                # UNFOLDED; this arm negated in plain Int64, so
                # `SELECT -(-9223372036854775808)` answered -9223372036854775808
                # with a success code (DuckDB 1.5.3: HUGEINT
                # 9223372036854775808). Leave it for the checked runtime negate,
                # which raises DuckDB's own "Overflow in negation" sentence.
                if cv.int_val == Int64.MIN:
                    return Expr.unary(op, child^)
                return Expr.literal(ScalarValue.from_int(Int(-cv.int_val)))

        return Expr.unary(op, child^)

    elif expr.tag == EXPR_CAST:
        # ⛔⛔ `cast_preserving_arrow`, NOT `Expr.cast(child, cast_target())` —
        # AND THIS IS THE BUG THAT HELPER WAS ADDED TO PREVENT, STILL LIVE AT
        # SIX REWRITE SITES UNTIL 2026-09-17.
        #
        # `cast_target()` is a bare `DType`. Every TIMESTAMP unit and DATE32
        # shares its physical DType with a plain integer — TIMESTAMP_S/_MS/_US/
        # _NS are ALL `int64`, DATE32 is `int32` — so rebuilding from the DType
        # alone silently RESETS `target_arrow` to the integer, and the node
        # stops being a temporal cast at all. DECIMAL128 loses its
        # precision/scale the same way.
        #
        # MEASURED 2026-09-17. `make_timestamp_ms(m)`
        # lowers to `CAST(CAST(m AS TIMESTAMP_MS) AS TIMESTAMP_US)`, whose
        # outer cast is the executor's unit-conversion arm (x1000). After these
        # rewrites both casts read INT64 -> INT64, the scale arm was never
        # reached, and the query answered the input UNSCALED: row 0 came back
        # -59999999 where DuckDB v1.5.5 answers -59999999000. A 1000x wrong
        # instant with a success code.
        #
        # ⭐ THE CHANGE IS A NO-OP FOR EVERY ORDINARY NUMERIC CAST, which is why
        # it is safe to make at all six sites at once: `cast_preserving_arrow`'s
        # own docstring records that for those the round-trip is byte-identical,
        # because `CastData.__init__` derives `target_arrow` from the DType
        # anyway. It differs ONLY for the temporal and decimal targets — i.e.
        # exactly the cases that are broken today.
        var child = _fold_expr(expr.cast_child().copy())
        return Expr.cast_preserving_arrow(child^, expr)

    elif expr.tag == EXPR_ALIAS:
        var child = _fold_expr(expr.alias_child().copy())
        return Expr.alias(child^, expr.alias_name())

    # Literals, ColRef, ColIdx -- return unchanged
    return expr^


@always_inline
def _is_bool_literal(expr: Expr, value: Bool) -> Bool:
    """Check if an expression is a boolean literal with the given value."""
    if expr.tag == EXPR_LITERAL:
        var sv = expr.literal_value()
        return sv.is_bool() and sv.bool_val == value
    return False


# The expression rule `_rewrite_agg_and_residual_sites` applies.
comptime _SITE_RULE_FOLD: Int = 0
comptime _SITE_RULE_SIMPLIFY: Int = 1
comptime _SITE_RULE_IN: Int = 2


@always_inline
def _apply_site_rule[rule: Int](var expr: Expr) -> Expr:
    comptime if rule == _SITE_RULE_FOLD:
        return _fold_expr(expr^)
    elif rule == _SITE_RULE_SIMPLIFY:
        return _simplify_expr(expr^)
    else:
        return _rewrite_in_expr(expr^)


def _rewrite_optional_site[rule: Int](mut slot: Optional[Expr]):
    if slot:
        var e = slot.take()
        slot = _apply_site_rule[rule](e^)


def _rewrite_agg_and_residual_sites[rule: Int](mut plan: LogicalPlan):
    """Apply one expression rule to every argument slot of an Aggregate's
    aggregate functions, or to a Join's residual condition, in place.

    An Aggregate's group-by keys are left as they are: the output column name
    of a key that is not a plain column is inferred from the expression's
    kind, so a rewritten key (an OR chain becoming an IN list) would infer a
    different name than the one the Aggregate's schema already carries.
    """
    if plan.tag == PLAN_AGGREGATE:
        ref aggs = plan._aggregate.value()[].agg_exprs
        for i in range(len(aggs)):
            ref agg = aggs[i]
            _rewrite_optional_site[rule](agg.child)
            _rewrite_optional_site[rule](agg.child1)
            _rewrite_optional_site[rule](agg.child2)
            _rewrite_optional_site[rule](agg.child3)
    elif plan.tag == PLAN_JOIN:
        ref j = plan._join.value()[]
        if j.residual:
            var e = j.residual.value()[].copy()
            j.residual.value()[] = _apply_site_rule[rule](e^)


# =============================================================================
# Rule 9: Predicate Simplification
# =============================================================================

def simplify_predicates(var plan: LogicalPlan) -> LogicalPlan:
    """Apply predicate simplification to all expressions in the plan tree.

    Wrapper around `simplify_predicates_inplace` for legacy callers.
    """
    simplify_predicates_inplace(plan)
    return plan^


def simplify_predicates_inplace(mut plan: LogicalPlan):
    """In-place predicate simplification."""
    if plan.tag == PLAN_FILTER:
        simplify_predicates_inplace(plan._filter.value()[].child[])
        var pred_copy = plan._filter.value()[].predicate.copy()
        var simplified = _simplify_expr(pred_copy^)
        plan._filter.value()[].predicate = simplified^

    elif plan.tag == PLAN_PROJECT:
        simplify_predicates_inplace(plan._project.value()[].child[])
        var new_exprs = ExprArray()
        for i in range(len(plan._project.value()[].exprs)):
            var expr_copy = plan._project.value()[].exprs[i].copy()
            new_exprs.append(_simplify_expr(expr_copy^))
        plan._project.value()[].exprs = new_exprs^

    elif plan.tag == PLAN_SCAN:
        if plan._scan and plan._scan.value()[].filter:
            var old_filter = plan._scan.value()[].filter.value().copy()
            var simplified = _simplify_expr(old_filter^)
            plan._scan.value()[].filter = simplified^

    elif plan.tag == PLAN_AGGREGATE:
        simplify_predicates_inplace(plan._aggregate.value()[].child[])
        _rewrite_agg_and_residual_sites[_SITE_RULE_SIMPLIFY](plan)

    elif plan.tag == PLAN_JOIN:
        simplify_predicates_inplace(plan._join.value()[].left[])
        simplify_predicates_inplace(plan._join.value()[].right[])
        _rewrite_agg_and_residual_sites[_SITE_RULE_SIMPLIFY](plan)

    elif plan.tag == PLAN_SORT:
        simplify_predicates_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        simplify_predicates_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        simplify_predicates_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        simplify_predicates_inplace(plan._topn.value()[].child[])


def _simplify_expr(var expr: Expr) -> Expr:
    """Recursively simplify boolean expressions."""
    if expr.tag == EXPR_BINARY_OP:
        var left = _simplify_expr(expr.binary_left().copy())
        var right = _simplify_expr(expr.binary_right().copy())
        var op = expr.binary_op()

        # AND simplifications
        if op == BIN_AND:
            if _is_bool_literal(left, True):
                return right^
            if _is_bool_literal(right, True):
                return left^
            if _is_bool_literal(left, False):
                return Expr.literal(ScalarValue.from_bool(False))
            if _is_bool_literal(right, False):
                return Expr.literal(ScalarValue.from_bool(False))

        # OR simplifications
        if op == BIN_OR:
            if _is_bool_literal(left, True):
                return Expr.literal(ScalarValue.from_bool(True))
            if _is_bool_literal(right, True):
                return Expr.literal(ScalarValue.from_bool(True))
            if _is_bool_literal(left, False):
                return right^
            if _is_bool_literal(right, False):
                return left^

        return Expr.binary(op, left^, right^)

    elif expr.tag == EXPR_UNARY_OP:
        var child = _simplify_expr(expr.unary_child().copy())
        var op = expr.unary_op()

        # NOT NOT x -> x
        if op == UN_NOT and child.tag == EXPR_UNARY_OP:
            if child.unary_op() == UN_NOT:
                return child.unary_child()

        return Expr.unary(op, child^)

    elif expr.tag == EXPR_CAST:
        # `cast_preserving_arrow` — see `_fold_expr`'s EXPR_CAST arm for the
        # measured defect (a temporal cast rebuilt from its DType alone stops
        # being temporal).
        var child = _simplify_expr(expr.cast_child().copy())
        return Expr.cast_preserving_arrow(child^, expr)

    elif expr.tag == EXPR_ALIAS:
        var child = _simplify_expr(expr.alias_child().copy())
        return Expr.alias(child^, expr.alias_name())

    return expr^


# =============================================================================
# Rule 18: Common Subexpression Elimination (CSE)
# =============================================================================

def eliminate_common_subexpressions(var plan: LogicalPlan) raises -> LogicalPlan:
    """Rule 18 — Common Subexpression Elimination (3-axis).

    Three axes. Each applicable plan
    node is rewritten in-place after recursing into children.

    Axis 1 (PLAN_PROJECT — depth >= 2): detect duplicated SUBTREES
        across the SAME Project's output list (a duplicated WHOLE output
        expression is just the case where the parent IS the output list);
        splice a synthetic Project BELOW materializing the shared subtree
        and rewrite every occurrence in the original exprs to ColRef the
        synthetic. The Project's own arity and output schema are
        UNCHANGED — a synthetic is never a user-visible output column,
        and never a name only a sibling could resolve.
    Axis 2 (PLAN_FILTER — depth >= 3): detect duplicated subtrees across
        the predicate's AND-conjuncts; wrap the Filter in a 2-Project
        sandwich (inner Project materializes the synthetic CSE columns
        as pass-through extras; Filter predicate is rewritten to ColRef
        the synthetic; outer Project strips the synthetic columns back
        out so the Filter's original output schema is preserved). Both
        synthetic Projects are flagged `is_cse_introduced=True` so
        `push_predicates_down` treats them as barriers (a predicate
        referencing `_cse_*` cannot push below the materializer).
    Axis 3 (PLAN_AGGREGATE — depth >= 2): detect duplicated subtrees
        across all agg-fn arguments; insert a synthetic Project below
        the Aggregate that pass-throughs the base columns and adds the
        synthetic CSE columns; rewrite each agg-fn argument that
        contained the duplicated subtree to ColRef the synthetic.
        Aggregate's output schema is unchanged (synthetics live in the
        below-Project, not the Aggregate's output).

    Eligibility: a subtree is CSE-eligible iff every node carries
    a tag from `{COL_REF, LITERAL, BINARY_OP, UNARY_OP, CAST, ALIAS,
    WHEN, IN_LIST}` (no AGG_FN / WINDOW_FN / SCALAR-FN / UDF / opaque
    nested-extract); subtree depth >= the per-axis threshold; fingerprint
    repetition >= 2 in the considered scope.

    Determinism: synthetic names are `_cse_<8hex_of_FNV1a_of_fingerprint>_<n>`
    where `n` is the per-call counter for collision tie-break. Identical
    plans across runs produce identical synthetic names (stable EXPLAIN +
    plan-cache keys).

    Out of scope: CSE across plan nodes, and
    typed-comptime CSE.
    """
    var counter = _CseNameCounter()
    eliminate_common_subexpressions_inplace_with_counter(plan, counter)
    return plan^


def eliminate_common_subexpressions_inplace(mut plan: LogicalPlan) raises:
    """In-place CSE entry point (preserves the original API surface).

    Allocates a fresh per-call counter and dispatches to the
    counter-threading walker. The counter is needed so distinct CSE
    materializations within ONE optimize call get disambiguating
    suffixes when two unrelated fingerprints happen to FNV1a-collide
    in their low 32 bits.
    """
    var counter = _CseNameCounter()
    eliminate_common_subexpressions_inplace_with_counter(plan, counter)


def eliminate_common_subexpressions_inplace_with_counter(mut plan: LogicalPlan, mut counter: _CseNameCounter) raises:
    """Counter-threading recursive driver (called by both entry points).

    Children are recursed into FIRST, so any nested CSE candidates land
    before the parent rewrite sees its expressions (constant folding
    + simplification have already run by the pass ordering in
    the optimizer driver).
    """
    if plan.tag == PLAN_PROJECT:
        eliminate_common_subexpressions_inplace_with_counter(plan._project.value()[].child[], counter)
        _cse_rewrite_project_axis1(plan, counter)

    elif plan.tag == PLAN_FILTER:
        eliminate_common_subexpressions_inplace_with_counter(plan._filter.value()[].child[], counter)
        _cse_rewrite_filter_axis2(plan, counter)

    elif plan.tag == PLAN_AGGREGATE:
        eliminate_common_subexpressions_inplace_with_counter(plan._aggregate.value()[].child[], counter)
        _cse_rewrite_aggregate_axis3(plan, counter)

    elif plan.tag == PLAN_JOIN:
        eliminate_common_subexpressions_inplace_with_counter(plan._join.value()[].left[], counter)
        eliminate_common_subexpressions_inplace_with_counter(plan._join.value()[].right[], counter)

    elif plan.tag == PLAN_SORT:
        eliminate_common_subexpressions_inplace_with_counter(plan._sort.value()[].child[], counter)

    elif plan.tag == PLAN_LIMIT:
        eliminate_common_subexpressions_inplace_with_counter(plan._limit.value()[].child[], counter)

    elif plan.tag == PLAN_DISTINCT:
        eliminate_common_subexpressions_inplace_with_counter(plan._distinct.value()[].child[], counter)

    elif plan.tag == PLAN_TOPN:
        eliminate_common_subexpressions_inplace_with_counter(plan._topn.value()[].child[], counter)


# =============================================================================
# Per-axis driver bodies
# =============================================================================

# Per-axis minimum subtree depth thresholds.
#   Axis 1 (Project): synthetic Project spliced below the Project — a
#     normal Project node — depth >= 2 (skip pure-leaf duplicates).
#   Axis 2 (Filter): 2-Project sandwich is plan-node-cost-positive — gate
#     stricter at depth >= 3 so per-row savings dominate (a depth-only
#     gate; there is no stats-aware gate).
#   Axis 3 (Aggregate): synthetic Project below an Aggregate is a normal
#     Project node — depth >= 2 (matches Axis 1 cost model).
comptime CSE_MIN_DEPTH_AXIS1: Int = 2
comptime CSE_MIN_DEPTH_AXIS2: Int = 3
comptime CSE_MIN_DEPTH_AXIS3: Int = 2


def _cse_rewrite_project_axis1(mut plan: LogicalPlan, mut counter: _CseNameCounter) raises:
    """Axis 1 — Project subtree dedup, ONE phase.

    For every fingerprint that occurs >= 2 times across this Project's
    output expressions at depth >= CSE_MIN_DEPTH_AXIS1, splice a NEW
    Project BELOW this one holding `Alias(<exemplar>, "_cse_<hash>_<n>")`
    per fingerprint (plus a pass-through of every child column), and
    rewrite every original expr to ColRef the synthetic in place of the
    matched subtree. THIS Project's arity and `output_schema` are
    untouched — the synthetics are never user-visible output columns.
    (An earlier version put them on THIS Project's own
    expression list, which broke `len(exprs) == output_schema
    .num_columns()` and killed the process in `push_projections_down`.)

    ⛔ THERE IS NO "PHASE A" ANY MORE, AND DO NOT BRING IT BACK.
    ------------------------------------------------------------------
    Until 2026-09-01 a "Phase A" ran first and dedup'd WHOLE output
    expressions by rewriting the second occurrence to
    `Alias(ColRef(<first output name>), <second output name>)`:

        SELECT (price-cost)/price AS m, (price-cost)/price AS m2
        -> [Alias((price-cost)/price, "m"), Alias(ColRef("m"), "m2")]

    **A PROJECT'S EXPRESSIONS ARE EVALUATED AGAINST ITS CHILD'S SCHEMA,
    AND SIBLINGS ARE NOT IN SCOPE FOR EACH OTHER.** "m" is an output of
    THIS node, not a column of the scan below it, so nothing could
    resolve it: the optimized schema came back `[m:FLOAT64,
    m2:<unknown>]` and materialize raised "non-breaker child is not a
    parquet-collect shape ... nor a bare in-memory leaf". It was
    fail-LOUD, which is the only reason it outlived the SIGILL fix that
    found it (it was pinned rather than patched in a rush).

    ⚠ ITS BLAST RADIUS WAS WIDER THAN THE SHAPE THE PIN RECORDED. Phase A
    had NO depth gate, so `SELECT price AS a, price AS b FROM orders`
    — no arithmetic at all — produced `Alias(ColRef("a"), "b")` and was
    broken identically, in a shape this pass's depth >= 2 gate means the
    surviving code never even looks at.

    THE REMEDY IS THE ONE THE SIGILL FIX USED ONE LEVEL UP: put the
    shared computation where it IS in scope. A whole-expression
    duplicate is just a subtree duplicate whose parent happens to be the
    output list, so the code below already handles it — the fingerprint
    tally unwraps aliases, both occurrences count, and both projections
    end up as `Alias(ColRef("_cse_..."), <user name>)` over a synthetic
    the spliced child really provides. Deleting Phase A was therefore
    the whole fix; nothing replaced it.

    ⚠ WHAT THIS BUYS, STATED HONESTLY: correctness, not speed. The optimizer's
    `merge_projects` runs unconditionally and inlines the spliced
    Project straight back into its parent, so the FINAL plan for a
    whole-expression duplicate is the bound plan — the shared expression
    is computed twice, exactly as it was before CSE ran. That is a
    correct answer where there used to be a raise, and it is the same
    no-op-after-merge the Axis-1 SIGILL fix measured. Making the
    materialization survive needs a CSE barrier in `merge_projects`,
    which is a PERF change and needs a measurement first.
    """
    ref pd = plan._project.value()[]
    if len(pd.exprs) == 0:
        return

    # Tally every eligible subtree across the whole output list. Aliases
    # are unwrapped by the walker, so a WHOLE output expression counts
    # here exactly like a nested one — which is the point: a
    # whole-expression duplicate needs no separate rule, only the same
    # in-scope materialization every other duplicate gets.
    var counts = Dict[String, Int]()
    var exemplars = ExprArray()
    var fp_to_exidx = Dict[String, Int]()
    var depths = Dict[String, Int]()
    for i in range(len(pd.exprs)):
        _collect_subtree_fingerprints(pd.exprs[i], counts, exemplars, fp_to_exidx, depths)

    var fps = List[String]()
    for entry in counts.items():
        var d = depths[entry.key]
        if entry.value >= 2 and d >= CSE_MIN_DEPTH_AXIS1:
            fps.append(entry.key)
    if len(fps) == 0:
        return
    _sort_string_list(fps)

    # Name each surviving fingerprint. Sorted-fp order (above) makes the
    # names deterministic given plan shape, which the EXPLAIN goldens and
    # the plan-cache keys rely on.
    var fp_to_synth = Dict[String, String]()
    for i in range(len(fps)):
        fp_to_synth[fps[i]] = _cse_synthetic_name(fps[i], counter)

    # Rewrite. THE SYNTHETICS GO IN A NEW PROJECT *BELOW* THIS
    # ONE — never alongside the user's own output expressions.
    #
    # ⛔ DO NOT "SIMPLIFY" THIS BACK INTO ONE PROJECT.
    # The original rewrite prepended each `Alias(<exemplar>, "_cse_...")`
    # onto THIS Project's own `exprs` and left `plan.output_schema` alone.
    # That did two things, both fatal:
    #   1. It BROKE the Project invariant `len(exprs) ==
    #      output_schema.num_columns()` that `LogicalPlan.project` (the only
    #      constructor — one derived schema
    #      field per expr) establishes. `push_projections_down`
    #      bounds a loop by
    #      `len(exprs)` and subscripts `output_schema.field_name(i)` with
    #      it, so a 2-column SELECT that grew to 4 exprs read field 2 of a
    #      2-field schema -> the schema bounds check `index 2 is out of bounds` ->
    #      `os.abort()`. That is a SIGTRAP/SIGILL PROCESS KILL, not a raise:
    #      no `try/except` on any customer SQL surface can see it.
    #   2. Even with the schema re-derived, it PUBLISHED the synthetics as
    #      user-visible output columns: `SELECT margin, b` came back as
    #      `[_cse_00dfe729_0, _cse_a3df4139_1, margin, b]`. Trading the loud
    #      crash for a silent wrong answer is strictly worse.
    # `_cse_rewrite_aggregate_axis3` had this right all along — its
    # synthetic Project goes BELOW the Aggregate, so "the Aggregate's own
    # output schema is unchanged". Axis 2 keeps the same property with an
    # outer pass-through strip Project. Axis 1 now does what Axis 3 does:
    # the node whose arity IS the query's answer is never widened, and its
    # `output_schema` is therefore never even re-derived — it stays exactly
    # the schema the binder produced.
    #
    # ⚠ A UDF-carrying Project is left alone. Its `exprs` are placeholder
    # col_refs for `M.OutputSchema` and execution is routed through the UDF
    # operator over THIS node's child; splicing a Project underneath would
    # change what the operator-build driver resolves column paths against.
    # (Placeholder col_refs are depth-1 leaves, so no fingerprint here is
    # eligible in the first place — this is belt-and-braces, and it can only
    # ever turn a would-be abort into a skip.)
    if pd.has_udf():
        return

    # The Project BELOW: pass through every column of the original child
    # (as `Alias(ColRef(x), x)`, which preserves both the field NAME and
    # the field TYPE through SchemaBuilder's inference) + one
    # `Alias(<exemplar>, "_cse_...")` per eligible fingerprint. Flagged
    # `is_cse_introduced=True` so `push_predicates_down` treats it as a
    # barrier and the `inmem_leaf` un-CSE walkers recognise it. The
    # exemplar carries the ORIGINAL subtree shape (no recursive rewrite
    # into siblings).
    var child_schema = _copy_schema(pd.child[].output_schema)
    var below_exprs = ExprArray()
    for i in range(child_schema.num_columns()):
        var nm = child_schema.field_name(i)
        below_exprs.append(Expr.alias(Expr.col_ref(nm), nm))
    for i in range(len(fps)):
        var synth_name = fp_to_synth[fps[i]]
        var exidx = fp_to_exidx[fps[i]]
        var exemplar_copy = exemplars[exidx].copy()
        below_exprs.append(Expr.alias(exemplar_copy^, synth_name))
    var below_project = LogicalPlan.project(
        below_exprs^, pd.child[].copy(), True
    )

    # THIS Project keeps its arity: exactly one rewritten expr per original
    # output column, each duplicated subtree now a ColRef to the synthetic
    # the node below materializes. `output_schema` is untouched and still
    # matches, so the invariant holds by construction.
    var new_exprs = ExprArray()
    for i in range(len(pd.exprs)):
        var rewritten = _rewrite_with_cse(pd.exprs[i].copy(), fp_to_synth)
        new_exprs.append(rewritten^)
    pd.exprs = new_exprs^
    pd.child = OwnedPointer(below_project^)


def _cse_rewrite_filter_axis2(mut plan: LogicalPlan, mut counter: _CseNameCounter) raises:
    """Axis 2 — duplicated subtrees inside a Filter predicate.

    Tallies fingerprints across the predicate's AND-conjuncts; if any
    eligible (depth >= 3, count >= 2) fingerprint is found, wraps the
    Filter in a 2-Project sandwich:

        outer Project (pass-through original cols, is_cse_introduced=True)
          Filter (predicate rewritten to ColRef the synthetics)
            inner Project (pass-through original + Alias(exemplar, "_cse_...") synthetics, is_cse_introduced=True)
              <original child>

    The sandwich preserves the Filter's output schema (outer Project
    drops the synthetic columns) and prevents predicate-pushdown from
    descending past the inner Project (where the synthetic ColRef target
    no longer exists). Both Project nodes are flagged
    `is_cse_introduced=True` so `push_predicates_down` treats them as
    barriers; downstream rules see the structure as a normal
    Project/Filter/Project chain.
    """
    # Snapshot every field of the Filter we'll need BEFORE we let go of
    # the `ref` (Mojo's lifetime rules disallow reassigning `plan` while
    # a `ref` into its internals is still live). Local var copies of the
    # predicate + child + orig schema decouple the rest of the body
    # from the FilterData borrow.
    var pred_copy = plan._filter.value()[].predicate.copy()
    var child_copy = plan._filter.value()[].child[].copy()
    var orig_schema = _copy_schema(child_copy.output_schema)

    # Collect AND-conjuncts of the predicate; tally fingerprints across all.
    var conjuncts = ExprArray()
    _collect_and_conjuncts_local(pred_copy, conjuncts)

    var counts = Dict[String, Int]()
    var exemplars = ExprArray()
    var fp_to_exidx = Dict[String, Int]()
    var depths = Dict[String, Int]()
    for i in range(len(conjuncts)):
        _collect_subtree_fingerprints(conjuncts[i], counts, exemplars, fp_to_exidx, depths)

    var fps = List[String]()
    for entry in counts.items():
        var d = depths[entry.key]
        if entry.value >= 2 and d >= CSE_MIN_DEPTH_AXIS2:
            fps.append(entry.key)
    if len(fps) == 0:
        return
    _sort_string_list(fps)

    var fp_to_synth = Dict[String, String]()
    for i in range(len(fps)):
        fp_to_synth[fps[i]] = _cse_synthetic_name(fps[i], counter)

    # Inner Project: pass through every column of the original child AND
    # add Alias(<exemplar>, "_cse_...") for every synthetic. The
    # pass-throughs use Alias(ColRef(name), name) to keep the schema
    # field-name + field-type identical to the input (alias-around-col-ref
    # is a no-op at execution but preserves SchemaBuilder's name inference).
    var inner_exprs = ExprArray()
    for i in range(orig_schema.num_columns()):
        var nm = orig_schema.field_name(i)
        inner_exprs.append(Expr.alias(Expr.col_ref(nm), nm))
    for i in range(len(fps)):
        var synth_name = fp_to_synth[fps[i]]
        var exidx = fp_to_exidx[fps[i]]
        var exemplar_copy = exemplars[exidx].copy()
        inner_exprs.append(Expr.alias(exemplar_copy^, synth_name))
    var inner_project = LogicalPlan.project(
        inner_exprs^, child_copy^, True
    )

    # Filter sits over the inner Project, with predicate rewritten so
    # every duplicated subtree becomes a ColRef to the synthetic column.
    var new_pred = _rewrite_with_cse(pred_copy^, fp_to_synth)
    var new_filter = LogicalPlan.filter(new_pred^, inner_project^)

    # Outer Project: pass through ONLY the original columns (strip the
    # synthetics). This restores the Filter's original output schema.
    var outer_exprs = ExprArray()
    for i in range(orig_schema.num_columns()):
        var nm = orig_schema.field_name(i)
        outer_exprs.append(Expr.alias(Expr.col_ref(nm), nm))
    var outer_project = LogicalPlan.project(
        outer_exprs^, new_filter^, True
    )

    plan = outer_project^


def _cse_rewrite_aggregate_axis3(mut plan: LogicalPlan, mut counter: _CseNameCounter) raises:
    """Axis 3 — duplicated subtrees inside Aggregate agg-fn args.

    Tallies fingerprints across every agg-fn's child Expr (slots
    child / child1 / child2 / child3). For each eligible fingerprint,
    inserts a synthetic Project below the Aggregate that pass-throughs
    the base columns + adds Alias(<exemplar>, "_cse_...") synthetics, then
    rewrites each agg-fn argument to ColRef the synthetic. The
    Aggregate's output schema is unchanged.

    Highest-payoff axis for TPC-H Q1 (`SUM(l_extendedprice * (1-l_discount))`
    + `SUM(l_extendedprice * (1-l_discount) * (1+l_tax))` shape — the
    inner subtree computes once per row instead of twice).
    """
    # Deep-copy the AggregateData ONCE up front; operate on the copy. This
    # lets us reassign `plan` at the end without holding any live `ref`
    # into `plan`'s internals (Mojo lifetime rule). The copy is a 1-time
    # cost in the rare-CSE-hit case; the no-op path bails before this.
    if len(plan._aggregate.value()[].agg_exprs) == 0:
        return

    # Phase 1: tally fingerprints from a brief borrow. ExprArray for
    # exemplars (Slab[Expr] supports non-Copyable T); Dict[String, Int]
    # for fp -> exemplar-index.
    var counts = Dict[String, Int]()
    var exemplars = ExprArray()
    var fp_to_exidx = Dict[String, Int]()
    var depths = Dict[String, Int]()
    var n_aggs = len(plan._aggregate.value()[].agg_exprs)
    for i in range(n_aggs):
        ref agg = plan._aggregate.value()[].agg_exprs[i]
        if agg.child:
            _collect_subtree_fingerprints(agg.child.value(), counts, exemplars, fp_to_exidx, depths)
        if agg.child1:
            _collect_subtree_fingerprints(agg.child1.value(), counts, exemplars, fp_to_exidx, depths)
        if agg.child2:
            _collect_subtree_fingerprints(agg.child2.value(), counts, exemplars, fp_to_exidx, depths)
        if agg.child3:
            _collect_subtree_fingerprints(agg.child3.value(), counts, exemplars, fp_to_exidx, depths)

    var fps = List[String]()
    for entry in counts.items():
        var d = depths[entry.key]
        if entry.value >= 2 and d >= CSE_MIN_DEPTH_AXIS3:
            fps.append(entry.key)
    if len(fps) == 0:
        return
    _sort_string_list(fps)

    var fp_to_synth = Dict[String, String]()
    for i in range(len(fps)):
        fp_to_synth[fps[i]] = _cse_synthetic_name(fps[i], counter)

    # Deep-copy the entire AggregateData; we then drop the borrow on
    # `plan` and operate on `ad_copy` exclusively.
    var ad_copy = plan._aggregate.value()[].copy()
    var child_schema = _copy_schema(ad_copy.child[].output_schema)

    # Synthetic Project below the Aggregate: pass through every base
    # column + add the CSE materializers.
    var below_exprs = ExprArray()
    for i in range(child_schema.num_columns()):
        var nm = child_schema.field_name(i)
        below_exprs.append(Expr.alias(Expr.col_ref(nm), nm))
    for i in range(len(fps)):
        var synth_name = fp_to_synth[fps[i]]
        var exidx = fp_to_exidx[fps[i]]
        var exemplar_copy = exemplars[exidx].copy()
        below_exprs.append(Expr.alias(exemplar_copy^, synth_name))
    var below_project = LogicalPlan.project(
        below_exprs^, ad_copy.child[].copy(), True
    )

    # Rewrite every agg-fn arg. Group-by keys are NOT rewritten (they
    # reference base columns that the synthetic Project pass-throughs
    # unchanged — rewriting them to `_cse_*` would be a no-op since the
    # CSE-eligible subtrees are inside the agg-fn args, not the keys).
    var new_aggs = AggExprArray()
    for i in range(n_aggs):
        ref agg = ad_copy.agg_exprs[i]
        var c0_opt: Optional[Expr] = None
        var c1_opt: Optional[Expr] = None
        var c2_opt: Optional[Expr] = None
        var c3_opt: Optional[Expr] = None
        if agg.child:
            c0_opt = _rewrite_with_cse(agg.child.value().copy(), fp_to_synth)
        if agg.child1:
            c1_opt = _rewrite_with_cse(agg.child1.value().copy(), fp_to_synth)
        if agg.child2:
            c2_opt = _rewrite_with_cse(agg.child2.value().copy(), fp_to_synth)
        if agg.child3:
            c3_opt = _rewrite_with_cse(agg.child3.value().copy(), fp_to_synth)
        var alias_take: Optional[String] = None
        if agg.alias_name:
            alias_take = agg.alias_name.value()
        var new_agg = AggExpr(agg.func, c0_opt^, alias_take^)
        new_agg.child1 = c1_opt^
        new_agg.child2 = c2_opt^
        new_agg.child3 = c3_opt^
        new_aggs.append(new_agg^)

    # Group-by keys (preserved as-is).
    var new_gb = ExprArray()
    for i in range(len(ad_copy.group_by)):
        new_gb.append(ad_copy.group_by[i].copy())

    # UDF aggs / chain_id preservation
    # removed — AggregateData no longer carries those fields.
    plan = LogicalPlan.aggregate(
        new_gb^, new_aggs^, below_project^
    )


# =============================================================================
# Private helpers
# =============================================================================

struct _CseNameCounter(Movable):
    """Per-optimize-call counter for synthetic-name collision tie-break.

    Allocated by the public `eliminate_common_subexpressions*` entry
    points and threaded through the recursive walker. Incremented every
    time a synthetic name is emitted; appended to the synthetic-name
    suffix as a tie-break against the rare 32-bit FNV1a-of-fingerprint
    collision. Stable across runs because the COUNT is deterministic
    given the plan shape + fingerprint order.
    """
    var n: Int

    def __init__(out self):
        self.n = 0

    @always_inline
    def next(mut self) -> Int:
        var v = self.n
        self.n += 1
        return v


def _collect_subtree_fingerprints(
    expr: Expr,
    mut counts: Dict[String, Int],
    mut exemplars: ExprArray,
    mut fp_to_exidx: Dict[String, Int],
    mut depths: Dict[String, Int],
) raises:
    """Recursive walker that populates fingerprint tally.

    For every node in the tree that is CSE-eligible (`_is_cse_eligible`)
    and has depth >= 2 (depth-1 leaves are skipped — they're cheaper to
    recompute than synthesize a ColRef-and-resolve), record:
      - `counts[fp]` += 1 (occurrence tally)
      - `exemplars[fp_to_exidx[fp]]` = expr.copy() (first-seen instance;
        the per-axis driver reads this to build the synthetic Project's
        materializer). Uses ExprArray-of-exemplars + per-fp index dict
        because Dict[String, Expr] is rejected by Dict (Expr is
        Movable-only; Dict requires V: Copyable).
      - `depths[fp]` = subtree depth (the per-axis driver reads this to
        gate against the depth threshold)

    Then recurses into children — but if the parent is itself an
    eligible CSE candidate, the recursion still happens so NESTED
    duplicates inside the parent also get tallied (the per-axis rewriter
    only rewrites the OUTERMOST eligible occurrence, but the tally
    correctly counts every subtree).

    Aliases are unwrapped (`EXPR_ALIAS` is bypassed) so an aliased
    expression and its un-aliased twin fingerprint equal — matching the
    canonicalization that `_expr_fingerprint` already does for ALIAS.
    """
    # Unwrap aliases: the alias decorates the output name, not the
    # computation. `_expr_fingerprint` returns the child's fingerprint
    # for ALIAS — we don't want the ALIAS node itself recorded as a
    # candidate (its child is the real subtree).
    if expr.tag == EXPR_ALIAS:
        _collect_subtree_fingerprints(expr.alias_child_ref(), counts, exemplars, fp_to_exidx, depths)
        return

    var d = _subtree_depth(expr)
    if d >= 2 and _is_cse_eligible(expr):
        var fp = _expr_fingerprint(expr)
        if fp in counts:
            counts[fp] = counts[fp] + 1
        else:
            counts[fp] = 1
            fp_to_exidx[fp] = len(exemplars)
            exemplars.append(expr.copy())
            depths[fp] = d

    # Recurse into children regardless: nested CSE candidates are
    # independently tallied. ELIGIBLE-children tags only — for opaque
    # tags (AGG_FN / WINDOW_FN / STRING_OP / etc.) descending would
    # risk fingerprinting Expr children that the rewriter can't honor.
    if expr.tag == EXPR_BINARY_OP:
        _collect_subtree_fingerprints(expr.binary_left_ref(), counts, exemplars, fp_to_exidx, depths)
        _collect_subtree_fingerprints(expr.binary_right_ref(), counts, exemplars, fp_to_exidx, depths)
    elif expr.tag == EXPR_UNARY_OP:
        _collect_subtree_fingerprints(expr.unary_child_ref(), counts, exemplars, fp_to_exidx, depths)
    elif expr.tag == EXPR_CAST:
        _collect_subtree_fingerprints(expr.cast_child_ref(), counts, exemplars, fp_to_exidx, depths)
    elif expr.tag == EXPR_WHEN:
        ref when_data = expr._when.value()
        for i in range(len(when_data.cases)):
            _collect_subtree_fingerprints(when_data.cases[i].condition[], counts, exemplars, fp_to_exidx, depths)
            _collect_subtree_fingerprints(when_data.cases[i].result[], counts, exemplars, fp_to_exidx, depths)
        _collect_subtree_fingerprints(when_data.default[], counts, exemplars, fp_to_exidx, depths)
    elif expr.tag == EXPR_IN_LIST:
        _collect_subtree_fingerprints(expr.in_list_child_ref(), counts, exemplars, fp_to_exidx, depths)
    # Other tags (COL_REF / LITERAL / COL_IDX) are leaves with depth 1;
    # opaque tags (AGG_FN / WINDOW_FN / STRING_OP / REGEXP /
    # CORRELATED_SUBQUERY / STRUCT_FIELD* / MAP_GET / JSON_EXTRACT /
    # EXTRACT) are CSE-ineligible and not descended into.


def _is_cse_eligible(expr: Expr) -> Bool:
    """Return True iff this subtree is safe to CSE.

    Conservative whitelist of pure-arithmetic / pure-comparison tags
    (extended with `EXPR_WHEN` + `EXPR_IN_LIST` since both have
    well-defined per-row semantics with no side effects). The walker
    recurses to verify every descendant is also eligible; encountering
    any opaque / impure tag short-circuits to False.

    Tags conservatively excluded:
      EXPR_AGG_FN, EXPR_WINDOW_FN, EXPR_CORRELATED_SUBQUERY (semantics
      tied to outer scope / windows / aggregation), EXPR_STRING_OP /
      EXPR_REGEXP (UDF-shaped per row but pattern is plan-literal;
      deferred — easy to re-enable), EXPR_STRUCT_FIELD* /
      EXPR_MAP_GET / EXPR_JSON_EXTRACT / EXPR_EXTRACT (nested / temporal
      extractors with arrow-side state; deferred).
    """
    if expr.tag == EXPR_COL_REF or expr.tag == EXPR_COL_IDX or expr.tag == EXPR_LITERAL:
        return True
    elif expr.tag == EXPR_BINARY_OP:
        return _is_cse_eligible(expr.binary_left_ref()) and _is_cse_eligible(expr.binary_right_ref())
    elif expr.tag == EXPR_UNARY_OP:
        return _is_cse_eligible(expr.unary_child_ref())
    elif expr.tag == EXPR_CAST:
        return _is_cse_eligible(expr.cast_child_ref())
    elif expr.tag == EXPR_ALIAS:
        return _is_cse_eligible(expr.alias_child_ref())
    elif expr.tag == EXPR_WHEN:
        ref when_data = expr._when.value()
        for i in range(len(when_data.cases)):
            if not _is_cse_eligible(when_data.cases[i].condition[]):
                return False
            if not _is_cse_eligible(when_data.cases[i].result[]):
                return False
        return _is_cse_eligible(when_data.default[])
    elif expr.tag == EXPR_IN_LIST:
        return _is_cse_eligible(expr.in_list_child_ref())
    # AGG_FN / WINDOW_FN / CORRELATED_SUBQUERY / STRING_OP / REGEXP /
    # STRUCT_FIELD* / MAP_GET / JSON_EXTRACT / EXTRACT — opaque.
    return False


def _subtree_depth(expr: Expr) -> Int:
    """Recursive height of an Expr tree.

    Leaves (COL_REF / COL_IDX / LITERAL) have depth 1. BinaryOp /
    UnaryOp / Cast / Alias / When / InList are depth = 1 + max(child
    depths). Opaque tags return 1 (treated as opaque leaves for depth
    purposes; the eligibility check rejects them upstream).
    """
    if expr.tag == EXPR_COL_REF or expr.tag == EXPR_COL_IDX or expr.tag == EXPR_LITERAL:
        return 1
    elif expr.tag == EXPR_BINARY_OP:
        var l = _subtree_depth(expr.binary_left_ref())
        var r = _subtree_depth(expr.binary_right_ref())
        return 1 + (l if l > r else r)
    elif expr.tag == EXPR_UNARY_OP:
        return 1 + _subtree_depth(expr.unary_child_ref())
    elif expr.tag == EXPR_CAST:
        return 1 + _subtree_depth(expr.cast_child_ref())
    elif expr.tag == EXPR_ALIAS:
        return _subtree_depth(expr.alias_child_ref())
    elif expr.tag == EXPR_WHEN:
        ref when_data = expr._when.value()
        var m = 1
        for i in range(len(when_data.cases)):
            var dc = _subtree_depth(when_data.cases[i].condition[])
            var dr = _subtree_depth(when_data.cases[i].result[])
            if dc > m: m = dc
            if dr > m: m = dr
        var dd = _subtree_depth(when_data.default[])
        if dd > m: m = dd
        return 1 + m
    elif expr.tag == EXPR_IN_LIST:
        return 1 + _subtree_depth(expr.in_list_child_ref())
    return 1


def _rewrite_with_cse(var expr: Expr, candidates: Dict[String, String]) raises -> Expr:
    """Rewrite subtrees whose fingerprint maps to a synthetic.

    Walks the tree bottom-up. At each non-alias node, fingerprints the
    current subtree; if the fingerprint is a key in `candidates`,
    REPLACES the entire subtree with `ColRef(candidates[fp])` —
    short-circuiting any deeper recursion (the synthetic column already
    materializes that subtree).

    For an Alias-wrapped expression, the alias is preserved (the output
    name still matters for the caller's schema) and the child is
    rewritten. The Alias node itself is never a CSE candidate (its
    fingerprint equals the child's per `_expr_fingerprint`, so the
    rewrite at the child level fires and the Alias re-wraps the new
    ColRef).
    """
    # Alias unwraps to its child for fingerprint comparison — but the
    # alias DECORATION must be preserved on the output. Recurse into
    # the child and re-wrap.
    if expr.tag == EXPR_ALIAS:
        var alias_nm = expr.alias_name()
        var child_copy = expr.alias_child_ref().copy()
        var new_child = _rewrite_with_cse(child_copy^, candidates)
        return Expr.alias(new_child^, alias_nm)

    # Check whether this node's subtree IS a CSE candidate. If yes,
    # replace with a ColRef and stop recursing.
    if _is_cse_eligible(expr) and _subtree_depth(expr) >= 2:
        var fp = _expr_fingerprint(expr)
        if fp in candidates:
            return Expr.col_ref(candidates[fp])

    # Otherwise: recurse into children, then rebuild this node with
    # the (possibly-rewritten) children.
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        var l = _rewrite_with_cse(expr.binary_left_ref().copy(), candidates)
        var r = _rewrite_with_cse(expr.binary_right_ref().copy(), candidates)
        return Expr.binary(op, l^, r^)
    elif expr.tag == EXPR_UNARY_OP:
        var op = expr.unary_op()
        var c = _rewrite_with_cse(expr.unary_child_ref().copy(), candidates)
        return Expr.unary(op, c^)
    elif expr.tag == EXPR_CAST:
        # `cast_preserving_arrow` — see `_fold_expr`'s EXPR_CAST arm. ⚠ THIS
        # SITE ALSO HELD THE TARGET IN A LOCAL (`var tgt = expr.cast_target()`),
        # which made the loss look deliberate; it was not, and the local is gone
        # so there is nothing to keep in sync with the node.
        var c = _rewrite_with_cse(expr.cast_child_ref().copy(), candidates)
        return Expr.cast_preserving_arrow(c^, expr)
    elif expr.tag == EXPR_WHEN or expr.tag == EXPR_IN_LIST:
        # CSE candidates inside these tags would have been detected at
        # the OUTER level (Axis 1/2/3 tally walks the whole tree). If
        # the outer node didn't fire (length-mismatch / depth-gate /
        # ineligibility) we leave the inner shape unchanged — a nested
        # rewrite would risk losing structural invariants (When's case
        # ordering; IN_LIST's value set), and the missed CSE is a
        # rare-shape opportunity.
        return expr^
    # Leaves and any tag we don't recurse into: return unchanged.
    return expr^


def _cse_synthetic_name(fingerprint: String, mut counter: _CseNameCounter) -> String:
    """Deterministic synthetic name generator.

    Format: `_cse_<8hex_of_FNV1a_lower32>_<counter>`. The per-call
    counter ensures uniqueness within ONE optimize call even on the
    rare 32-bit FNV1a collision. Identical plans across runs produce
    identical names (stable EXPLAIN + plan-cache keys) because both
    inputs (fingerprint canonical string + counter sequence) are
    deterministic given plan shape.

    Hash collision probability for 8 hex chars (32-bit space) is
    ~1.5e-5 at 1000 candidates per optimize call; the counter suffix
    breaks the rare tie. Pre-rewrite bytewise canonical-fingerprint
    equality check (done by the per-axis driver via the Dict[String, _]
    keying) ensures NO false-positive rewrite even on a hash collision.
    """
    var h32 = _fnv1a_lower32(fingerprint)
    var hex8 = _u32_to_hex8(h32)
    return String("_cse_") + hex8 + String("_") + String(counter.next())


@always_inline
def _fnv1a_lower32(s: String) -> UInt32:
    """FNV-1a 64-bit applied to the string bytes; return the low 32 bits.

    Standard FNV-1a constants (offset basis 0xcbf29ce484222325, prime
    0x100000001b3). Used purely as a NAME-shortening hash — the
    fingerprint string is still the load-bearing equality key in the
    rewriter Dict.
    """
    var h: UInt64 = 0xcbf29ce484222325
    var bs = s.as_bytes()
    for i in range(len(bs)):
        h = h ^ UInt64(Int(bs[i]))
        h = h * 0x100000001b3
    return UInt32(Int(h & 0xFFFFFFFF))


@always_inline
def _u32_to_hex8(n: UInt32) -> String:
    """Format a UInt32 as 8 lowercase hex chars (leading zero padded)."""
    comptime HEX = "0123456789abcdef"
    var nv = Int(n)
    var out = String("")
    for i in range(8):
        var nibble = (nv >> ((7 - i) * 4)) & 0xF
        out += HEX[byte=nibble]
    return out


@always_inline
def _sort_string_list(mut xs: List[String]):
    """Insertion-sort a List[String] in lexicographic order (stable, in-place).

    Used to make the fingerprint-iteration order deterministic across
    runs (Dict.items() iteration is not ordered). N is bounded by the
    number of distinct CSE candidates per node — typically <10.
    """
    var n = len(xs)
    for i in range(1, n):
        var j = i
        while j > 0 and xs[j] < xs[j - 1]:
            var tmp = xs[j - 1]
            xs[j - 1] = xs[j]
            xs[j] = tmp
            j -= 1


def _collect_and_conjuncts_local(expr: Expr, mut conjuncts: ExprArray):
    """Flatten top-level AND tree into a list of conjunct COPIES.

    Local twin of `optimizer_filter._collect_and_conjuncts` — that
    helper takes `var expr` (owning) and we have only a borrow here.
    Same semantics: `(A AND B) AND C` → `[A, B, C]`; non-AND
    expressions are added as a single leaf.
    """
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_AND:
        _collect_and_conjuncts_local(expr.binary_left_ref(), conjuncts)
        _collect_and_conjuncts_local(expr.binary_right_ref(), conjuncts)
    else:
        conjuncts.append(expr.copy())


@always_inline
def _count_cse_duplicates(plan: LogicalPlan) raises -> Int:
    """Count CSE-eligible duplicate fingerprints across all 3 axes (test diagnostic).

    Extension: previously only counted Project
    top-level whole-expression duplicates. Now extended to also count
    Axis-2 (Filter conjunct subtree) and Axis-3 (Aggregate agg-fn arg
    subtree) duplicates. Test `test_cse_count_duplicates` is preserved
    by the Project-axis arm continuing to return the Project-only
    whole-expression duplicate count when the plan is a Project.

    Returns 0 for plans that have neither Project / Filter / Aggregate
    at the top, or that have no duplicates. Used purely for testing
    and EXPLAIN diagnostics.
    """
    if plan.tag == PLAN_PROJECT:
        var fingerprints = List[String]()
        for i in range(len(plan._project.value()[].exprs)):
            fingerprints.append(_expr_fingerprint(plan._project.value()[].exprs[i]))
        var dup_count = 0
        for i in range(len(fingerprints)):
            for j in range(i):
                if fingerprints[i] == fingerprints[j]:
                    dup_count += 1
                    break
        return dup_count

    if plan.tag == PLAN_FILTER:
        var conjuncts = ExprArray()
        _collect_and_conjuncts_local(plan._filter.value()[].predicate, conjuncts)
        var counts = Dict[String, Int]()
        var exemplars = ExprArray()
        var fp_to_exidx = Dict[String, Int]()
        var depths = Dict[String, Int]()
        for i in range(len(conjuncts)):
            _collect_subtree_fingerprints(conjuncts[i], counts, exemplars, fp_to_exidx, depths)
        var dup = 0
        for entry in counts.items():
            if entry.value >= 2:
                dup += (entry.value - 1)
        return dup

    if plan.tag == PLAN_AGGREGATE:
        ref ad = plan._aggregate.value()[]
        var counts = Dict[String, Int]()
        var exemplars = ExprArray()
        var fp_to_exidx = Dict[String, Int]()
        var depths = Dict[String, Int]()
        for i in range(len(ad.agg_exprs)):
            ref agg = ad.agg_exprs[i]
            if agg.child:
                _collect_subtree_fingerprints(agg.child.value(), counts, exemplars, fp_to_exidx, depths)
            if agg.child1:
                _collect_subtree_fingerprints(agg.child1.value(), counts, exemplars, fp_to_exidx, depths)
            if agg.child2:
                _collect_subtree_fingerprints(agg.child2.value(), counts, exemplars, fp_to_exidx, depths)
            if agg.child3:
                _collect_subtree_fingerprints(agg.child3.value(), counts, exemplars, fp_to_exidx, depths)
        var dup = 0
        for entry in counts.items():
            if entry.value >= 2:
                dup += (entry.value - 1)
        return dup

    return 0


# =============================================================================
# Rule 21: IN Clause Rewrite
# =============================================================================

def rewrite_in_clauses(var plan: LogicalPlan) -> LogicalPlan:
    """Rewrite IN clause expressions for optimized evaluation.

    Detects OR chains of equality comparisons on one column
    (`col=1 OR col=2 OR col=3`, the expanded form of `col IN (1, 2, 3)`)
    and collapses every such chain of two or more leaves into one
    `EXPR_IN_LIST` node; an IN list of no values folds to FALSE and one of
    one value to `col == v` (`_rewrite_in_expr`). Filter predicates and
    Project expressions, the argument slots of an Aggregate's aggregate
    functions and a Join's residual condition are rewritten; an Aggregate's
    group-by keys are not (see `_rewrite_agg_and_residual_sites`).
    """
    rewrite_in_clauses_inplace(plan)
    return plan^


def rewrite_in_clauses_inplace(mut plan: LogicalPlan):
    """In-place IN-clause rewriting."""
    if plan.tag == PLAN_FILTER:
        rewrite_in_clauses_inplace(plan._filter.value()[].child[])
        var pred_copy = plan._filter.value()[].predicate.copy()
        var rewritten = _rewrite_in_expr(pred_copy^)
        plan._filter.value()[].predicate = rewritten^

    elif plan.tag == PLAN_PROJECT:
        rewrite_in_clauses_inplace(plan._project.value()[].child[])
        var new_exprs = ExprArray()
        for i in range(len(plan._project.value()[].exprs)):
            var expr_copy = plan._project.value()[].exprs[i].copy()
            new_exprs.append(_rewrite_in_expr(expr_copy^))
        plan._project.value()[].exprs = new_exprs^

    elif plan.tag == PLAN_AGGREGATE:
        rewrite_in_clauses_inplace(plan._aggregate.value()[].child[])
        _rewrite_agg_and_residual_sites[_SITE_RULE_IN](plan)

    elif plan.tag == PLAN_JOIN:
        rewrite_in_clauses_inplace(plan._join.value()[].left[])
        rewrite_in_clauses_inplace(plan._join.value()[].right[])
        _rewrite_agg_and_residual_sites[_SITE_RULE_IN](plan)

    elif plan.tag == PLAN_SORT:
        rewrite_in_clauses_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        rewrite_in_clauses_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        rewrite_in_clauses_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        rewrite_in_clauses_inplace(plan._topn.value()[].child[])


def _rewrite_in_expr(var expr: Expr) -> Expr:
    """Canonicalize OR-of-eq-on-same-col chains
    to `EXPR_IN_LIST`.

    Detection (`_count_or_eq_chain` + `_get_eq_chain_col`) already
    walked the OR-tree and confirmed every leaf is `col == lit` on the
    SAME column. When that holds at the top of an OR-tree, we flatten
    the leaves into a `List[ScalarValue]` and emit a single
    `EXPR_IN_LIST` node. The engine evaluator
    then probes the value table once per batch instead of N times.

    Recurses into AND children + unary/cast/alias — so a Filter
    predicate of the form `(big OR-tree) AND <residual>` collapses the
    OR-tree side and leaves the residual untouched.

    Threshold: K >= 2. K=1 stays as `col == lit` (cheaper). K=0 (empty)
    cannot occur (the SQL surface raises before this point).
    """
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()

        if op == BIN_OR:
            # Try to collapse the entire OR-tree first.
            var n = _count_or_eq_chain(expr)
            if n >= 2:
                var col_name = _get_eq_chain_col(expr)
                if col_name != "":
                    # Flatten and rebuild.
                    var values = List[ScalarValue]()
                    _collect_or_eq_values(expr, values)
                    if len(values) == n:
                        return Expr.in_list_node(
                            Expr.col_ref(col_name), values^
                        )
            # Fall through: not a uniform-col OR-of-eq chain, recurse
            # into both sides for nested IN-shape sub-trees.
            var left = _rewrite_in_expr(expr.binary_left().copy())
            var right = _rewrite_in_expr(expr.binary_right().copy())
            return Expr.binary(op, left^, right^)

        # AND / comparisons / arithmetic: recurse, rebuild.
        var left = _rewrite_in_expr(expr.binary_left().copy())
        var right = _rewrite_in_expr(expr.binary_right().copy())
        return Expr.binary(op, left^, right^)

    elif expr.tag == EXPR_UNARY_OP:
        var child = _rewrite_in_expr(expr.unary_child().copy())
        return Expr.unary(expr.unary_op(), child^)

    elif expr.tag == EXPR_CAST:
        # `cast_preserving_arrow` — see `_fold_expr`'s EXPR_CAST arm.
        var child = _rewrite_in_expr(expr.cast_child().copy())
        return Expr.cast_preserving_arrow(child^, expr)

    elif expr.tag == EXPR_ALIAS:
        var child = _rewrite_in_expr(expr.alias_child().copy())
        return Expr.alias(child^, expr.alias_name())

    elif expr.tag == EXPR_IN_LIST:
        # IN-list edge-case folds:
        #   5a EMPTY-CONSTANT-FOLD: `col IN ()` → `lit(False)`. An empty
        #      set has no members, so membership is always FALSE
        #      regardless of the column value. Matches the SQL semantics
        #      mirrored at the `Expr.in_list(...)` factory site
        #      (expr.mojo).
        #   5b SINGLE-ELEM-SIMPLIFY: `col IN (a)` → `col == a`. Drops the
        #      EXPR_IN_LIST IR overhead in favor of the cheaper
        #      `EXPR_BINARY_OP(BIN_EQ)` shape the engine already
        #      specializes (and other optimizer rules — column-range
        #      pruning, dyn-filter pushdown, sargable-predicate
        #      detection — match against).
        # The folds are emitted even when the EXPR_IN_LIST node was
        # constructed directly via `Expr.in_list_node(...)`, which (unlike
        # `Expr.in_list(...)`) does NOT pre-fold at construction time.
        var n = expr.in_list_len()
        if n == 0:
            return Expr.literal(ScalarValue.from_bool(False))
        if n == 1:
            var v0 = expr.in_list_values_ref()[0].copy()
            return Expr.binary(
                BIN_EQ, expr.in_list_child(), Expr.literal(v0^)
            )

    return expr^


def _collect_or_eq_values(expr: Expr, mut out: List[ScalarValue]):
    """Helper: walk an OR-tree of `col == lit` leaves and
    append each leaf's literal to `out`. Caller must have validated the
    tree shape via `_count_or_eq_chain` + `_get_eq_chain_col` first."""
    if expr.tag != EXPR_BINARY_OP:
        return
    var op = expr.binary_op()
    if op == BIN_OR:
        _collect_or_eq_values(expr.binary_left_ref(), out)
        _collect_or_eq_values(expr.binary_right_ref(), out)
    elif op == BIN_EQ:
        # Either ColRef==Literal or Literal==ColRef.
        if expr.binary_left_ref().tag == EXPR_LITERAL:
            out.append(expr.binary_left_ref().literal_value())
        elif expr.binary_right_ref().tag == EXPR_LITERAL:
            out.append(expr.binary_right_ref().literal_value())


@always_inline
def _is_col_eq_literal(expr: Expr) -> Bool:
    """Check if an expression is of the form ColRef = Literal."""
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_EQ:
        # Use ref accessors directly to avoid copy (Expr is not ImplicitlyCopyable)
        if expr.binary_left_ref().tag == EXPR_COL_REF and expr.binary_right_ref().tag == EXPR_LITERAL:
            return True
        if expr.binary_left_ref().tag == EXPR_LITERAL and expr.binary_right_ref().tag == EXPR_COL_REF:
            return True
    return False


def _get_eq_col_name(expr: Expr) -> String:
    """Extract the column name from a col = literal expression.

    Returns empty string if not a col = literal pattern.
    """
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_EQ:
        if expr.binary_left_ref().tag == EXPR_COL_REF and expr.binary_right_ref().tag == EXPR_LITERAL:
            return expr.binary_left_ref().col_ref_name()
        if expr.binary_left_ref().tag == EXPR_LITERAL and expr.binary_right_ref().tag == EXPR_COL_REF:
            return expr.binary_right_ref().col_ref_name()
    return String("")


def _count_or_eq_chain(expr: Expr) -> Int:
    """Count the number of col = literal terms in an OR chain on the same column.

    Returns 0 if the expression is not a valid IN-clause OR chain.
    Returns the count of terms if all OR leaves are col = literal on the same column.
    """
    if expr.tag != EXPR_BINARY_OP:
        return 0

    if expr.binary_op() == BIN_EQ:
        if _is_col_eq_literal(expr):
            return 1
        return 0

    if expr.binary_op() == BIN_OR:
        var left_count = _count_or_eq_chain(expr.binary_left_ref())
        var right_count = _count_or_eq_chain(expr.binary_right_ref())
        if left_count == 0 or right_count == 0:
            return 0
        # Verify all terms reference the same column
        var left_col = _get_eq_chain_col(expr.binary_left_ref())
        var right_col = _get_eq_chain_col(expr.binary_right_ref())
        if left_col == right_col and left_col != "":
            return left_count + right_count
        return 0

    return 0


def _get_eq_chain_col(expr: Expr) -> String:
    """Get the column name from an OR chain of col = literal terms.

    Returns empty string if not a valid OR chain on a single column.
    """
    if expr.tag == EXPR_BINARY_OP:
        if expr.binary_op() == BIN_EQ:
            return _get_eq_col_name(expr)
        if expr.binary_op() == BIN_OR:
            return _get_eq_chain_col(expr.binary_left_ref())
    return String("")


# =============================================================================
# Tier 1 Expr → kernel template
# matcher
#
# Walk a single Expr node and, if its shape (tag + binary_op +
# child kinds + literal dtype) matches one of the comptime-monomorphized
# kernel templates registered in `komira_kernels/expr_kernel_templates.mojo`,
# return the stable template-id. Otherwise return None — the caller falls back
# to InterpretedExprKernel (template-id 0) or the legacy engine evaluator.
#
# This is a PURE READ function — does NOT mutate the Expr tree, does NOT
# allocate beyond the returned `Optional[Int]`. It's wired into the
# optimizer pipeline by the plan compiler, which switches on the
# returned template-id to emit the corresponding MorselOp variant.
#
# 3.a's matcher handles ColLit shapes
# only (literal dtype is determinable from `ScalarValue.dtype`); ColCol
# shapes return None because the matcher has no schema context to determine
# the ColRef's dtype. ColCol shapes WILL match once a later change plumbs
# schema context through the optimizer pass; the ColCol templates already
# exist in the registry (IDs 1-16) and the matcher is structured to add
# ColCol matching as a small extension once schema context is available.
#
# Contract:
#   - Returns `Optional.some(id)` for any Expr shape that has an active
#     template binding in 3.a (currently: ColLit shapes for arithmetic +
#     comparison on F64+I64).
#   - Returns `Optional.none()` (NOT `EXPR_TEMPLATE_INTERPRETED`) when no
#     template matches — caller's responsibility to decide the fallback path.
#   - Pre-existing optimizer rules (fold_constants, simplify_predicates,
#     eliminate_common_subexpressions, rewrite_in_clauses) MUST run BEFORE
#     this matcher in the optimizer pipeline so the matcher sees canonical
#     / minimized Expr trees.
# =============================================================================


def _match_arith_collit_f64(op: UInt8) -> Int:
    """Map a BIN_* op to its F64 ColLit arithmetic template-id.
    Returns 0 (INTERPRETED) if op is not in the F64 ColLit arith set.
    """
    if op == BIN_ADD:
        return EXPR_TEMPLATE_ADD_F64_COLLIT
    if op == BIN_SUB:
        return EXPR_TEMPLATE_SUB_F64_COLLIT
    if op == BIN_MUL:
        return EXPR_TEMPLATE_MUL_F64_COLLIT
    if op == BIN_DIV:
        return EXPR_TEMPLATE_DIV_F64_COLLIT
    return EXPR_TEMPLATE_INTERPRETED


def _match_arith_collit_i64(op: UInt8) -> Int:
    """Map a BIN_* op to its I64 ColLit arithmetic template-id.
    Returns 0 (INTERPRETED) if op is not in the I64 ColLit arith set.
    """
    if op == BIN_ADD:
        return EXPR_TEMPLATE_ADD_I64_COLLIT
    if op == BIN_SUB:
        return EXPR_TEMPLATE_SUB_I64_COLLIT
    if op == BIN_MUL:
        return EXPR_TEMPLATE_MUL_I64_COLLIT
    if op == BIN_DIV:
        return EXPR_TEMPLATE_DIV_I64_COLLIT
    return EXPR_TEMPLATE_INTERPRETED


def _match_cmp_collit_f64(op: UInt8) -> Int:
    """Map a BIN_* op to its F64 ColLit comparison template-id.
    Returns 0 (INTERPRETED) if op is not in the F64 ColLit cmp set.
    """
    if op == BIN_GT:
        return EXPR_TEMPLATE_GT_F64_COLLIT
    if op == BIN_GE:
        return EXPR_TEMPLATE_GE_F64_COLLIT
    if op == BIN_LT:
        return EXPR_TEMPLATE_LT_F64_COLLIT
    if op == BIN_LE:
        return EXPR_TEMPLATE_LE_F64_COLLIT
    if op == BIN_EQ:
        return EXPR_TEMPLATE_EQ_F64_COLLIT
    if op == BIN_NE:
        return EXPR_TEMPLATE_NE_F64_COLLIT
    return EXPR_TEMPLATE_INTERPRETED


def _match_cmp_collit_i64(op: UInt8) -> Int:
    """Map a BIN_* op to its I64 ColLit comparison template-id.
    Returns 0 (INTERPRETED) if op is not in the I64 ColLit cmp set.
    """
    if op == BIN_GT:
        return EXPR_TEMPLATE_GT_I64_COLLIT
    if op == BIN_GE:
        return EXPR_TEMPLATE_GE_I64_COLLIT
    if op == BIN_LT:
        return EXPR_TEMPLATE_LT_I64_COLLIT
    if op == BIN_LE:
        return EXPR_TEMPLATE_LE_I64_COLLIT
    if op == BIN_EQ:
        return EXPR_TEMPLATE_EQ_I64_COLLIT
    if op == BIN_NE:
        return EXPR_TEMPLATE_NE_I64_COLLIT
    return EXPR_TEMPLATE_INTERPRETED


def _match_expr_to_kernel_template(expr: Expr) -> Optional[Int]:
    """Return the template-id (>0) of the kernel template that handles this
    Expr shape, or None if no template matches.

    Phase 3.a scope:
    - Matches ColLit shapes only (ColRef on left, Literal on right OR
      Literal on left, ColRef on right — both orientations supported).
    - Dtype determined from `ScalarValue.dtype` on the literal side.
    - F64 + I64 ColLit shapes match for both arithmetic (ADD/SUB/MUL/DIV)
      and comparison (GT/GE/LT/LE/EQ/NE) ops.
    - Other op/dtype combinations return None.
    - ColCol shapes (both children EXPR_COL_REF) return None — schema
      context for ColRef dtype determination is NOT available at the
      matcher level today; a later change plumbs that through.
    - Non-binary Exprs (UN_*, EXPR_CAST, EXPR_WHEN, EXPR_IN_LIST, etc.)
      return None — those are 3.b template targets.

    EXPR_IN_LIST (tag 9) is intentionally a
    pass-through; the engine has its own probe-table fast path for
    canonicalized OR-of-eq chains. Same for EXPR_ALIAS, EXPR_COL_REF,
    EXPR_LITERAL, EXPR_COL_IDX (operand-shapes, not their own kernels).
    """
    # Phase 3.b — UN_NEGATE / UN_NOT / UN_IS_NULL / UN_IS_NOT_NULL
    # These unary templates use the F64 / I64
    # default (matcher has no schema context for the child ColRef's exact
    # dtype). A later change will refine via schema-context plumbing. Until
    # then, the unary matcher returns the default-dtype ID; the engine
    # dispatch arm picks the actual dtype variant via the column's known
    # arrow type. For coverage trip-wire purposes, the matcher returning
    # ANY in-band ID demonstrates that the registry contains the entry.
    if expr.tag == EXPR_UNARY_OP:
        var u_op = expr.unary_op()
        # NOT requires a Bool child; templates 49-56/49-50/etc. share the
        # IS_NULL/IS_NOT_NULL family. Default to F64 variants.
        if u_op == UN_NOT:
            return Optional[Int](EXPR_TEMPLATE_NOT_BOOL)
        if u_op == UN_NEGATE:
            return Optional[Int](EXPR_TEMPLATE_NEGATE_F64)
        if u_op == UN_IS_NULL:
            return Optional[Int](EXPR_TEMPLATE_IS_NULL_F64)
        if u_op == UN_IS_NOT_NULL:
            return Optional[Int](EXPR_TEMPLATE_IS_NOT_NULL_F64)
        return None

    # Phase 3.b — EXPR_CAST. Default to F64↔F32 / I64↔I32 / F64↔I64 / etc.
    # The matcher returns the cast template-id when the cast target dtype
    # is in the supported set. Source dtype defaults to F64/I64 absent
    # schema context.
    if expr.tag == EXPR_CAST:
        var tgt = expr.cast_target()
        if tgt == DType.float32:
            return Optional[Int](EXPR_TEMPLATE_CAST_F64_TO_F32)
        if tgt == DType.float64:
            # could be F32→F64, I64→F64, I32→F64; default to I64→F64 (most common)
            return Optional[Int](EXPR_TEMPLATE_CAST_I64_TO_F64)
        if tgt == DType.int32:
            return Optional[Int](EXPR_TEMPLATE_CAST_I64_TO_I32)
        if tgt == DType.int64:
            return Optional[Int](EXPR_TEMPLATE_CAST_F64_TO_I64)
        return None

    if expr.tag != EXPR_BINARY_OP:
        return None

    var op = expr.binary_op()
    var left_tag = expr.binary_left_ref().tag
    var right_tag = expr.binary_right_ref().tag

    # Phase 3.b — BIN_AND / BIN_OR over two predicates. The matcher returns
    # the AND_BOOL / OR_BOOL template-id whenever both sides are themselves
    # binary-op or unary Exprs that could produce Bool (most natural shape
    # is two BIN_* comparisons). The dispatcher / engine validates that the
    # children actually produce Bool; the matcher's job here is shape-only.
    if op == BIN_AND:
        if left_tag == EXPR_BINARY_OP or left_tag == EXPR_UNARY_OP:
            if right_tag == EXPR_BINARY_OP or right_tag == EXPR_UNARY_OP:
                return Optional[Int](EXPR_TEMPLATE_AND_BOOL)
    if op == BIN_OR:
        if left_tag == EXPR_BINARY_OP or left_tag == EXPR_UNARY_OP:
            if right_tag == EXPR_BINARY_OP or right_tag == EXPR_UNARY_OP:
                return Optional[Int](EXPR_TEMPLATE_OR_BOOL)

    # Phase 3.b — BIN_MOD ColCol. Defaults to I64; I32 variant requires
    # schema context (deferred).
    if op == BIN_MOD and left_tag == EXPR_COL_REF and right_tag == EXPR_COL_REF:
        return Optional[Int](EXPR_TEMPLATE_MOD_I64_COLCOL)

    # ColLit shape — ColRef on left, Literal on right.
    if left_tag == EXPR_COL_REF and right_tag == EXPR_LITERAL:
        var lit_dtype = expr.binary_right_ref().literal_value().dtype
        if lit_dtype == DType.float64:
            # Arithmetic vs comparison
            if op == BIN_ADD or op == BIN_SUB or op == BIN_MUL or op == BIN_DIV:
                var t = _match_arith_collit_f64(op)
                if t != EXPR_TEMPLATE_INTERPRETED:
                    return Optional[Int](t)
            if op == BIN_GT or op == BIN_GE or op == BIN_LT or op == BIN_LE or op == BIN_EQ or op == BIN_NE:
                var t = _match_cmp_collit_f64(op)
                if t != EXPR_TEMPLATE_INTERPRETED:
                    return Optional[Int](t)
        elif lit_dtype == DType.int64 or lit_dtype == DType.int32:
            # int32 literals for I64 column comparisons (e.g. Date32-as-Int) work too
            if op == BIN_ADD or op == BIN_SUB or op == BIN_MUL or op == BIN_DIV:
                var t = _match_arith_collit_i64(op)
                if t != EXPR_TEMPLATE_INTERPRETED:
                    return Optional[Int](t)
            if op == BIN_GT or op == BIN_GE or op == BIN_LT or op == BIN_LE or op == BIN_EQ or op == BIN_NE:
                var t = _match_cmp_collit_i64(op)
                if t != EXPR_TEMPLATE_INTERPRETED:
                    return Optional[Int](t)
        # No match for this lit dtype — fall through to None below.

    # ColLit shape — Literal on left, ColRef on right (commutative cases).
    # Only commutative ops (ADD, MUL, EQ, NE) match here without re-orientation.
    # Non-commutative ops (SUB, DIV, GT, GE, LT, LE) on Lit-on-left would need
    # a separate template family or a normalization pass — neither exists in
    # 3.a, so this orientation only matches commutative ops.
    if left_tag == EXPR_LITERAL and right_tag == EXPR_COL_REF:
        var lit_dtype = expr.binary_left_ref().literal_value().dtype
        if lit_dtype == DType.float64:
            if op == BIN_ADD:
                return Optional[Int](EXPR_TEMPLATE_ADD_F64_COLLIT)
            if op == BIN_MUL:
                return Optional[Int](EXPR_TEMPLATE_MUL_F64_COLLIT)
            if op == BIN_EQ:
                return Optional[Int](EXPR_TEMPLATE_EQ_F64_COLLIT)
            if op == BIN_NE:
                return Optional[Int](EXPR_TEMPLATE_NE_F64_COLLIT)
        elif lit_dtype == DType.int64 or lit_dtype == DType.int32:
            if op == BIN_ADD:
                return Optional[Int](EXPR_TEMPLATE_ADD_I64_COLLIT)
            if op == BIN_MUL:
                return Optional[Int](EXPR_TEMPLATE_MUL_I64_COLLIT)
            if op == BIN_EQ:
                return Optional[Int](EXPR_TEMPLATE_EQ_I64_COLLIT)
            if op == BIN_NE:
                return Optional[Int](EXPR_TEMPLATE_NE_I64_COLLIT)

    # ColCol, Lit-Lit (already constant-folded), nested compounds, and any
    # shape that didn't match above: return None (caller falls back to
    # InterpretedExprKernel or the legacy engine evaluator).
    return None
