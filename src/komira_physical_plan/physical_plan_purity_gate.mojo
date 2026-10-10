# =============================================================================
# physical_plan_purity_gate — THE REFUSAL that keeps a LOGICAL plan out of the
# PHYSICAL one, written to run beside the IR version door.
# =============================================================================
#
# A prerequisite for running the optimizer as a separately built library
# across an ABI seam.
#
# ── WHAT IT REFUSES ──────────────────────────────────────────────────────────
# The optimizer/engine contract: *"The physical plan is a COMPLETE,
# SELF-CONTAINED IR … It contains no logical plans and no optimizer
# callbacks."* `SegmentDescPod`
# satisfies that BY TYPE for every field it declares — and reaches a whole
# `LogicalPlan` anyway, through five hops each of which is a field declaration:
#
#     CutResult.segments : List[SegmentDescPod]                 segment_cutter.mojo
#       -> SegmentDescPod.ops : Slab[MorselOp]                  physical_plan.mojo
#          (and .source_spec : SourceSpecPod)
#       -> MorselOp.filter_predicate / .project_exprs / .probe_residual
#          (and SourceSpecPod.parquet_filter)     : Optional[Expr] / ExprArray
#       -> Expr._corr_subq : Optional[OwnedPointer[CorrelatedSubqueryData]]
#       -> CorrelatedSubqueryData._plan : ErasedBox (a LogicalPlan)
#
# (`segment_cutter` and its `CutResult` are not in this tree; the other four
# hops are, in komira_physical_plan, komira_plan_expr and komira_plan_ir.)
#
# `Expr` is allowed in the physical plan — correctly, `Expr` IS inert data —
# so a structural inert-IR check by type is GREEN over a type that
# transitively owns a plan tree, scan leaves included. `Expr`'s correlated-
# subquery arm is *"THE ONE CROSS-EDGE FROM THE EXPRESSION TREE BACK INTO THE
# PLAN TREE"* (`corr_subquery.corr_data_inner_plan_ref`'s own docstring).
#
# ⛔ SO THE PHYSICAL PLAN IS LOGICAL-PLAN-FREE BY A **DYNAMIC INVARIANT**, NEVER
# BY TYPE. Optimizer pass-1 `flatten_dependent_joins` (komira_optimizer) is
# contracted to leave zero `EXPR_CORRELATED_SUBQUERY` nodes behind. No evaluator
# in this tree runs that tag: `komira_kernels.expr_interpreter.interpret_expr`
# returns NULL for it. In ONE binary the pass's own tests hold it to that
# contract. Across an `@extern` seam nothing does: a plan minted by a
# `komira_optimizer.so` whose flatten pass differed — or ran in a different
# order, or was skipped for a shape the newer optimizer decorrelates later —
# carries the subtree over SILENTLY, and the engine on the far side has
# nothing that would notice.
#
# An unchecked ABI cannot carry a dynamic invariant. It can carry a REFUSAL.
# That is this file.
#
# ⚠ WHY NOT REUSE THE WALKER THAT ALREADY EXISTS. `flatten_dependent_joins.
# _expr_contains_correlated_subquery` answers the same question and **FAILS
# OPEN**: it descends every `EXPR_WHEN` arm (each case's condition and result,
# and the default), but its own comment concedes it does not descend
# `EXPR_WINDOW_FN` or "the remaining tags", and among those it returns False
# for `EXPR_REGEXP`, `EXPR_SUBSTRING`, `EXPR_EXTRACT`, `EXPR_MATH_FN*`,
# `EXPR_MAP_GET`, `EXPR_JSON_EXTRACT` and both `STRUCT_FIELD` arms without
# looking inside them. A node it misses is neither lowered nor refused:
# `flatten_dependent_joins` returns a plan that still holds it, and the pass's
# own invariant check (`_plan_contains_correlated_subquery`) uses the same
# walker and misses it too. For a safety check that miss is the whole failure.
# It also lives in `komira_optimizer`, which depends on komira_plan_ir; this
# package does not depend on it and cannot call it.
#
# ⇒ this walker is EXHAUSTIVE over all `EXPR_TAG_COUNT` tags and **RAISES** on a
# tag it does not model, exactly as `scan_binding_gate.mojo` does one gate
# over. An unmodelled tag is a HOLE IN A SAFETY CHECK, not a cosmetic gap, and
# the falsifier (`komira_physical_plan/tests/test_physical_plan_purity_gate.mojo`)
# instantiates every tag id in `[0, EXPR_TAG_COUNT)` and requires an arm for
# each — so a new tag cannot be added without this file going red.
#
# ── WHAT IT DOES *NOT* COVER, STATED RATHER THAN IMPLIED ──────────────────────
# `CutResult.payloads` (`SegParamPayload.dim_subplans: List[LogicalPlan]` and
# `.breaker_plan: Optional[LogicalPlan]`) are OUT OF SCOPE HERE, on purpose.
# Those are clause-#2 debt that is VISIBLE IN THE TYPE — a reader of
# `SegParamPayload` can see a `LogicalPlan` and a boundary that carries one
# cannot pretend otherwise. (`CutResult` and `SegParamPayload` belong to the
# segment cutter and are not in this tree.) This gate exists for the edge
# that crosses SILENTLY — the one nothing in the type system, and no reader,
# can see.
#
# ── COST ─────────────────────────────────────────────────────────────────────
# It is written to run on every cut of every query, as the version door is. It
# is a tag-dispatched walk over the expressions the segments already hold; it
# allocates nothing on the passing path, and every message is built only on the
# failing path.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    expr_tag_name,
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BETWEEN,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_IDX,
    EXPR_COL_REF,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_EXTRACT,
    EXPR_IN_LIST,
    EXPR_JSON_EXTRACT,
    EXPR_LITERAL,
    EXPR_MAP_GET,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_REGEXP,
    EXPR_SORT_KEY,
    EXPR_STRING_OP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    EXPR_WINDOW_FN,
)
from komira_physical_plan.physical_plan import SegmentDescPod


