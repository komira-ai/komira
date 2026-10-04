# =============================================================================
# scan_binding_gate — the EPOCH CHECK, applied to a whole plan.
# =============================================================================
#
# WHY THIS FILE EXISTS
# --------------------
# `scan_resolver.check_binding` is MECHANISM 2 of the scan-binding ownership
# rule — the one thing standing between "a handle minted by a dead registry"
# and a tcmalloc crash three frames later.
#
# A check with no PRODUCTION CALLER is decorative: a plan carrying a handle
# minted by a dead registry would execute with NO ERROR — not a wild read, not
# a crash, a SILENT NO-OP. This module is that production caller: a registry
# that mints handles without being threaded to execution fails LOUDLY, by
# name, at every execution route.
#
# WHAT THIS MODULE ADDS OVER `check_binding`
# ------------------------------------------
# `check_binding` checks ONE binding. Execution is handed a PLAN. The gap
# between the two is a tree walk, and a tree walk that misses a container is
# exactly how a gate rots into vacuity — so this walker:
#
#   * covers ALL `PLAN_*` tags AND ALL `EXPR_*` tags, enumerated, never
#     `tag <= PLAN_CAST_TO_VARCHAR`;
#   * RAISES on a tag it does not model, rather than returning quietly. An
#     unmodelled tag is a hole in a SAFETY check, and `plan_validation_gate.mojo`
#     documents what the alternative costs: its validator skips unmodelled
#     tags, and a skip must be LOUD or silence reads as success. Here the
#     answer is stronger — there is no skip;
#   * RETURNS THE NUMBER OF SCAN LEAVES IT INSPECTED, so a caller (and a test)
#     can tell "checked, found nothing wrong" apart from "walked into a shape it
#     could not descend and checked nothing". A gate that cannot report zero
#     work cannot be proven non-vacuous.
#
# ⚠ THE QUESTION IS "WHAT CAN CONTAIN A PLAN?", NOT "WHAT ARE THE PLAN TAGS?"
# --------------------------------------------------------------------------
# A walk that enumerates every `PLAN_*` tag and raises on an unmodelled one is
# still a SILENT NO-OP FOR A SCAN INSIDE A SUBQUERY. The question that matters
# is **"WHAT CAN CONTAIN A PLAN?"**, and the answer is not a subset of the plan
# tags:
#
#   1. a plan node's CHILD SLOT   — `FilterData.child`, `JoinData.left/right`,
#      `UnionData.children`, … the obvious shape.
#   2. an EXPRESSION.             — `Expr` tag 14 `EXPR_CORRELATED_SUBQUERY`
#      carries the subquery's `LogicalPlan` (`CorrelatedSubqueryData`).
#      This is the ONLY cross-edge from the expression tree back into the plan
#      tree (verified: it is the only `LogicalPlan`-typed field outside
#      `logical_plan_variants`' child slots), and it is how EXISTS / NOT EXISTS
#      / scalar-subquery / `IN (subquery)` are all spelled. It is reachable from
#      EVERY expression site on EVERY node — a Filter predicate, a Project
#      expression, a group-by key, an aggregate argument, a join residual, and
#      a Scan's own pushed-down filter.
#
# So the walk is MUTUALLY RECURSIVE — plan → expr → plan — and the expr side
# gets the same two properties the plan side has: every tag enumerated, and a
# RAISE (`SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG`) on one that is not. Adding an
# `EXPR_*` tag without an arm here is as loud as adding a `PLAN_*` one.
#
# The two "genuine leaf" answers are stated per tag rather than defaulted,
# because "this tag cannot contain a plan" is a CLAIM and a claim that is made
# by falling off the end of an if-chain is a claim nobody reviewed.
#
# WHERE IT LIVES. `komira_core/plan/`, above `komira_core/source/`: it names
# both `LogicalPlan` (plan layer) and `ScanResolver` (source layer), and the
# source layer must not depend on the plan layer — `scan_binding.mojo`'s header
# states that constraint for the same reason.
#
# COST. One tree walk per PLAN-COMPILE — never per morsel, never per row, never
# per batch. Resolution is once per scan leaf per EXECUTION, on the driver
# thread — so the resolver needs no lock and no atomic. Per binding-backed
# scan leaf the work is one `Int` compare that returns immediately for an
# UNBOUND binding. The expression side adds a walk over expression trees that are already
# walked several times per plan-compile by the optimizer (`_collect_expr_columns`,
# `_expr_fingerprint`, `_validate_expr_columns`), so it is not a new order of
# cost. This is deliberately NOT behind a dev flag: a diagnostic that is off by
# default is the right shape for a diagnostic, but a memory-safety check that
# is off by default is not a check.
# =============================================================================

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
    expr_tag_name,
)
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
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    plan_tag_name,
)
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref
from komira_scan_source.scan_resolver import ScanResolver, check_binding


