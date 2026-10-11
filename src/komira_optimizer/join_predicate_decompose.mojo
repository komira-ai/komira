# =============================================================================
# Optimizer rule: join_predicate_decompose
# Non-equi join predicate decomposition
# =============================================================================
#
# Non-equi / range / complex join support. A DataFrame-style `predicate=`
# join (`l1.anti_join(l3, predicate=(Expr.left("a")==Expr.right("b")) & ...)`;
# that frontend is not in this tree) builds a `LogicalPlan.join` that carries
# the raw, side-qualified predicate Expr in `JoinData.residual` with
# `left_on`/`right_on` empty. THIS pass walks the plan, finds every PLAN_JOIN
# carrying such a raw residual, and decomposes it:
#
#   - Each AND-conjunct of the form `Expr.left("X") BIN_EQ Expr.right("Y")`
#     (or the swapped `Expr.right("Y") BIN_EQ Expr.left("X")`), where BOTH
#     sides are bare side-qualified col-refs, is LIFTED into the equi-key
#     fast path (`left_on += "X"`, `right_on += "Y"`).
#   - Every OTHER conjunct (NEQ, range comparisons, EQ-on-non-bare-colrefs,
#     arbitrary boolean sub-expressions) is AND'd back together into the new
#     `residual` Expr, with its side qualifiers REWRITTEN to plain
#     (COL_SIDE_NONE) col-refs resolvable against the joined-row schema:
#     left-input columns keep their name; right-input columns keep their
#     name unless it collides with a left-input column, in which case the
#     `<name>_right` form (matching `LogicalPlan.join`'s schema-builder) is
#     used. If no residual conjunct survives, `residual` becomes None and the
#     join is a pure equi-join indistinguishable from a classic `on=` join.
#   - Evaluating the residual is outside komira_optimizer: the plan
#     compiler and the residual join probe that consume it are not in this
#     tree. The residual is designed to be evaluated per candidate
#     equi-matched (or, with zero equi-keys, cross-product) pair, per join
#     type (INNER keeps passing pairs; LEFT also NULL-fills left rows with no
#     passing pair; SEMI/ANTI test whether a passing pair exists).
#
#   Important downstream-rule invariant: this pass is designed to run
#   BEFORE every join-reorder / rebuild rule. The ~20 sites that
#   rebuild `LogicalPlan.join(...)` all default `residual=None`. For a
#   residual-carrying join that would silently DROP the condition (→ wrong
#   results). `optimizer_reorder` treats a residual-carrying join as an
#   opaque leaf and rebuilds it with its residual; any other rule that
#   reaches one MUST preserve `residual`.
#
# References — studied before coding:
#   - DuckDB `src/include/duckdb/planner/operator/logical_comparison_join.hpp`
#     + `src/include/duckdb/planner/joinside.hpp`: `LogicalComparisonJoin`
#     carries `vector<JoinCondition>` where each `JoinCondition` is
#     `{left, right, comparison: ExpressionType}` — the per-condition
#     operator is what lets DuckDB express NEQ / range join conditions.
#     Komira's equivalent is `left_on`/`right_on` for the `==` conditions
#     PLUS this `residual` Expr for everything else.
#   - DuckDB `src/planner/subquery/flatten_dependent_join.cpp:195-260`
#     (`CreateDelimJoinConditions`): builds `JoinCondition` objects from a
#     flattened correlated subquery, including `COMPARE_NOTEQUAL`. This
#     pass is designed to run AFTER `flatten_dependent_joins` so a flattened correlated
#     subquery's join gets decomposed if it ever carries a
#     `predicate=`-style residual.
#   - DataFusion `physical-plan/src/joins/`: `HashJoinExec` carries
#     `filter: Option<JoinFilter>` evaluated per matched probe-row in the
#     probe loop (`apply_join_filter_to_indices` in `utils.rs`) — exactly
#     the `residual` shape. `nested_loop_join.rs` is the reference for the zero-equi-
#     key (pure-range / band) fallback.
#
# Pass order: `optimizer_driver.optimize` runs this pass AFTER
# `flatten_dependent_joins` and BEFORE the join-reorder / rebuild rules (see the invariant above). Idempotent: a
# re-run is a no-op because after the first run the residual contains only
# plain (COL_SIDE_NONE) col-refs, so `_residual_needs_decompose` returns False.
# =============================================================================