# -----------------------------------------------------------------------------
# The refusal names. Every one of them is what an operator will `git grep` for,
# so they are declared once here and never re-spelled at a raise site.
# -----------------------------------------------------------------------------

comptime PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN: StaticString = (
    "PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN"
)

comptime PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG: StaticString = (
    "PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG"
)

comptime PHYSICAL_PLAN_PURITY_UNCHECKABLE: StaticString = (
    "PHYSICAL_PLAN_PURITY_UNCHECKABLE"
)

# The four expression SITES a `SegmentDescPod` reaches, named so a refusal says
# WHERE. Passed as an argument from the one call site that knows it — never
# SELECTED by a ladder inside a function, which is the shape measured to bind
# two parallel constant arrays independently and cross them in a shared library.
comptime SITE_SOURCE_PARQUET_FILTER: StaticString = "source_spec.parquet_filter"
comptime SITE_OP_FILTER_PREDICATE: StaticString = "ops[i].filter_predicate"
comptime SITE_OP_PROJECT_EXPRS: StaticString = "ops[i].project_exprs"
comptime SITE_OP_PROBE_RESIDUAL: StaticString = "ops[i].probe_residual"


# =============================================================================
# The EXPRESSION half — exhaustive over every `EXPR_*` tag.
# =============================================================================