comptime SCAN_BINDING_GATE_UNMODELLED_TAG: StaticString = (
    "SCAN_BINDING_GATE_UNMODELLED_TAG"
)
"""NAMED ERROR — the walker met a `PLAN_*` tag it has no arm for.

A safety walk that silently returns on an unknown node is a safety walk with a
hole in it, and the hole is invisible: the caller sees success. Raising means a
tag added without an arm here is found by the first test that builds one.
"""


comptime SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG: StaticString = (
    "SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG"
)
"""NAMED ERROR — the walker met an `EXPR_*` tag it has no arm for.

The expression half of the same property, and it is not decoration: the ONE
cross-edge from an expression back into a plan (`EXPR_CORRELATED_SUBQUERY`) is
an expression tag, so an unmodelled expression tag can hide an entire plan
subtree. Distinct from
`SCAN_BINDING_GATE_UNMODELLED_TAG` because the two name different files' tag
spaces and a reader needs to know which one grew.
"""


def check_plan_scan_bindings[
    RES: ScanResolver
](resolver: RES, plan: LogicalPlan) raises -> Int:
    """MECHANISM 2 OF THE OWNERSHIP RULE, applied to a whole plan.

    Walk every node AND every expression it carries; for every SCAN leaf whose
    source is binding-backed, run the epoch check against `resolver`. Returns
    the number of scan leaves inspected — INCLUDING those inside subqueries,
    which is the whole point of the expression half of the walk.

    RAISES:
      * `SCAN_BINDING_EPOCH_MISMATCH` — a handle minted by a registry that is
        gone. This is the use-after-free, converted into a named error at the
        point of the mistake instead of a crash three frames later.
      * `SCAN_BINDING_HANDLE_NOT_BOUND` — the epoch matches but the slot does
        not exist in this registry (an evicted entry).
      * `SCAN_BINDING_GATE_UNMODELLED_TAG` — this walker has no arm for a plan
        tag.
      * `SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG` — no arm for an expression tag.

    An UNBOUND binding is legal and is NOT an error. `check_binding` returns
    immediately for those, which is what makes this walk nearly free while
    still being live for every minted handle.
    """
    var tag = plan.tag

    # ---- LEAVES ------------------------------------------------------------
    if tag == PLAN_SCAN:
        # A PLAN_SCAN with no payload is a corrupt node, and
        # `optimizer_helpers.validate_plan_integrity` is the gate that says so.
        # It is not this gate's finding, so it is not this gate's raise: an
        # absent payload carries no binding, hence nothing to epoch-check.
        if not plan._scan:
            return 0
        ref sd = plan.scan_data_ref()
        var n = 0
        if sd.source.is_binding_backed():
            check_binding(resolver, sd.source.binding_ref())
            n = 1
        elif sd.source.has_carrier_binding():
            # ⚠ THE PREDICATE ABOVE IS TAG-KEYED, AND A HANDLE IS NOT.
            # `is_binding_backed()` asks "has this arm's PAYLOAD moved into
            # `_binding`", which is false for `SOURCE_VARIANT_IN_MEMORY`. Keyed
            # on it ALONE, this gate would be STRUCTURALLY BLIND to an
            # in-memory node stamped with a handle from a registry that no longer
            # exists: it would walk through here, return "clean", and reach the
            # executor.
            #
            # The question this gate has to ask is "IS THERE A HANDLE HERE",
            # never "which arm is this". `has_carrier_binding()` is that
            # question for the in-memory arm; the two arms merge
            # when `SourceVariant._in_memory` is deleted and this branch goes
            # away with it.
            check_binding(resolver, sd.source.carrier_binding_ref())
            n = 1
        # else: an arm holding a concrete source with no
        # handle. Nothing for mechanism 2 to check — and counting it would
        # overstate this gate's coverage.
        #
        # A SCAN IS NOT A LEAF FOR THIS WALK. `ScanData.filter` is a
        # pushed-down predicate and is an `Expr` like any other, so it can carry
        # a subquery. Descending it is what makes "leaf" a statement about the
        # PLAN tree rather than about this function.
        if sd.filter:
            n += check_expr_scan_bindings(resolver, sd.filter.value())
        return n

    if tag == PLAN_VIEW_REF or tag == PLAN_CSE_REF:
        # Genuine leaves: an unresolved reference whose subtree is not spliced
        # in yet (VIEW_REF, until `view_resolution_pass` runs) or is spliced in
        # ELSEWHERE in this same plan (CSE_REF, which names the canonical
        # occurrence by hash). Either way there is no child here to descend, and
        # the canonical CSE occurrence is walked where it actually lives — so
        # skipping here loses no coverage and double-walking would be wrong.
        # Neither payload (`ViewRefData` / `CseRefData`) carries an `Expr`:
        # both are (name-or-hash, output_schema).
        return 0

    # ---- SINGLE-CHILD, WITH EXPRESSIONS ------------------------------------
    if tag == PLAN_FILTER:
        if not plan._filter:
            return 0
        ref f = plan.filter_data_ref()
        var n = check_expr_scan_bindings(resolver, f.predicate)
        return n + check_plan_scan_bindings(resolver, f.child[])
    if tag == PLAN_PROJECT:
        if not plan._project:
            return 0
        ref p = plan.project_data_ref()
        var n = 0
        for i in range(len(p.exprs)):
            n += check_expr_scan_bindings(resolver, p.exprs[i])
        return n + check_plan_scan_bindings(resolver, p.child[])
    if tag == PLAN_AGGREGATE:
        if not plan._aggregate:
            return 0
        ref a = plan.aggregate_data_ref()
        var n = 0
        for i in range(len(a.group_by)):
            n += check_expr_scan_bindings(resolver, a.group_by[i])
        for i in range(len(a.agg_exprs)):
            # ALL FOUR slots, not `num_children()` — that accessor STOPS at the
            # first empty slot, so a sparsely-populated AggExpr would hide the
            # later ones. A walk must not inherit a counter's short-circuit.
            ref ae = a.agg_exprs[i]
            if ae.child:
                n += check_expr_scan_bindings(resolver, ae.child.value())
            if ae.child1:
                n += check_expr_scan_bindings(resolver, ae.child1.value())
            if ae.child2:
                n += check_expr_scan_bindings(resolver, ae.child2.value())
            if ae.child3:
                n += check_expr_scan_bindings(resolver, ae.child3.value())
        return n + check_plan_scan_bindings(resolver, a.child[])

    # ---- SINGLE-CHILD, NO EXPRESSIONS --------------------------------------
    # Each of these carries column NAMES (`List[String]`) rather than `Expr`
    # values, so there is no expression site to descend. Stated rather than
    # assumed: `PartitionByData.partition_exprs` is a `List[PartitionExpr]`, and
    # `PartitionExpr` is (func, column, offset, default, frame, alias) — every
    # field a scalar or a name, no nested `Expr`, hence no subquery.
    if tag == PLAN_SORT:
        if not plan._sort:
            return 0
        return check_plan_scan_bindings(resolver, plan.sort_data_ref().child[])
    if tag == PLAN_LIMIT:
        if not plan._limit:
            return 0
        return check_plan_scan_bindings(resolver, plan.limit_data_ref().child[])
    if tag == PLAN_DISTINCT:
        if not plan._distinct:
            return 0
        return check_plan_scan_bindings(
            resolver, plan.distinct_data_ref().child[]
        )
    if tag == PLAN_TOPN:
        if not plan._topn:
            return 0
        return check_plan_scan_bindings(resolver, plan.topn_data_ref().child[])
    if tag == PLAN_PARTITION_BY:
        if not plan._partition_by:
            return 0
        return check_plan_scan_bindings(
            resolver, plan.partition_by_data_ref().child[]
        )
    if tag == PLAN_PARTITION_TOPN:
        if not plan._partition_topn:
            return 0
        return check_plan_scan_bindings(
            resolver, plan.partition_topn_data_ref().child[]
        )
    if tag == PLAN_CAST_TO_VARCHAR:
        if not plan._cast_to_varchar:
            return 0
        return check_plan_scan_bindings(
            resolver, plan.cast_to_varchar_data_ref().child[]
        )

    # ---- TWO-CHILD ---------------------------------------------------------
    # BOTH sides, always. A join whose RIGHT side carries the stale handle is
    # the shape a left-only walk would miss, and it is not exotic: an in-memory
    # source is overwhelmingly a join's build side.
    if tag == PLAN_JOIN:
        if not plan._join:
            return 0
        ref j = plan.join_data_ref()
        var n = check_plan_scan_bindings(resolver, j.left[])
        n += check_plan_scan_bindings(resolver, j.right[])
        # THE RESIDUAL is a non-equi predicate `Expr` the decompose pass leaves
        # on the node. It is an expression site like any other, and
        # `plan_validator._validate_join` not walking it is the same class of
        # hole one gate over.
        if j.residual:
            n += check_expr_scan_bindings(resolver, j.residual.value()[])
        return n
    if tag == PLAN_ASOF_JOIN:
        if not plan._asof_join:
            return 0
        ref a = plan.asof_join_data_ref()
        # `AsofJoinData` carries key NAMES and a tolerance, no `Expr`.
        var n = check_plan_scan_bindings(resolver, a.left[])
        return n + check_plan_scan_bindings(resolver, a.right[])

    # ---- N-CHILD -----------------------------------------------------------
    if tag == PLAN_UNION:
        if not plan._union:
            return 0
        ref u = plan.union_data_ref()
        var n = 0
        for i in range(u.num_children()):
            n += check_plan_scan_bindings(resolver, u.children[i][])
        return n

    raise Error(
        String(SCAN_BINDING_GATE_UNMODELLED_TAG)
        + String(": the scan-binding epoch walk has no arm for plan tag ")
        + String(Int(tag))
        + String(" (")
        + plan_tag_name(tag)
        + String("). A tag with no arm here is a HOLE IN A SAFETY CHECK, not a")
        + String(" cosmetic gap: a scan leaf underneath it would never be")
        + String(" epoch-checked and the caller would see success. Add the arm")
        + String(" in scan_binding_gate.mojo — descend its children AND every")
        + String(" Expr it carries, or return 0 with a comment saying why it")
        + String(" is a genuine leaf.")
    )


