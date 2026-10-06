# =============================================================================
# Plan Validator -- catch errors in LogicalPlan before execution
# =============================================================================
#
# Walks the plan tree bottom-up and validates:
#   - Column references exist in the schema
#   - Types are compatible for operations
#   - Join keys exist on both sides
#   - Aggregate expressions reference valid columns
#   - Filter predicates produce boolean output
#
# Errors include plan context: which node, which expression, available
# columns. This catches typos and type mismatches BEFORE execution.
#
# Design reference: Section 5.4 of compiler_pipeline_design.md
# =============================================================================

from komira_arrow.schema import Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_EXTRACT,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR,
    UN_NOT, UN_IS_NULL, UN_IS_NOT_NULL,
)
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
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
    PLAN_CAST_TO_VARCHAR,
)


# =============================================================================
# The report -- what the walk DID and DID NOT check
# =============================================================================
#
# WHY THIS EXISTS (a review, FINDING 3). `_validate_expr_columns`
# had arms for 7 of the 24 `EXPR_*` tags and fell off the end of its if-chain
# for the other 17. A bad column reference inside a CASE / IN-list / regexp /
# substring / math fn / struct-field / window fn was therefore NOT caught, and
# `validate_plan` returned success anyway. Silence read as "valid".
#
# The walk now descends into every variant that carries a child expression. For
# the residual few that carry NO resolvable name in THIS schema (a correlated
# subquery's inner plan, the two declared-but-payload-less tags, and any tag
# added after this file was last touched) the walk records a NOT-VALIDATED note
# instead of passing quietly. "I did not check this" and "I checked this and it
# is fine" are different answers and this type is what keeps them different.


struct PlanValidationReport(Movable):
    """The non-error half of a validation run: the sites the walk could not
    check. An EMPTY report means the whole tree was checked."""

    var unvalidated: List[String]
    """One human-readable note per expression site the walk declined to check.
    Each names the tag and the plan context so a developer can tell WHICH part
    of their query was not covered."""

    def __init__(out self):
        self.unvalidated = List[String]()

    def copy(self) -> Self:
        var out = Self()
        for i in range(len(self.unvalidated)):
            out.unvalidated.append(self.unvalidated[i])
        return out^

    def note_unvalidated(mut self, note: String):
        """Record a site the walk could not check."""
        self.unvalidated.append(note)

    @always_inline
    def num_unvalidated(self) -> Int:
        return len(self.unvalidated)

    @always_inline
    def fully_validated(self) -> Bool:
        """True iff every expression site in the tree was actually checked."""
        return len(self.unvalidated) == 0

    def note(self, i: Int) -> String:
        return self.unvalidated[i]

    def summary(self) -> String:
        """One line naming what was NOT checked (empty string when nothing was
        skipped, so a caller can print it unconditionally)."""
        if len(self.unvalidated) == 0:
            return String("")
        var s = String(
            "NOT VALIDATED ("
            + String(len(self.unvalidated))
            + " expression site(s) the validator does not model): "
        )
        for i in range(len(self.unvalidated)):
            if i > 0:
                s += "; "
            s += self.unvalidated[i]
        return s^


# =============================================================================
# Public API
# =============================================================================

def validate_plan(plan: LogicalPlan) raises:
    """Walk the plan tree and validate correctness.

    Validates:
    - Column references exist in the schema at each plan level
    - Types are compatible for operations
    - Join keys exist on both sides
    - Aggregate expressions are valid
    - Filter predicates are valid expressions

    ⚠ THIS ENTRY DISCARDS THE NOT-VALIDATED REPORT. Returning normally from
    here means "no violation was FOUND", NOT "the whole plan was checked" — a
    correlated-subquery operand (and any expression tag added after this file
    was last extended) is skipped, and this signature has nowhere to say so.
    Callers that need to distinguish those two answers — the dev gate in
    `plan_validation_gate.mojo` is one — must call `validate_plan_report`.

    Args:
        plan: The LogicalPlan to validate.

    Raises:
        Error with descriptive message if validation fails.

    Examples:
        ```mojo
        from komira_sdk import validate_plan, col
        from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET, ExprArray
        var scan = LogicalPlan.scan("data.parquet", SOURCE_PARQUET, schema^)
        var exprs = ExprArray()
        exprs.append(Expr.col_ref("id"))
        var projected = LogicalPlan.project(exprs^, scan^)
        validate_plan(projected)     # raises if a column ref is unknown
        ```
    (LIFT tests/sdk/test_sdk_logical_plan.mojo:440-447).
    """
    var report = validate_plan_report(plan)
    _ = report^