def expr_carries_correlated_subquery(expr: Expr) raises -> Bool:
    """True iff `expr` or any subtree of it is — or carries the payload of — an
    `EXPR_CORRELATED_SUBQUERY`, i.e. transitively owns a `LogicalPlan`.

    Every one of the `EXPR_TAG_COUNT` tags has an arm. A tag with no arm RAISES
    `PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG` rather than returning False:
    returning False for a shape this walk cannot descend is precisely the
    fail-open behaviour that makes
    `flatten_dependent_joins._expr_contains_correlated_subquery` unusable as a
    safety check, and a gate that answers "no" about a subtree it never looked
    at is worse than no gate — its caller sees success.

    ⚠ THE PAYLOAD IS CHECKED ON EVERY NODE, NOT ONLY ON TAG 14. `_corr_subq` is
    a field like any other; a pass that rewrites `tag` and forgets to clear the
    payload leaves a node that still OWNS a `LogicalPlan` while reading as an
    ordinary binary op. Checking the field costs one load per node and closes
    the case where the tag and the payload disagree — which is exactly the case
    an inspection of the tag alone is blind to.
    """
    # THE PAYLOAD, on every node. See the docstring: tag and payload can
    # disagree, and the payload is what owns the plan.
    if expr._corr_subq:
        return True

    var tag = expr.tag

    # ---- THE CROSS-EDGE ----------------------------------------------------
    # Refused ON THE TAG even when the payload is absent. A tag-14 node with no
    # payload owns no plan today, but it is a malformed cross-edge node, and
    # no evaluator in this tree runs tag 14 (`interpret_expr` in komira_kernels
    # returns NULL for it); a purity gate that admitted it would pass it on.
    if tag == EXPR_CORRELATED_SUBQUERY:
        return True

    # ---- GENUINE LEAVES ----------------------------------------------------
    if tag == EXPR_COL_REF or tag == EXPR_COL_IDX or tag == EXPR_LITERAL:
        # A name, an index, a scalar. No child `Expr`, no plan.
        return False
    if tag == EXPR_WINDOW_FN:
        # `WindowFnData` carries column NAMES (`arg_col` / `partition_by` /
        # `order_by`), an op code and a frame — not child `Expr` values.
        # ⚠ THE FAIL-OPEN WALKER HAS NO ARM FOR THIS TAG. It reaches the same
        # answer; the difference is that this one is a STATED fact about
        # `WindowFnData`'s fields rather than a fallthrough.
        return False
    if tag == EXPR_BETWEEN or tag == EXPR_SORT_KEY:
        # Tags 10 / 11 are DECLARED in `expr.mojo` with no payload field and no
        # factory: nothing in the tree builds one. Enumerated rather than left
        # to the raise, so that if a payload is ever added the arm is here to
        # extend rather than a hole to discover.
        return False

    # ---- ONE CHILD ---------------------------------------------------------
    if tag == EXPR_UNARY_OP:
        if not expr._unary:
            return False
        return expr_carries_correlated_subquery(expr.unary_child_ref())
    if tag == EXPR_CAST:
        if not expr._cast:
            return False
        return expr_carries_correlated_subquery(expr.cast_child_ref())
    if tag == EXPR_ALIAS:
        if not expr._alias:
            return False
        return expr_carries_correlated_subquery(expr.alias_child_ref())
    if tag == EXPR_STRING_OP:
        if not expr._string_op:
            return False
        return expr_carries_correlated_subquery(expr.string_op_child_ref())
    if tag == EXPR_IN_LIST:
        # The VALUES are `ScalarValue` literals; only the child is an `Expr`.
        if not expr._in_list:
            return False
        return expr_carries_correlated_subquery(expr.in_list_child_ref())
    if tag == EXPR_AGG_FN:
        if not expr._agg_fn:
            return False
        return expr_carries_correlated_subquery(expr.agg_fn_child_ref())
    if tag == EXPR_REGEXP:
        if not expr._regexp:
            return False
        return expr_carries_correlated_subquery(expr.regexp_child_ref())
    if tag == EXPR_STRUCT_FIELD:
        if not expr._struct_field:
            return False
        return expr_carries_correlated_subquery(expr.struct_field_parent_ref())
    if tag == EXPR_STRUCT_FIELD_IDX:
        if not expr._struct_field_idx:
            return False
        return expr_carries_correlated_subquery(
            expr.struct_field_idx_parent_ref()
        )
    if tag == EXPR_JSON_EXTRACT:
        if not expr._json_extract:
            return False
        return expr_carries_correlated_subquery(expr.json_extract_parent_ref())
    if tag == EXPR_EXTRACT:
        if not expr._extract:
            return False
        return expr_carries_correlated_subquery(expr.extract_child_ref())
    if tag == EXPR_MATH_FN:
        if not expr._math_fn:
            return False
        return expr_carries_correlated_subquery(expr.math_fn_child_ref())
    if tag == EXPR_SUBSTRING:
        if not expr._substring:
            return False
        return expr_carries_correlated_subquery(expr.substring_child_ref())
    if tag == EXPR_STRING_FN:
        if not expr._string_fn:
            return False
        return expr_carries_correlated_subquery(expr.string_fn_child_ref())
    if tag == EXPR_STRING_FN_N:
        # N children, every one an ordinary
        # expression. A correlated subquery hiding in `concat(a, (SELECT ...))`
        # must be found here or the purity gate lets a `SegmentDescPod` own a
        # `LogicalPlan`. The LOOP is the arm — a fixed-arity read would miss
        # every argument past the second.
        if not expr._string_fn_n:
            return False
        for i in range(expr.string_fn_n_num_args()):
            if expr_carries_correlated_subquery(expr.string_fn_n_arg_ref(i)):
                return True
        return False
    if tag == EXPR_UDF_CALL:
        # One child, the UDF's argument. A correlated
        # subquery hiding inside `affine((SELECT ...))` must be found here or
        # the purity gate lets a `SegmentDescPod` own a `LogicalPlan`.
        if not expr._udf_call:
            return False
        return expr_carries_correlated_subquery(expr.udf_call_child_ref())

    # ---- TWO CHILDREN ------------------------------------------------------
    if tag == EXPR_BINARY_OP:
        if not expr._binary:
            return False
        if expr_carries_correlated_subquery(expr.binary_left_ref()):
            return True
        return expr_carries_correlated_subquery(expr.binary_right_ref())
    if tag == EXPR_MATH_FN2:
        if not expr._math_fn2:
            return False
        if expr_carries_correlated_subquery(expr.math_fn2_left_ref()):
            return True
        return expr_carries_correlated_subquery(expr.math_fn2_right_ref())
    if tag == EXPR_MAP_GET:
        # BOTH sides: a Map key is itself an `Expr`.
        if not expr._map_get:
            return False
        if expr_carries_correlated_subquery(expr.map_get_parent_ref()):
            return True
        return expr_carries_correlated_subquery(expr.map_get_key_ref())

    # ---- N CHILDREN --------------------------------------------------------
    if tag == EXPR_WHEN:
        # Unlike EXPR_WINDOW_FN this one is NOT a leaf: `WhenData` holds a
        # condition AND a result per case plus a default, every one of them an
        # `Expr`. A `CASE WHEN EXISTS (...) THEN …` predicate is invisible to a
        # walk that stops here. The fail-open walker descends all three slots
        # too.
        if not expr._when:
            return False
        for i in range(expr.when_num_cases()):
            if expr_carries_correlated_subquery(
                expr.when_case_condition_ref(i)
            ):
                return True
            if expr_carries_correlated_subquery(expr.when_case_result_ref(i)):
                return True
        return expr_carries_correlated_subquery(expr.when_default_ref())

    raise Error(
        PHYSICAL_PLAN_PURITY_UNMODELLED_EXPR_TAG,
        ": the physical-plan purity walk has no arm for expression tag ",
        Int(tag),
        " (",
        expr_tag_name(tag),
        "). An expression tag with no arm here is a HOLE IN A SAFETY CHECK,",
        " not a cosmetic gap: EXPR_CORRELATED_SUBQUERY proves an expression",
        " can own a whole LogicalPlan, so a subquery underneath an unmodelled",
        " tag would cross the optimizer/engine .so boundary with the gate",
        " reporting success. Add the arm in",
        " komira_physical_plan/physical_plan_purity_gate.mojo — descend its child",
        " expressions, or return False with a comment saying why that tag",
        " cannot carry a plan.",
    )