from std.memory import OwnedPointer
from std.collections import Optional

from komira_collections.slab import Slab
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_AGG_FN,
    BIN_EQ,
    BIN_AND,
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
    WhenCaseData,
)
from komira_plan_expr.expr_helpers import flatten_and_conjuncts
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
)


# =============================================================================
# Public API
# =============================================================================


def join_predicate_decompose(var plan: LogicalPlan) raises -> LogicalPlan:
    """Top-level entry: decompose every raw `predicate=` join residual in
    `plan`.

    Walks the plan recursively. At each PLAN_JOIN whose `residual` is a raw,
    side-qualified predicate, splits the residual's AND-conjuncts into
    equi-key conjuncts (lifted into `left_on`/`right_on`) and surviving
    conjuncts (AND'd into the rewritten residual). Idempotent.

    Raises: no residual shape is rejected. A conjunct that does not lift
    into an equi-key stays in the residual, rewritten to plain col-refs
    (an Expr kind the rewrite walker does not list is deep-copied as-is).
    """
    join_predicate_decompose_inplace(plan)
    return plan^


def join_predicate_decompose_inplace(mut plan: LogicalPlan) raises:
    """In-place mirror of `join_predicate_decompose`.

    Recurses children FIRST, then decomposes at this node. The recursion
    pattern follows `flatten_dependent_joins_inplace`.
    """
    if plan.tag == PLAN_FILTER:
        join_predicate_decompose_inplace(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        join_predicate_decompose_inplace(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        join_predicate_decompose_inplace(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        join_predicate_decompose_inplace(plan._join.value()[].left[])
        join_predicate_decompose_inplace(plan._join.value()[].right[])
        _maybe_decompose_join(plan)
    elif plan.tag == PLAN_SORT:
        join_predicate_decompose_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        join_predicate_decompose_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        join_predicate_decompose_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        join_predicate_decompose_inplace(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        join_predicate_decompose_inplace(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        join_predicate_decompose_inplace(plan._partition_topn.value()[].child[])
    elif plan.tag == PLAN_UNION:
        ref children = plan._union.value()[].children
        for i in range(len(children)):
            join_predicate_decompose_inplace(children[i][])
    # PLAN_SCAN, PLAN_ASOF_JOIN, PLAN_VIEW_REF, PLAN_CSE_REF: leaves /
    # no `predicate=` residual to decompose.


# =============================================================================
# Per-join decomposition
# =============================================================================


def _maybe_decompose_join(mut plan: LogicalPlan) raises:
    """If `plan` is a PLAN_JOIN carrying a raw side-qualified residual,
    decompose it in place."""
    if plan.tag != PLAN_JOIN:
        return
    if not plan._join.value()[].has_residual():
        return
    # Only decompose if the residual still carries side qualifiers (i.e. it
    # is a raw `predicate=` expression, not an already-decomposed residual).
    if not _residual_needs_decompose(plan._join.value()[].residual.value()[]):
        return

    # Snapshot the left-input column names for collision-aware right-side
    # rewriting (matches `LogicalPlan.join`'s schema-builder).
    var left_cols = List[String]()
    ref left_schema = plan._join.value()[].left[].output_schema
    for i in range(left_schema.num_columns()):
        left_cols.append(left_schema.field_name(i))

    var raw = plan._join.value()[].residual.value()[].copy()
    var conjuncts = flatten_and_conjuncts(raw)

    var new_left_on = plan._join.value()[].left_on.copy()
    var new_right_on = plan._join.value()[].right_on.copy()
    var residual_conjuncts = Slab[Expr]()

    for i in range(len(conjuncts)):
        ref c = conjuncts[i]
        var lifted = _try_lift_equi_conjunct(c, new_left_on, new_right_on)
        if not lifted:
            # Surviving conjunct — rewrite qualifiers to plain col-refs.
            residual_conjuncts.append(_rewrite_strip_sides(c, left_cols))

    var new_residual: Optional[OwnedPointer[Expr]] = None
    if len(residual_conjuncts) > 0:
        var acc = residual_conjuncts[0].copy()
        for i in range(1, len(residual_conjuncts)):
            acc = Expr.binary(BIN_AND, acc^, residual_conjuncts[i].copy())
        new_residual = OwnedPointer(acc^)

    # A surviving residual (any conjunct that did not lift into an
    # equi-key) stays on the join for the caller that executes the plan
    # (not in this tree) to evaluate against each matched pair (or, with
    # zero equi-keys, each cross-product pair). The residual conjuncts have
    # already been rewritten to plain (COL_SIDE_NONE) col-refs over the
    # joined-row schema, so a re-run of this pass is a no-op
    # (`_residual_needs_decompose` returns False).
    #
    # NB: this pass is designed to run BEFORE every join-reorder /
    # rebuild rule — and either fully lifts the residual into equi-keys
    # (residual=None, indistinguishable from a classic `on=` join) or
    # produces a fully-rewritten residual. Downstream rules that rebuild
    # `LogicalPlan.join(...)` default `residual=None`; for a residual-carrying
    # join those rules would silently drop the condition, so the audit
    # constraint is: NO downstream rule may reorder/split a residual-carrying
    # join. `optimizer_reorder` treats a residual-carrying join as an opaque
    # leaf and rebuilds it with its residual; if another rule reaches a
    # residual-carrying join it must preserve `residual`. Nothing in this
    # tree detects a dropped or a *partially* dropped residual. Keep this
    # invariant in mind when adding join rules.

    # Rebuild the JoinData with the lifted equi-keys + the rewritten residual.
    # Children / join_type / algo_hint preserved.
    var jt = plan._join.value()[].join_type
    var algo = plan._join.value()[].algo_hint
    var left_plan = plan._join.value()[].left[].copy()
    var right_plan = plan._join.value()[].right[].copy()
    plan = LogicalPlan.join(
        left_plan^, right_plan^, new_left_on^, new_right_on^, jt, algo,
        new_residual^,
    )


# =============================================================================
# Conjunct classification: equi-key liftability
# =============================================================================


def _try_lift_equi_conjunct(
    c: Expr, mut left_on: List[String], mut right_on: List[String],
) -> Bool:
    """If `c` is `Expr.left("X") BIN_EQ Expr.right("Y")` (or the swapped
    form), append "X" to `left_on` and "Y" to `right_on` and return True;
    otherwise return False (the conjunct stays in the residual).

    Both operands must be BARE side-qualified col-refs. An EQ between a
    qualified col-ref and a literal / expression, or between two same-side
    col-refs, is NOT liftable — it goes to the residual.
    """
    if c.tag != EXPR_BINARY_OP:
        return False
    if c.binary_op() != BIN_EQ:
        return False
    ref lhs = c.binary_left_ref()
    ref rhs = c.binary_right_ref()
    if lhs.tag != EXPR_COL_REF or rhs.tag != EXPR_COL_REF:
        return False
    var ls = lhs.col_ref_side()
    var rs = rhs.col_ref_side()
    if ls == COL_SIDE_LEFT and rs == COL_SIDE_RIGHT:
        left_on.append(lhs.col_ref_name())
        right_on.append(rhs.col_ref_name())
        return True
    if ls == COL_SIDE_RIGHT and rs == COL_SIDE_LEFT:
        # Swapped form: `Expr.right("Y") == Expr.left("X")`.
        left_on.append(rhs.col_ref_name())
        right_on.append(lhs.col_ref_name())
        return True
    return False


# =============================================================================
# Residual rewriting: strip side qualifiers to plain col-refs
# =============================================================================


def _rewrite_strip_sides(expr: Expr, left_cols: List[String]) -> Expr:
    """Deep-copy `expr` rewriting every side-qualified EXPR_COL_REF to a
    plain (COL_SIDE_NONE) col-ref over the joined-row schema.

    Left-qualified refs keep their name. Right-qualified refs keep their
    name unless it collides with a left-input column name, in which case
    the `<name>_right` form is used (matching `LogicalPlan.join`'s
    schema-builder collision-rename). COL_SIDE_NONE col-refs pass through
    unchanged. Variants with Expr children are walked recursively; the
    childless ones in the final arm are deep-copied as-is.
    """
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        var side = expr.col_ref_side()
        if side == COL_SIDE_LEFT:
            return Expr.col_ref(name)
        if side == COL_SIDE_RIGHT:
            for i in range(len(left_cols)):
                if left_cols[i] == name:
                    return Expr.col_ref(name + "_right")
            return Expr.col_ref(name)
        # COL_SIDE_NONE — already plain.
        return Expr.col_ref(name)
    elif expr.tag == EXPR_BINARY_OP:
        return Expr.binary(
            expr.binary_op(),
            _rewrite_strip_sides(expr.binary_left_ref(), left_cols),
            _rewrite_strip_sides(expr.binary_right_ref(), left_cols),
        )
    elif expr.tag == EXPR_UNARY_OP:
        return Expr.unary(
            expr.unary_op(),
            _rewrite_strip_sides(expr.unary_child_ref(), left_cols),
        )
    elif expr.tag == EXPR_CAST:
        return Expr.cast(
            _rewrite_strip_sides(expr.cast_child_ref(), left_cols),
            expr.cast_target(),
        )
    elif expr.tag == EXPR_ALIAS:
        return Expr.alias(
            _rewrite_strip_sides(expr.alias_child_ref(), left_cols),
            expr.alias_name(),
        )
    elif expr.tag == EXPR_STRING_OP:
        return Expr.string_op(
            expr.string_op_type(),
            _rewrite_strip_sides(expr.string_op_child_ref(), left_cols),
            expr.string_op_pattern(),
        )
    elif expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        var new_cases = List[WhenCaseData]()
        for i in range(len(wd.cases)):
            new_cases.append(WhenCaseData(
                _rewrite_strip_sides(wd.cases[i].condition[], left_cols),
                _rewrite_strip_sides(wd.cases[i].result[], left_cols),
            ))
        return Expr.when(
            new_cases^, _rewrite_strip_sides(wd.default[], left_cols),
        )
    elif expr.tag == EXPR_IN_LIST:
        ref il = expr._in_list.value()
        var vals = List[ScalarValue]()
        for i in range(len(il.values)):
            vals.append(il.values[i].copy())
        return Expr.in_list_node(
            _rewrite_strip_sides(il.child[], left_cols), vals^,
        )
    elif expr.tag == EXPR_AGG_FN:
        return Expr.agg_fn(
            expr.agg_fn_op(),
            _rewrite_strip_sides(expr.agg_fn_child_ref(), left_cols),
        )
    else:
        # EXPR_LITERAL, EXPR_COL_IDX, EXPR_WINDOW_FN, EXPR_CORRELATED_SUBQUERY,
        # EXPR_BETWEEN, EXPR_SORT_KEY — no side-qualified col-refs to rewrite
        # (a correlated subquery in a join residual would be a frontend bug;
        # flatten_dependent_joins is designed to run before this pass).
        # Deep-copy as-is.
        return expr.copy()


# =============================================================================
# Detection: does the residual still carry side qualifiers?
# =============================================================================


def _residual_needs_decompose(expr: Expr) -> Bool:
    """True if `expr` contains any side-qualified (COL_SIDE_LEFT /
    COL_SIDE_RIGHT) EXPR_COL_REF — i.e. it is a raw, un-decomposed
    `predicate=` expression rather than an already-rewritten residual."""
    if expr.tag == EXPR_COL_REF:
        return expr.col_ref_side() != COL_SIDE_NONE
    elif expr.tag == EXPR_BINARY_OP:
        return (
            _residual_needs_decompose(expr.binary_left_ref())
            or _residual_needs_decompose(expr.binary_right_ref())
        )
    elif expr.tag == EXPR_UNARY_OP:
        return _residual_needs_decompose(expr.unary_child_ref())
    elif expr.tag == EXPR_CAST:
        return _residual_needs_decompose(expr.cast_child_ref())
    elif expr.tag == EXPR_ALIAS:
        return _residual_needs_decompose(expr.alias_child_ref())
    elif expr.tag == EXPR_STRING_OP:
        return _residual_needs_decompose(expr.string_op_child_ref())
    elif expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        for i in range(len(wd.cases)):
            if _residual_needs_decompose(wd.cases[i].condition[]):
                return True
            if _residual_needs_decompose(wd.cases[i].result[]):
                return True
        return _residual_needs_decompose(wd.default[])
    elif expr.tag == EXPR_IN_LIST:
        return _residual_needs_decompose(expr._in_list.value().child[])
    elif expr.tag == EXPR_AGG_FN:
        return _residual_needs_decompose(expr.agg_fn_child_ref())
    else:
        return False