def validate_plan_report(plan: LogicalPlan) raises -> PlanValidationReport:
    """`validate_plan`, but returning what it could NOT check.

    Raises on a genuine violation exactly as `validate_plan` does. Returns a
    `PlanValidationReport` whose `unvalidated` list is EMPTY iff every
    expression site in the tree was actually resolved against a schema.

    Args:
        plan: The LogicalPlan to validate.

    Returns:
        The report of sites the walk declined to check.

    Raises:
        Error with descriptive message if validation fails.
    """
    # Enforce the universal RANGE root invariant ONCE, at the
    # true root (this public entry), BEFORE the recursive per-node walk. Kept out
    # of the recursive `_validate_plan_node` so a nested Limit is never itself
    # treated as the "root".
    assert_offset_limit_is_root(plan)
    var report = PlanValidationReport()
    _validate_plan_node(plan, report)
    return report^


def _validate_plan_node(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Recursive per-node validation (the body of `validate_plan`, minus the
    root-only RANGE invariant)."""
    if plan.tag == PLAN_SCAN:
        _validate_scan(plan, report)
    elif plan.tag == PLAN_FILTER:
        _validate_filter(plan, report)
    elif plan.tag == PLAN_PROJECT:
        _validate_project(plan, report)
    elif plan.tag == PLAN_AGGREGATE:
        _validate_aggregate(plan, report)
    elif plan.tag == PLAN_JOIN:
        _validate_join(plan, report)
    elif plan.tag == PLAN_SORT:
        _validate_sort(plan, report)
    elif plan.tag == PLAN_LIMIT:
        _validate_limit(plan, report)
    elif plan.tag == PLAN_DISTINCT:
        _validate_distinct(plan, report)
    elif plan.tag == PLAN_TOPN:
        _validate_topn(plan, report)
    elif plan.tag == PLAN_PARTITION_BY:
        _validate_partition_by(plan, report)
    elif plan.tag == PLAN_PARTITION_TOPN:
        _validate_partition_topn(plan, report)
    else:
        raise Error("validate_plan: unknown plan tag " + String(Int(plan.tag)))


def _subtree_has_offset_limit(plan: LogicalPlan) -> Bool:
    """True iff any PLAN_LIMIT in this subtree carries a slice offset (offset >
    0). Complete over EVERY child-bearing node tag so the RANGE root invariant
    cannot be evaded by nesting the slice under any operator (filter / project /
    agg / sort / join / asof / union / cast / partition / another limit).
    SCAN / VIEW_REF / CSE_REF are leaves / opaque references (terminal)."""
    if plan.tag == PLAN_LIMIT:
        if plan._limit.value()[].offset > 0:
            return True
        return _subtree_has_offset_limit(plan._limit.value()[].child[])
    elif plan.tag == PLAN_FILTER:
        return _subtree_has_offset_limit(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _subtree_has_offset_limit(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return _subtree_has_offset_limit(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        return (
            _subtree_has_offset_limit(plan._join.value()[].left[])
            or _subtree_has_offset_limit(plan._join.value()[].right[])
        )
    elif plan.tag == PLAN_SORT:
        return _subtree_has_offset_limit(plan._sort.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _subtree_has_offset_limit(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _subtree_has_offset_limit(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        return _subtree_has_offset_limit(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        return _subtree_has_offset_limit(plan._partition_topn.value()[].child[])
    elif plan.tag == PLAN_ASOF_JOIN:
        return (
            _subtree_has_offset_limit(plan._asof_join.value()[].left[])
            or _subtree_has_offset_limit(plan._asof_join.value()[].right[])
        )
    elif plan.tag == PLAN_UNION:
        var n = plan._union.value()[].num_children()
        for i in range(n):
            if _subtree_has_offset_limit(plan._union.value()[].children[i][]):
                return True
        return False
    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        return _subtree_has_offset_limit(plan._cast_to_varchar.value()[].child[])
    return False


def assert_offset_limit_is_root(plan: LogicalPlan) raises:
    """Universal RANGE invariant: a PLAN_LIMIT carrying a slice
    offset (offset > 0) MUST be the plan ROOT.

    The offset is honored ONLY by the root-absorption skip-count at the
    materialize sink; a NON-root offset would be silently dropped by the column
    lowering / write / run paths (the silent-wrong-window class the PE review
    flagged). This is the fail-closed backstop, called at every executor entry.
    offset == 0 limits are unrestricted (plain LIMIT). A root offset is allowed
    provided its child subtree is offset-free."""
    if plan.tag == PLAN_LIMIT and plan._limit.value()[].offset > 0:
        if _subtree_has_offset_limit(plan._limit.value()[].child[]):
            raise Error(
                "RANGE invariant: a slice/range offset (offset > 0) must be the"
                " plan ROOT, but a second offset LIMIT was found below the root."
                " `slice`/`range` is a terminal viewport verb — apply it LAST."
            )
    elif _subtree_has_offset_limit(plan):
        raise Error(
            "RANGE invariant: a slice/range offset (offset > 0) must be the plan"
            " ROOT, but an offset LIMIT is nested below another operator (an op"
            " was chained after `slice`/`range`). `slice`/`range` is a terminal"
            " viewport verb — apply it LAST, or materialize the window first."
        )


def plan_contains_range_offset(plan: LogicalPlan) -> Bool:
    """Public predicate: True iff any PLAN_LIMIT in the tree carries a slice
    offset (offset > 0). Used by the write/run path to fail closed — the
    streaming write cannot honor a row-window skip in this milestone."""
    return _subtree_has_offset_limit(plan)


# =============================================================================
# Internal: per-node validation
# =============================================================================

def _validate_scan(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Scan node.

    Checks:
    - If projection is specified and schema is available, all column names exist.
    - If filter is specified, all column references in the filter exist in the output schema.
    """
    # Validate filter expression column references against output schema
    if plan.scan_data_ref().filter:
        _validate_expr_columns(
            plan.scan_data_ref().filter.value(),
            plan.output_schema,
            "Scan filter",
            report,
        )


def _validate_filter(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Filter node.

    Checks:
    - Child is valid (recursive).
    - Predicate column references exist in child schema.
    """
    # Validate child first (bottom-up)
    _validate_plan_node(plan.filter_data_ref().child[], report)

    # Validate predicate expression references against child output schema
    _validate_expr_columns(
        plan.filter_data_ref().predicate,
        plan.filter_data_ref().child[].output_schema,
        "Filter predicate",
        report,
    )


def _validate_project(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Project node.

    Checks:
    - Child is valid (recursive).
    - All expression column references exist in child schema.
    """
    _validate_plan_node(plan.project_data_ref().child[], report)

    for i in range(len(plan.project_data_ref().exprs)):
        _validate_expr_columns(
            plan.project_data_ref().exprs[i],
            plan.project_data_ref().child[].output_schema,
            "Project expression " + String(i),
            report,
        )


def _validate_aggregate(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate an Aggregate node.

    Checks:
    - Child is valid (recursive).
    - Group-by expression column references exist in child schema.
    - Aggregate expression column references exist in child schema.
    """
    _validate_plan_node(plan.aggregate_data_ref().child[], report)

    # Validate group-by expressions
    for i in range(len(plan.aggregate_data_ref().group_by)):
        _validate_expr_columns(
            plan.aggregate_data_ref().group_by[i],
            plan.aggregate_data_ref().child[].output_schema,
            "Aggregate group_by " + String(i),
            report,
        )

    # Validate aggregate expressions.
    #
    # ⚠ ALL FOUR SLOTS. `AggExpr` carries `child`, `child1`, `child2`, `child3`
    # (multi-arg aggregates: CORR, COVAR, UDAFs — see `agg_expr.mojo`), and this
    # loop read only slot 0. A bad column reference in the SECOND argument of a
    # bivariate aggregate was neither RAISED nor NOTED — the exact "I did not
    # check, reported as I checked and it is fine" that rule 3 of
    # `_validate_expr_columns` exists to forbid, one field over. Found
    # alongside the scan-binding walk's subquery hole: same class of
    # defect (a container the walk never opens), different walk.
    #
    # Enumerated by field rather than by `num_children()`, which STOPS at the
    # first empty slot and therefore cannot enumerate a sparse payload.
    for i in range(len(plan.aggregate_data_ref().agg_exprs)):
        ref ae = plan.aggregate_data_ref().agg_exprs[i]
        if ae.child:
            _validate_expr_columns(
                ae.child.value(),
                plan.aggregate_data_ref().child[].output_schema,
                "Aggregate agg_expr " + String(i),
                report,
            )
        if ae.child1:
            _validate_expr_columns(
                ae.child1.value(),
                plan.aggregate_data_ref().child[].output_schema,
                "Aggregate agg_expr " + String(i) + " arg 1",
                report,
            )
        if ae.child2:
            _validate_expr_columns(
                ae.child2.value(),
                plan.aggregate_data_ref().child[].output_schema,
                "Aggregate agg_expr " + String(i) + " arg 2",
                report,
            )
        if ae.child3:
            _validate_expr_columns(
                ae.child3.value(),
                plan.aggregate_data_ref().child[].output_schema,
                "Aggregate agg_expr " + String(i) + " arg 3",
                report,
            )


def _validate_join(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Join node.

    Checks:
    - Both children are valid (recursive).
    - left_on keys exist in left child schema.
    - right_on keys exist in right child schema.
    - left_on and right_on have the same length.
    """
    _validate_plan_node(plan.join_data_ref().left[], report)
    _validate_plan_node(plan.join_data_ref().right[], report)

    # Check key count match
    if len(plan.join_data_ref().left_on) != len(plan.join_data_ref().right_on):
        raise Error(
            "Join validation: left_on has "
            + String(len(plan.join_data_ref().left_on))
            + " keys but right_on has "
            + String(len(plan.join_data_ref().right_on))
            + " keys. They must match."
        )

    # Check left keys exist in left schema
    for key in plan.join_data_ref().left_on:
        var found = False
        for i in range(plan.join_data_ref().left[].output_schema.num_columns()):
            if plan.join_data_ref().left[].output_schema.field_name(i) == key:
                found = True
                break
        if not found:
            raise Error(
                "Join validation: left key '"
                + key
                + "' not found in left schema. Available: "
                + _schema_column_names(plan.join_data_ref().left[].output_schema)
            )

    # Check right keys exist in right schema
    for key in plan.join_data_ref().right_on:
        var found = False
        for i in range(plan.join_data_ref().right[].output_schema.num_columns()):
            if plan.join_data_ref().right[].output_schema.field_name(i) == key:
                found = True
                break
        if not found:
            raise Error(
                "Join validation: right key '"
                + key
                + "' not found in right schema. Available: "
                + _schema_column_names(plan.join_data_ref().right[].output_schema)
            )

    # ⚠ THE RESIDUAL — an expression site this walk NEVER OPENED (found
    # in review). `JoinData.residual` carries the non-equi part of a
    # `predicate=` join, and nothing here looked at it: not a raise, not a note.
    # That is the same class of defect as `scan_binding_gate`'s subquery hole —
    # a container the walk does not know exists — and it is worse here than a
    # missed column, because a residual can hold an `EXPR_CORRELATED_SUBQUERY`
    # and therefore a whole `LogicalPlan`.
    #
    # It is NOTED rather than resolved, deliberately. A residual's col-refs are
    # SIDE-QUALIFIED (`Expr.left("x")` / `Expr.right("x")`, COL_SIDE_LEFT /
    # COL_SIDE_RIGHT) until `join_predicate_decompose` rewrites them, so
    # resolving them against any single schema here would report valid plans as
    # broken — and a dev gate that cries wolf gets turned off. Rule 3 of
    # `_validate_expr_columns` is exactly the answer for that case: say "I did
    # not check this", never stay silent.
    if plan.join_data_ref().residual:
        report.note_unvalidated(
            "Join residual: the predicate residual carries SIDE-QUALIFIED"
            " column references (COL_SIDE_LEFT / COL_SIDE_RIGHT) until"
            " `join_predicate_decompose` rewrites them, so they cannot be"
            " resolved against either child's schema from here -- nothing in"
            " this expression was checked, INCLUDING any correlated subquery"
            " and therefore any plan nested inside it"
        )


def _validate_sort(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Sort node.

    Checks:
    - Child is valid (recursive).
    - Sort key column names exist in child schema.
    - keys and descending lists have same length.
    """
    _validate_plan_node(plan.sort_data_ref().child[], report)

    if len(plan.sort_data_ref().keys) != len(plan.sort_data_ref().descending):
        raise Error(
            "Sort validation: keys has "
            + String(len(plan.sort_data_ref().keys))
            + " entries but descending has "
            + String(len(plan.sort_data_ref().descending))
            + ". They must match."
        )

    for key in plan.sort_data_ref().keys:
        var found = False
        for i in range(plan.sort_data_ref().child[].output_schema.num_columns()):
            if plan.sort_data_ref().child[].output_schema.field_name(i) == key:
                found = True
                break
        if not found:
            raise Error(
                "Sort validation: sort key '"
                + key
                + "' not found in schema. Available: "
                + _schema_column_names(plan.sort_data_ref().child[].output_schema)
            )


def _validate_limit(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Limit node.

    Checks:
    - Child is valid (recursive).
    - n >= 0.
    - offset >= 0 (the RANGE primitive). The root-ness of a positive
      offset is enforced separately, once, by `assert_offset_limit_is_root` at
      the public `validate_plan` entry (and at every executor entry).
    """
    _validate_plan_node(plan.limit_data_ref().child[], report)

    if plan.limit_data_ref().n < 0:
        raise Error(
            "Limit validation: n must be >= 0, got "
            + String(plan.limit_data_ref().n)
        )

    if plan.limit_data_ref().offset < 0:
        raise Error(
            "Limit validation: offset must be >= 0, got "
            + String(plan.limit_data_ref().offset)
        )


def _validate_distinct(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a Distinct node.

    Checks:
    - Child is valid (recursive).
    - If columns specified, they exist in child schema.
    """
    _validate_plan_node(plan.distinct_data_ref().child[], report)

    if plan.distinct_data_ref().columns:
        var cols = plan.distinct_data_ref().columns.value().copy()
        for c in cols:
            var found = False
            for i in range(plan.distinct_data_ref().child[].output_schema.num_columns()):
                if plan.distinct_data_ref().child[].output_schema.field_name(i) == c:
                    found = True
                    break
            if not found:
                raise Error(
                    "Distinct validation: column '"
                    + c
                    + "' not found in schema. Available: "
                    + _schema_column_names(plan.distinct_data_ref().child[].output_schema)
                )


def _validate_topn(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a TopN node.

    Checks:
    - Child is valid (recursive).
    - n >= 0.
    - Sort key column names exist in child schema.
    - keys and descending lists have same length.
    """
    _validate_plan_node(plan.topn_data_ref().child[], report)

    if plan.topn_data_ref().n < 0:
        raise Error(
            "TopN validation: n must be >= 0, got "
            + String(plan.topn_data_ref().n)
        )

    if len(plan.topn_data_ref().keys) != len(plan.topn_data_ref().descending):
        raise Error(
            "TopN validation: keys has "
            + String(len(plan.topn_data_ref().keys))
            + " entries but descending has "
            + String(len(plan.topn_data_ref().descending))
            + ". They must match."
        )

    for key in plan.topn_data_ref().keys:
        var found = False
        for i in range(plan.topn_data_ref().child[].output_schema.num_columns()):
            if plan.topn_data_ref().child[].output_schema.field_name(i) == key:
                found = True
                break
        if not found:
            raise Error(
                "TopN validation: sort key '"
                + key
                + "' not found in schema. Available: "
                + _schema_column_names(plan.topn_data_ref().child[].output_schema)
            )


def _validate_partition_by(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a PartitionBy node.

    Checks:
    - Child is valid (recursive).
    - Partition keys + order keys exist in child schema.
    - descending has same length as order_keys.
    - Each partition expression's column (if any) exists in child schema.
    """
    _validate_plan_node(plan.partition_by_data_ref().child[], report)

    ref child_schema = plan.partition_by_data_ref().child[].output_schema

    for k in plan.partition_by_data_ref().partition_keys:
        var found = False
        for i in range(child_schema.num_columns()):
            if child_schema.field_name(i) == k:
                found = True
                break
        if not found:
            raise Error(
                "PartitionBy validation: partition key '"
                + k
                + "' not found. Available: "
                + _schema_column_names(child_schema)
            )

    if len(plan.partition_by_data_ref().order_keys) != len(plan.partition_by_data_ref().descending):
        raise Error(
            "PartitionBy validation: order_keys and descending have mismatched lengths"
        )

    for k in plan.partition_by_data_ref().order_keys:
        var found = False
        for i in range(child_schema.num_columns()):
            if child_schema.field_name(i) == k:
                found = True
                break
        if not found:
            raise Error(
                "PartitionBy validation: order key '"
                + k
                + "' not found. Available: "
                + _schema_column_names(child_schema)
            )

    for i in range(len(plan.partition_by_data_ref().partition_exprs)):
        var col = plan.partition_by_data_ref().partition_exprs[i].column
        if col.byte_length() == 0:
            continue
        var found = False
        for j in range(child_schema.num_columns()):
            if child_schema.field_name(j) == col:
                found = True
                break
        if not found:
            raise Error(
                "PartitionBy validation: expression column '"
                + col
                + "' not found. Available: "
                + _schema_column_names(child_schema)
            )


def _validate_partition_topn(plan: LogicalPlan, mut report: PlanValidationReport) raises:
    """Validate a PartitionTopN node.

    Checks:
    - Child is valid (recursive).
    - k >= 0.
    - Partition keys + sort keys exist in child schema.
    - sort_keys and descending lists have same length.
    """
    _validate_plan_node(plan.partition_topn_data_ref().child[], report)

    if plan.partition_topn_data_ref().k < 0:
        raise Error(
            "PartitionTopN validation: k must be >= 0, got "
            + String(plan.partition_topn_data_ref().k)
        )

    if len(plan.partition_topn_data_ref().sort_keys) != len(
        plan.partition_topn_data_ref().descending
    ):
        raise Error(
            "PartitionTopN validation: sort_keys has "
            + String(len(plan.partition_topn_data_ref().sort_keys))
            + " entries but descending has "
            + String(len(plan.partition_topn_data_ref().descending))
            + ". They must match."
        )

    ref child_schema = plan.partition_topn_data_ref().child[].output_schema

    for k in plan.partition_topn_data_ref().partition_keys:
        var found = False
        for i in range(child_schema.num_columns()):
            if child_schema.field_name(i) == k:
                found = True
                break
        if not found:
            raise Error(
                "PartitionTopN validation: partition key '"
                + k
                + "' not found in schema. Available: "
                + _schema_column_names(child_schema)
            )

    for k in plan.partition_topn_data_ref().sort_keys:
        var found = False
        for i in range(child_schema.num_columns()):
            if child_schema.field_name(i) == k:
                found = True
                break
        if not found:
            raise Error(
                "PartitionTopN validation: sort key '"
                + k
                + "' not found in schema. Available: "
                + _schema_column_names(child_schema)
            )


# =============================================================================
# Expression validation helpers
# =============================================================================

def _assert_column_exists(
    name: String, schema: Schema, context: String
) raises:
    """The one place a column NAME is resolved against a schema. Every arm of
    `_validate_expr_columns` that carries a name funnels here so the error text
    (the name + the "Available: [...]" list) is identical wherever it comes
    from."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return
    raise Error(
        context
        + ": column '"
        + name
        + "' not found. Available: "
        + _schema_column_names(schema)
    )


def _validate_expr_columns(
    expr: Expr,
    schema: Schema,
    context: String,
    mut report: PlanValidationReport,
) raises:
    """Validate that every column NAME an expression references exists in
    `schema`. Raises with context on the first one that does not.

    ⚠ EVERY `EXPR_*` TAG MUST HAVE AN ARM (a review, FINDING 3).
    This chain used to model 7 of the 24 tags and fall off the end for the rest,
    which meant a bad reference inside a CASE / IN-list / regexp / substring /
    math fn / struct-field / window fn was reported as VALID. Three rules keep
    that from coming back:

      1. A tag whose payload carries a child `Expr` RECURSES.
      2. A tag whose payload carries a column NAME (the window function's
         `arg_col` / `partition_by` / `order_by`) resolves it, exactly as a Sort
         key is resolved.
      3. A tag this walk genuinely cannot resolve against THIS schema records a
         NOT-VALIDATED note on `report`. It never returns quietly — "I did not
         check" must not be reported as "I checked and it is fine".

    The terminal `else` covers rule 3 for any tag added after this file was last
    touched, so a NEW expression variant degrades to "not validated" rather than
    to a silent pass.

    Args:
        expr: The expression to validate.
        schema: The schema to check column references against.
        context: Human-readable context for error messages.
        report: Accumulates the sites this walk could not check.
    """
    # ---- 1. The name-carrying leaf. -----------------------------------------
    if expr.tag == EXPR_COL_REF:
        _assert_column_exists(expr.col_ref_name(), schema, context)

    # ---- 2. No name, no children. -------------------------------------------
    elif expr.tag == EXPR_LITERAL:
        pass

    elif expr.tag == EXPR_COL_IDX:
        # A POSITIONAL reference: it carries no NAME, so a by-name resolver has
        # nothing to resolve. Deliberately NOT bounds-checked here — the index's
        # frame of reference depends on the node (a join side's schema vs the
        # combined one vs a post-project schema), so a bounds check at this
        # level would false-positive, and a dev gate that cries wolf gets turned
        # off. Positional-index validation belongs on the node, not the expr.
        pass

    # ---- 3. One child. -------------------------------------------------------
    elif expr.tag == EXPR_UNARY_OP:
        _validate_expr_columns(expr.unary_child_ref(), schema, context, report)

    elif expr.tag == EXPR_CAST:
        _validate_expr_columns(expr.cast_child_ref(), schema, context, report)

    elif expr.tag == EXPR_ALIAS:
        _validate_expr_columns(expr.alias_child_ref(), schema, context, report)

    elif expr.tag == EXPR_STRING_OP:
        _validate_expr_columns(
            expr.string_op_child_ref(), schema, context, report
        )

    elif expr.tag == EXPR_REGEXP:
        _validate_expr_columns(expr.regexp_child_ref(), schema, context, report)

    elif expr.tag == EXPR_SUBSTRING:
        _validate_expr_columns(
            expr.substring_child_ref(), schema, context, report
        )

    elif expr.tag == EXPR_STRING_FN:
        _validate_expr_columns(
            expr.string_fn_child_ref(), schema, context, report
        )

    elif expr.tag == EXPR_STRING_FN_N:
        # (2026-09-03): validate EVERY argument. Missing this
        # arm reports a bad column reference as VALID.
        for i in range(expr.string_fn_n_num_args()):
            _validate_expr_columns(
                expr.string_fn_n_arg_ref(i), schema, context, report
            )

    elif expr.tag == EXPR_UDF_CALL:
        # (2026-09-02): validate the UDF's ARGUMENT against the child
        # schema. Missing this arm reports a bad column reference as VALID.
        _validate_expr_columns(
            expr.udf_call_child_ref(), schema, context, report
        )

    elif expr.tag == EXPR_EXTRACT:
        _validate_expr_columns(expr.extract_child_ref(), schema, context, report)

    elif expr.tag == EXPR_MATH_FN:
        _validate_expr_columns(expr.math_fn_child_ref(), schema, context, report)

    elif expr.tag == EXPR_IN_LIST:
        # The VALUES are `ScalarValue` literals -- no column names in them.
        _validate_expr_columns(expr.in_list_child_ref(), schema, context, report)

    elif expr.tag == EXPR_AGG_FN:
        _validate_expr_columns(expr.agg_fn_child_ref(), schema, context, report)

    elif expr.tag == EXPR_STRUCT_FIELD:
        # The FIELD name is resolved against the parent's STRUCT type, not
        # against `schema`; the parent expression is what this walk owns.
        _validate_expr_columns(
            expr.struct_field_parent_ref(), schema, context, report
        )

    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        _validate_expr_columns(
            expr.struct_field_idx_parent_ref(), schema, context, report
        )

    elif expr.tag == EXPR_JSON_EXTRACT:
        _validate_expr_columns(
            expr.json_extract_parent_ref(), schema, context, report
        )

    # ---- 4. Two children. ----------------------------------------------------
    elif expr.tag == EXPR_BINARY_OP:
        _validate_expr_columns(expr.binary_left_ref(), schema, context, report)
        _validate_expr_columns(expr.binary_right_ref(), schema, context, report)

    elif expr.tag == EXPR_MATH_FN2:
        _validate_expr_columns(expr.math_fn2_left_ref(), schema, context, report)
        _validate_expr_columns(
            expr.math_fn2_right_ref(), schema, context, report
        )

    elif expr.tag == EXPR_MAP_GET:
        # BOTH sides: the key is itself an Expr and may be `col("which_key")`.
        _validate_expr_columns(
            expr.map_get_parent_ref(), schema, context, report
        )
        _validate_expr_columns(expr.map_get_key_ref(), schema, context, report)

    # ---- 5. N children. ------------------------------------------------------
    elif expr.tag == EXPR_WHEN:
        for i in range(expr.when_num_cases()):
            _validate_expr_columns(
                expr.when_case_condition_ref(i), schema, context, report
            )
            _validate_expr_columns(
                expr.when_case_result_ref(i), schema, context, report
            )
        _validate_expr_columns(expr.when_default_ref(), schema, context, report)

    # ---- 6. Names on the payload rather than in a child Expr. ----------------
    elif expr.tag == EXPR_WINDOW_FN:
        # `arg_col` / `partition_by` / `order_by` are column NAMES carried on
        # the expression, so they are exactly as resolvable as a Sort key.
        ref wf = expr.window_fn_data_ref()
        if wf.arg_col.byte_length() > 0:
            _assert_column_exists(wf.arg_col, schema, context + " (window arg)")
        for i in range(len(wf.partition_by)):
            _assert_column_exists(
                wf.partition_by[i], schema, context + " (window PARTITION BY)"
            )
        for i in range(len(wf.order_by)):
            _assert_column_exists(
                wf.order_by[i], schema, context + " (window ORDER BY)"
            )

    # ---- 7. NOT VALIDATED -- recorded, never silent. -------------------------
    elif expr.tag == EXPR_CORRELATED_SUBQUERY:
        # The operand is an inner `LogicalPlan` with its OWN schema plus a list
        # of OUTER references that by definition do not resolve against this
        # node's schema. Validating it needs the correlation context the
        # decorrelation pass builds, which does not exist at this entry.
        #
        # ⚠ THIS IS THE SAME BLIND SPOT `scan_binding_gate` SHIPPED WITH, AND
        # THE ONLY REASON IT IS NOT THE SAME DEFECT IS THIS NOTE. Tag 14 carries
        # `CorrelatedSubqueryData.inner_plan: OwnedPointer[LogicalPlan]` — the
        # one cross-edge from the expression tree back into the plan tree — so
        # NOTHING inside the subquery is validated: not its scans, not its
        # nodes, not the tags `_first_unmodeled_plan_tag` would otherwise refuse
        # to walk (it does not descend here either, so a subquery over a UNION
        # reports the whole plan as fully modelled). The epoch gate had the same
        # non-descent and NO note, which made it a silent no-op; it now
        # descends. This walk declines instead, for a stated reason, and SAYS SO
        # — which is the difference between a documented limit and a hole.
        report.note_unvalidated(
            context
            + ": EXPR_CORRELATED_SUBQUERY (tag 14) -- the inner plan and its"
            " outer references are not resolvable against this node's schema"
            " before decorrelation, so nothing in this operand was checked,"
            " INCLUDING every plan node and scan inside the subquery"
        )

    elif expr.tag == EXPR_BETWEEN or expr.tag == EXPR_SORT_KEY:
        # Declared in `expr.mojo` (tags 10 / 11) with NO payload field and no
        # factory: nothing in the tree builds one today. If one ever appears it
        # is unreachable by this walk, so say so rather than pass it.
        report.note_unvalidated(
            context
            + ": expression tag "
            + String(Int(expr.tag))
            + " has no payload field on `Expr`, so its operands cannot be"
            " reached from here -- nothing in this expression was checked"
        )

    else:
        # A tag added after this walk was last extended. It degrades to NOT
        # VALIDATED, never to a silent pass -- that difference is the whole
        # point of this arm.
        report.note_unvalidated(
            context
            + ": expression tag "
            + String(Int(expr.tag))
            + " is not modeled by `_validate_expr_columns` -- nothing inside it"
            " was checked. Add an arm above (recurse into its children, or"
            " resolve the names it carries) rather than deleting this note"
        )


# =============================================================================
# Helpers
# =============================================================================

def _schema_column_names(schema: Schema) -> String:
    """Format available column names for error messages."""
    var result = String("[")
    for i in range(schema.num_columns()):
        if i > 0:
            result += ", "
        result += schema.field_name(i)
    result += "]"
    return result