# =============================================================================
# The SEGMENT half — the four expression sites a `SegmentDescPod` reaches.
# =============================================================================


def _refuse(
    seg_id: Int,
    list_index: Int,
    op_index: Int,
    site: StaticString,
) raises:
    """Build and raise the refusal. Separated from the walk so the message —
    which is real string construction — exists only on the failing path, the
    same discipline the version door states for itself."""
    raise Error(
        PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN,
        ": segment seg_id=",
        seg_id,
        " (list index ",
        list_index,
        ", op index ",
        op_index,
        ") carries an EXPR_CORRELATED_SUBQUERY at ",
        site,
        ", so this PHYSICAL plan transitively owns a LOGICAL plan",
        " (Expr._corr_subq -> CorrelatedSubqueryData._plan).",
        " That violates the optimizer/engine contract clause #2 -- the",
        " physical plan is a COMPLETE, SELF-CONTAINED IR and contains no",
        " logical plans. It should not happen: optimizer pass-1",
        " flatten_dependent_joins (komira_optimizer) is contracted to leave",
        " zero EXPR_CORRELATED_SUBQUERY nodes behind, and no evaluator runs",
        " one (interpret_expr returns NULL for it). Reaching HERE means that",
        " pass did not run, ran in the wrong order, declined a shape it used",
        " to decorrelate, or missed a node under a tag its own walker does",
        " not descend -- or that",
        " the plan was minted by a komira_optimizer.so whose flatten pass",
        " differs from this binary's. Do NOT silence this by deleting the",
        " check: across the .so seam the subtree crosses SILENTLY and the",
        " engine on the far side has nothing that would notice.",
    )