def check_expr_scan_bindings[
    RES: ScanResolver
](resolver: RES, expr: Expr) raises -> Int:
    """The EXPRESSION half of the walk. Returns scan leaves inspected.

    An expression is not a leaf of the plan tree. `EXPR_CORRELATED_SUBQUERY`
    carries a whole `LogicalPlan` (`CorrelatedSubqueryData.inner_plan`), which
    is how EXISTS / NOT EXISTS / scalar subquery / `IN (subquery)` are spelled,
    and a plan-node-only walk cannot see any of them. That would be a SILENT
    NO-OP — the same defect `check_plan_scan_bindings` raises on unmodelled
    tags to prevent, one level down.

    Every `EXPR_*` tag has an arm. A tag with no arm RAISES
    `SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG`, for exactly the reason the plan
    half raises: an unmodelled expression tag can hide a whole plan subtree.
    """
    var tag = expr.tag

    # ---- THE CROSS-EDGE: an expression that contains a PLAN ----------------
    if tag == EXPR_CORRELATED_SUBQUERY:
        if not expr._corr_subq:
            return 0
        return check_plan_scan_bindings(
            resolver, corr_subq_inner_plan_ref(expr)
        )

    # ---- GENUINE LEAVES ----------------------------------------------------
    if tag == EXPR_COL_REF or tag == EXPR_COL_IDX or tag == EXPR_LITERAL:
        # A name, an index, a scalar. No child `Expr`, no plan.
        return 0
    if tag == EXPR_WINDOW_FN:
        # `WindowFnData` carries column NAMES (`arg_col` / `partition_by` /
        # `order_by`) and an op, not child `Expr` values — the same fact
        # `plan_validator._validate_expr_columns` resolves them as names for.
        return 0
    if tag == EXPR_BETWEEN or tag == EXPR_SORT_KEY:
        # Tags 10 / 11 are DECLARED in `expr.mojo` with no payload field and no
        # factory: nothing in the tree builds one. Enumerated rather than left
        # to the raise, because "reserved, carries nothing" is a fact about
        # these two tags — and if a payload is ever added, the arm is here to
        # extend rather than a hole to discover.
        return 0

    # ---- ONE CHILD ---------------------------------------------------------
    if tag == EXPR_UNARY_OP:
        if not expr._unary:
            return 0
        return check_expr_scan_bindings(resolver, expr.unary_child_ref())
    if tag == EXPR_CAST:
        if not expr._cast:
            return 0
        return check_expr_scan_bindings(resolver, expr.cast_child_ref())
    if tag == EXPR_ALIAS:
        if not expr._alias:
            return 0
        return check_expr_scan_bindings(resolver, expr.alias_child_ref())
    if tag == EXPR_STRING_OP:
        if not expr._string_op:
            return 0
        return check_expr_scan_bindings(resolver, expr.string_op_child_ref())
    if tag == EXPR_IN_LIST:
        # The VALUES are `ScalarValue` literals; only the child is an `Expr`.
        if not expr._in_list:
            return 0
        return check_expr_scan_bindings(resolver, expr.in_list_child_ref())
    if tag == EXPR_AGG_FN:
        if not expr._agg_fn:
            return 0
        return check_expr_scan_bindings(resolver, expr.agg_fn_child_ref())
    if tag == EXPR_REGEXP:
        if not expr._regexp:
            return 0
        return check_expr_scan_bindings(resolver, expr.regexp_child_ref())
    if tag == EXPR_STRUCT_FIELD:
        if not expr._struct_field:
            return 0
        return check_expr_scan_bindings(
            resolver, expr.struct_field_parent_ref()
        )
    if tag == EXPR_STRUCT_FIELD_IDX:
        if not expr._struct_field_idx:
            return 0
        return check_expr_scan_bindings(
            resolver, expr.struct_field_idx_parent_ref()
        )
    if tag == EXPR_JSON_EXTRACT:
        if not expr._json_extract:
            return 0
        return check_expr_scan_bindings(
            resolver, expr.json_extract_parent_ref()
        )
    if tag == EXPR_EXTRACT:
        if not expr._extract:
            return 0
        return check_expr_scan_bindings(resolver, expr.extract_child_ref())
    if tag == EXPR_MATH_FN:
        if not expr._math_fn:
            return 0
        return check_expr_scan_bindings(resolver, expr.math_fn_child_ref())
    if tag == EXPR_SUBSTRING:
        if not expr._substring:
            return 0
        return check_expr_scan_bindings(resolver, expr.substring_child_ref())
    if tag == EXPR_STRING_FN:
        if not expr._string_fn:
            return 0
        return check_expr_scan_bindings(resolver, expr.string_fn_child_ref())
    if tag == EXPR_STRING_FN_N:
        # N children. A missed arm HIDES a whole
        # `LogicalPlan` from the gate (tag 14 carries one) — this walker's
        # header warns about exactly that, and a variadic node can hide one
        # behind any argument index, not only the first.
        if not expr._string_fn_n:
            return 0
        var sfnn_seen = 0
        for i in range(expr.string_fn_n_num_args()):
            sfnn_seen += check_expr_scan_bindings(
                resolver, expr.string_fn_n_arg_ref(i)
            )
        return sfnn_seen
    if tag == EXPR_UDF_CALL:
        # One child, the UDF's argument. A missed arm
        # here HIDES a whole `LogicalPlan` from the gate (tag 14 carries one),
        # which is what this walker's header warns about.
        if not expr._udf_call:
            return 0
        return check_expr_scan_bindings(resolver, expr.udf_call_child_ref())

    # ---- TWO CHILDREN ------------------------------------------------------
    if tag == EXPR_BINARY_OP:
        if not expr._binary:
            return 0
        var n = check_expr_scan_bindings(resolver, expr.binary_left_ref())
        return n + check_expr_scan_bindings(resolver, expr.binary_right_ref())
    if tag == EXPR_MATH_FN2:
        if not expr._math_fn2:
            return 0
        var n = check_expr_scan_bindings(resolver, expr.math_fn2_left_ref())
        return n + check_expr_scan_bindings(resolver, expr.math_fn2_right_ref())
    if tag == EXPR_MAP_GET:
        # BOTH sides: a Map key is itself an `Expr`.
        if not expr._map_get:
            return 0
        var n = check_expr_scan_bindings(resolver, expr.map_get_parent_ref())
        return n + check_expr_scan_bindings(resolver, expr.map_get_key_ref())

    # ---- N CHILDREN --------------------------------------------------------
    if tag == EXPR_WHEN:
        if not expr._when:
            return 0
        var n = 0
        for i in range(expr.when_num_cases()):
            n += check_expr_scan_bindings(
                resolver, expr.when_case_condition_ref(i)
            )
            n += check_expr_scan_bindings(
                resolver, expr.when_case_result_ref(i)
            )
        return n + check_expr_scan_bindings(resolver, expr.when_default_ref())

    raise Error(
        String(SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG)
        + String(": the scan-binding epoch walk has no arm for expression tag ")
        + String(Int(tag))
        + String(" (")
        + expr_tag_name(tag)
        + String("). An expression tag with no arm here is a HOLE IN A SAFETY")
        + String(" CHECK: EXPR_CORRELATED_SUBQUERY proves an expression can")
        + String(" contain a whole LogicalPlan, so a scan underneath an")
        + String(" unmodelled expression would never be epoch-checked and the")
        + String(" caller would see success. Add the arm in")
        + String(" scan_binding_gate.mojo — descend its child expressions, or")
        + String(" return 0 with a comment saying why it cannot contain a plan.")
    )
