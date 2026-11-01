# =============================================================================
# komira_dispatch_sources.plan_leaf_servable -- the leaf-servability pre-gates:
#   can every leaf scan under a plan be served by the parquet leaf or the
#   in-memory leaf?
# =============================================================================
#
# The forest executor runs several plans together, and its non-breaker leaf
# raises (rather than declines) on a source it cannot serve. So before its
# first attempt it asks `_subtree_all_leaf_scans_servable` of every member and
# declines the whole forest on a miss.
#
# Every function here reads plan tags, the scan's source type and `Expr` trees,
# returns a Bool and never raises, which is what makes it usable in front of a
# raising leaf. Nothing executes.
#
# `_inmem_pushed_filter_servable` mirrors the in-memory leaf's own predicate
# recognizer (the one its filter resolution uses), so that this pre-gate needs
# none of the leaf's imports. The two must change together: a shape the leaf
# serves and this gate refuses is declined, and a declined forest raises at its
# caller.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_STRING_OP,
    EXPR_IN_LIST,
    EXPR_REGEXP,
    EXPR_LITERAL,
    EXPR_CAST,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    UN_NOT,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    PLAN_SCAN,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_TOPN,
    PLAN_JOIN,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_PROJECT,
)


def _is_column(imm e: Expr) -> Bool:
    """True iff `e` is a column reference, by name or by index."""
    return e.tag == EXPR_COL_REF or e.tag == EXPR_COL_IDX


def _pushed_filter_is_arith_value(imm e: Expr) -> Bool:
    """True iff `e` is a value the column evaluator can materialize as the
    right-hand side of `col CMP <value>` (`qty_sum * 0.5`): a column
    reference, a literal, a CAST of such a value, or ADD/SUB/MUL/DIV over two
    such values. The in-memory leaf's recognizer accepts the same set."""
    if _is_column(e) or e.is_literal():
        return True
    if e.tag == EXPR_CAST:
        return _pushed_filter_is_arith_value(e.cast_child_ref())
    if e.tag == EXPR_BINARY_OP:
        var bop = e.binary_op()
        if bop == BIN_ADD or bop == BIN_SUB or bop == BIN_MUL or bop == BIN_DIV:
            return _pushed_filter_is_arith_value(
                e.binary_left_ref()
            ) and _pushed_filter_is_arith_value(e.binary_right_ref())
        return False
    return False


def _inmem_pushed_filter_servable(imm pred: Expr) -> Bool:
    """True iff `pred`, a filter pushed onto an in-memory scan, is one the
    in-memory leaf's filter evaluator serves without raising.

    The accepted shapes:
      * AND / OR of accepted shapes;
      * a comparison (EQ, NE, LT, LE, GT, GE) whose LEFT operand is a column
        and whose right operand is a literal, a column or an arithmetic value
        (`_pushed_filter_is_arith_value`); the evaluator resolves the left
        operand as the column;
      * NOT of an accepted shape; IS NULL and IS NOT NULL of a column;
      * a string op, an IN list or a REGEXP over a column;
      * a BOOL literal (the optimizer folds `col IN ()` to `false`). A literal
        of another type is refused: the evaluator reads the literal's bool
        value unconditionally.
    Anything else returns False."""
    if pred.tag == EXPR_BINARY_OP:
        var op = pred.binary_op()
        if op == BIN_AND or op == BIN_OR:
            return _inmem_pushed_filter_servable(
                pred.binary_left_ref()
            ) and _inmem_pushed_filter_servable(pred.binary_right_ref())
        if (
            op == BIN_EQ
            or op == BIN_NE
            or op == BIN_LT
            or op == BIN_LE
            or op == BIN_GT
            or op == BIN_GE
        ):
            if not _is_column(pred.binary_left_ref()):
                return False
            return _pushed_filter_is_arith_value(pred.binary_right_ref())
        return False
    if pred.tag == EXPR_UNARY_OP:
        var op = pred.unary_op()
        if op == UN_NOT:
            return _inmem_pushed_filter_servable(pred.unary_child_ref())
        if op == UN_IS_NULL or op == UN_IS_NOT_NULL:
            return _is_column(pred.unary_child_ref())
        return False
    if pred.tag == EXPR_STRING_OP:
        return _is_column(pred.string_op_child_ref())
    if pred.tag == EXPR_IN_LIST:
        return _is_column(pred.in_list_child_ref())
    if pred.tag == EXPR_REGEXP:
        return _is_column(pred.regexp_child_ref())
    if pred.tag == EXPR_LITERAL:
        return pred.literal_value().is_bool()
    return False


def _is_servable_inmem_leaf(imm plan: LogicalPlan) -> Bool:
    """True iff `plan` is a `SCAN(SOURCE_IN_MEMORY)` leaf the in-memory leaf
    serves: no pushed filter, or a pushed filter `_inmem_pushed_filter_servable`
    accepts."""
    if plan.tag != PLAN_SCAN or not plan._scan:
        return False
    ref sd = plan.scan_data_ref()
    if sd.source_type != SOURCE_IN_MEMORY:
        return False
    if sd.filter:
        return _inmem_pushed_filter_servable(sd.filter.value())
    return True


def _subtree_all_leaf_scans_servable(imm plan: LogicalPlan) -> Bool:
    """True iff every leaf scan reachable under `plan` is a `SOURCE_PARQUET`
    scan or a servable in-memory leaf (`_is_servable_inmem_leaf`).

    The walk descends through FILTER, PROJECT, AGGREGATE, SORT, TOPN and
    DISTINCT, and both sides of a JOIN. Any other node (union, limit, view
    reference, window, ...), any other source (CSV, NDJSON, ...), an in-memory
    leaf with a filter outside the envelope, or a node whose payload is
    missing returns False."""
    var tag = plan.tag
    if tag == PLAN_SCAN:
        if not plan._scan:
            return False
        if plan.scan_data_ref().source_type == SOURCE_PARQUET:
            return True
        return _is_servable_inmem_leaf(plan)
    if tag == PLAN_FILTER:
        if not plan._filter:
            return False
        return _subtree_all_leaf_scans_servable(plan.filter_data_ref().child[])
    if tag == PLAN_PROJECT:
        if not plan._project:
            return False
        return _subtree_all_leaf_scans_servable(plan.project_data_ref().child[])
    if tag == PLAN_AGGREGATE:
        if not plan._aggregate:
            return False
        return _subtree_all_leaf_scans_servable(
            plan.aggregate_data_ref().child[]
        )
    if tag == PLAN_SORT:
        if not plan._sort:
            return False
        return _subtree_all_leaf_scans_servable(plan.sort_data_ref().child[])
    if tag == PLAN_TOPN:
        if not plan._topn:
            return False
        return _subtree_all_leaf_scans_servable(plan.topn_data_ref().child[])
    if tag == PLAN_DISTINCT:
        if not plan._distinct:
            return False
        return _subtree_all_leaf_scans_servable(
            plan.distinct_data_ref().child[]
        )
    if tag == PLAN_JOIN:
        if not plan._join:
            return False
        ref jd = plan.join_data_ref()
        return _subtree_all_leaf_scans_servable(
            jd.left[]
        ) and _subtree_all_leaf_scans_servable(jd.right[])
    return False