def assert_physical_plan_carries_no_logical_plan(
    imm segments: List[SegmentDescPod],
) raises -> Int:
    """Verify no emitted `SegmentDescPod` transitively owns a `LogicalPlan`.
    Returns the number of EXPRESSION SITES inspected. Raises
    `PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN` on the first offender, naming the
    segment, the op and the site.

    Written to be called ONCE per cut at the plan-entry chokepoint
    (`segment_cutter.cut_and_admit`), beside the IR version door. That cutter
    is not in this tree, and nothing here calls this function except its test.
    It takes the whole segment list for the same reason the door does: one call
    site is the shape that does not get partially deleted later.

    ⚠ IT RETURNS A COUNT, AND THE COUNT IS THE POINT. "Checked, found nothing"
    and "walked into a shape it could not descend and checked nothing" are
    indistinguishable from a bare `raises`-or-not, and this repo has shipped
    several gates that were the second while reading as the first. A caller —
    and the falsifier — can assert the walk actually looked at something.

    ⚠ AN EMPTY PLAN IS NOT CHECKABLE AND IS NOT A PASS, for the version door's
    reason: a gate returning OK over zero segments is indistinguishable from a
    gate nobody called. It raises `PHYSICAL_PLAN_PURITY_UNCHECKABLE`. This
    duplicates the version door's zero-segment refusal DELIBERATELY — a gate
    whose non-vacuity depends on a SIBLING gate still being called first is a
    gate that goes vacuous the day that sibling moves.

    THE FOUR SITES, enumerated because they are the whole coverage claim:
      * `source_spec.parquet_filter`   — the pushed decode filter
      * `ops[i].filter_predicate`      — OP_FILTER
      * `ops[i].project_exprs`         — OP_PROJECT (an ExprArray, all of it)
      * `ops[i].probe_residual`        — OP_JOIN_PROBE's non-equi residual
    These are EVERY `Expr`-typed field reachable from `SegmentDescPod`; a
    field added to `physical_plan.mojo` must be added here.
    """
    if len(segments) == 0:
        raise Error(
            PHYSICAL_PLAN_PURITY_UNCHECKABLE,
            ": asked to verify that a plan with ZERO segments carries no",
            " logical plan. Nothing was inspected, so this is a REFUSAL, not a",
            " pass -- a gate that returns OK over an empty list is",
            " indistinguishable from a gate that was never called. An empty",
            " plan reaching here means its producer emitted no segments.",
        )

    var sites = 0
    for i in range(len(segments)):
        ref seg = segments[i]

        # --- the SOURCE's pushed decode filter -------------------------------
        if seg.source_spec.parquet_filter:
            sites += 1
            if expr_carries_correlated_subquery(
                seg.source_spec.parquet_filter.value()
            ):
                _refuse(seg.seg_id, i, -1, SITE_SOURCE_PARQUET_FILTER)

        # --- every streaming op's expressions --------------------------------
        # ⚠ EVERY OP, NOT ONLY THE ONE ITS TAG SELECTS. The fields are declared
        # on `MorselOp` unconditionally; reading `filter_predicate` only when
        # `tag == OP_FILTER` would let a stale payload on a retagged op carry a
        # plan past the gate, which is the same tag-vs-payload disagreement the
        # expression walk checks for at every node.
        for k in range(len(seg.ops)):
            ref op = seg.ops[k]
            if op.filter_predicate:
                sites += 1
                if expr_carries_correlated_subquery(
                    op.filter_predicate.value()
                ):
                    _refuse(seg.seg_id, i, k, SITE_OP_FILTER_PREDICATE)
            if op.project_exprs:
                ref exprs = op.project_exprs.value()
                for e in range(len(exprs)):
                    sites += 1
                    if expr_carries_correlated_subquery(exprs[e]):
                        _refuse(seg.seg_id, i, k, SITE_OP_PROJECT_EXPRS)
            if op.probe_residual:
                sites += 1
                if expr_carries_correlated_subquery(op.probe_residual.value()):
                    _refuse(seg.seg_id, i, k, SITE_OP_PROBE_RESIDUAL)

    return sites
