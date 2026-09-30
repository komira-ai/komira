# =============================================================================
# scan_binding_bind_pass — THE ENTRY-TIME BIND. Where binding actually belongs.
# =============================================================================
#
# WHAT THIS IS. A mutating plan walk that, for every IN-MEMORY scan leaf in a
# plan — including one inside a subquery — takes a refcount bump of its payload
# into `registry` and STAMPS the node with the `(handle, epoch)` the registry
# minted. After it, `SourceVariant.has_carrier_binding()` is TRUE for every
# in-memory scan node in the plan, and the handle is valid against THIS
# registry.
#
# =============================================================================
# WHY IT IS A PASS OVER A PLAN AND NOT A LINE IN EACH CONSTRUCTOR
# =============================================================================
#
# A payload-READER that finds no binding breaks the query, so every in-memory
# scan must be bound before it is read. The obvious repair is "bind at
# construction" — if every `InMemorySource` were
# bound the moment it is built, every reader migrates trivially. It does not
# work, and the reason is not effort:
#
#   ⚠ A HANDLE IS ONLY MEANINGFUL AGAINST THE REGISTRY THAT MINTED IT, AND
#     WHICH REGISTRY THAT IS IS CHOSEN AT EXECUTION, NOT AT CONSTRUCTION.
#
# `ScanBinding.registry_epoch` is the whole of mechanism 2: a handle whose
# epoch does not match the executing registry raises `SCAN_BINDING_EPOCH_MISMATCH`
# by name. So a constructor that binds must already know which `EngineContext`
# will execute the plan. It does not, and it structurally cannot:
#
#   * `inmem_source_frame.from_record_batch_typed(mut ctx, batch)`
#     takes a context and DISCARDS IT (`_ = ctx`), with the reason in its own
#     docstring: "the ctx is supplied at materialize, where it is actually
#     needed". That is the SDK's stated contract, not an oversight.
#   * `PlanCarrier.from_record_batch`, `factories.from_record_batch`,
#     `inmem_source.build_inmem_scan_plan(_batches)`, `SqlCatalog.add_in_memory`
#     and `arrow_ipc_typed_source._build_chunked_inmem_scan_plan` take no
#     context at all — they are the ergonomic seeds a user reaches for.
#   * `LogicalPlan.scan` and `optimizer_helpers._rebuild_scan` build in-memory
#     scan nodes from `komira_core`, BELOW the SDK. `EngineContext` is not a
#     name core is allowed to spell.
#   * and the decisive one: the SAME plan can be materialized by TWO different
#     contexts, or by one context and then re-materialized after that context is
#     gone. A construction-time handle is correct for at most one of them.
#     The falsifiers are the PAIR in `test_inmem_entry_binding_widening`:
#     `test_an_unbound_plan_executes_under_either_context` (the property
#     entry-time binding keeps) and
#     `test_a_plan_carrying_another_contexts_handle_is_refused_by_name` (what a
#     construction-time handle costs — a raise BY NAME under any other context).
#     Both go RED for a design that binds before the executor is known.
#
# The frame that knows BOTH the plan and the executing registry is the TERMINAL
# EXECUTION ROUTE — which is exactly where mechanism 2 is already wired, for
# exactly the same reason. So this pass runs there, next to the gate.
#
# =============================================================================
# REBIND, NOT BIND-IF-ABSENT
# =============================================================================
#
# A plan clone carries its handle (`InMemorySource.copy()` forwards `binding`,
# deliberately). So a plan that was bound by context A and is later executed by
# context B arrives ALREADY carrying a handle — a handle B's registry never
# minted. Binding only when `has_carrier_binding()` is false would leave it, and
# the gate two lines later would raise `SCAN_BINDING_EPOCH_MISMATCH` on a plan
# that is perfectly serviceable.
#
# So the predicate is "is this handle valid against THIS registry", not "is
# there a handle". A stale one is REPLACED.
#
# ⚠ THAT IS SAFE ONLY WHILE THE UNION ARM STILL HOLDS THE PAYLOAD, and saying so
# is the point. The batches are reachable from the node itself
# (`SourceVariant._in_memory`), so re-binding is always possible and always
# correct — it re-registers bytes we are holding. When `_in_memory` is deleted
# there is nothing to re-bind FROM, `carrier_payload_arc()` stops existing, and
# a stale handle can only be an error. The rebind arm disappears with the arm it
# reads; it is not a permanent weakening of mechanism 2.
#
# ⚠ WHETHER IT LAUNDERS A FOREIGN HANDLE IS A PROPERTY OF THE DOOR, NOT OF THIS
# PASS.
#
# A door that runs the epoch gate BEFORE this pass (`_prepare_plan` /
# `optimize_full` gate at their TOP, and this pass runs after they RETURN)
# refuses a plan carrying another context's handle before this pass ever sees
# it. A door that skips the gate does not: the REBIND arm below would re-stamp
# a foreign handle there and the query would run. That covers doors that are
# not methods on `EngineContext`, such as
#
#   * `inmem_source_frame.materialize_inmem_plan`
#   * `inmem_source_frame.materialize_inmem_agg_plan`
#
# which open `optimize_for_breaker`, which gates nothing — so every such door
# must run the gate itself.
#
# ⚠ THE RISK IS NOT A MISSING CHECK, IT IS A ROUTE-DEPENDENT ANSWER.
# `SCAN_BINDING_EPOCH_MISMATCH` would fire or not depending on which door the
# plan entered, while the ownership tests assert the refusal as though it were
# a property of the plan. A single falsifier cannot show a route-dependent
# property, which is why the coverage is ONE TEST PER ROUTE
# (`test_inmem_terminals_refuse_a_foreign_handle.mojo`).
#
# The order must not be inverted anywhere: inverting it silently deletes the
# refusal. The live case for the rebind is the one a CLOSING `ScanBindScope`
# creates — a handle from THIS registry whose slot has been released — and
# without it a plan that survived one execution would be permanently
# unexecutable by the context that ran it, which would make the release itself
# unshippable. Pinned by
# `test_a_stale_handle_is_replaced_rather_than_kept_by_the_pass`; the ordering
# is pinned by `test_a_plan_carrying_another_contexts_handle_is_refused_by_name`.
#
# =============================================================================
# RETENTION — WHAT THIS ACQUIRES, AND WHO OWES THE RELEASE
# =============================================================================
#
# `bind` takes a SECOND retaining reference to a payload that already has an
# owner. That is precisely the shape that leaks: once `InMemorySource.binding`
# exists, the registry slot is no longer the last owner, and a release that
# drops the bookkeeping keeps the bytes — with `num_bound()` reading the
# correct answer throughout.
#
# So this pass is an ACQUIRE and its caller owes a RELEASE. The pass returns
# nothing that remembers what it bound, on purpose: the caller opens a
# `ScanBindScope` (`EngineContext.open_scan_bind_scope`) before calling, and the
# scope's DESTRUCTOR releases `[watermark, num_slots())` — the same
# range-not-a-list shape, for the same reason (a returned list is a fourth thing
# that has to be kept in step with the binds, and an acquire that forgets to
# append is invisible).
#
# ⚠ IT IS A DESTRUCTOR AND NOT A STATEMENT, AND THE DIFFERENCE IS A LEAK. A
# release written as a statement AFTER the query body is skipped by a raise in
# between, and "the payload is the plan's own, which the raise is unwinding
# anyway" is FALSE for the reason one paragraph up: `bind` took its OWN
# retaining reference, so unwinding the plan does not drop it. MEASURED with
# production APIs only — `ctx.bind_plan_inmem_payloads(plan)` then
# `_ = plan^` — the registry still held 512 rows. Every RAISING query would
# leak its payload for the life of the `EngineContext`, and a long-lived
# service (`komira_viewd_core`) keeps ONE warm context per worker across every
# request: the leak multiplies by QUERY RATE.
#
# ⚠ THE RESIDENCY ASSERTION IS `resident_payload_rows()`, NEVER `num_bound()`.
# A tombstone-only evict takes `num_bound()` to zero while the bytes stay
# resident, so a falsifier written against the count goes GREEN on the broken
# implementation.
#
# =============================================================================
# WHY THE WALK IS A TWIN OF `scan_binding_gate` AND NOT A NEW SHAPE
# =============================================================================
#
# A walk that enumerates every `PLAN_*` tag and raises on an unmodelled one is
# still a SILENT NO-OP FOR A SCAN INSIDE A SUBQUERY, because the question that
# decides coverage is not "what are the plan tags" but "WHAT CAN CONTAIN A
# PLAN" (see `scan_binding_gate`). A bind pass with that hole is
# strictly worse than the gate having it: the gate would merely fail to CHECK a
# subquery leaf, whereas this pass failing to BIND one leaves a node the
# binding readers cannot serve.
#
# So this walk carries the same two properties, tag for tag:
#   * every `PLAN_*` tag has an arm; one without raises
#     `SCAN_BIND_PASS_UNMODELLED_TAG`.
#   * every `EXPR_*` tag has an arm; one without raises
#     `SCAN_BIND_PASS_UNMODELLED_EXPR_TAG`.
# and it is mutually recursive plan -> expr -> plan through
# `EXPR_CORRELATED_SUBQUERY`, the one cross-edge from the expression tree back
# into the plan tree.
#
# The tokens are DISTINCT from the gate's so a reader knows which walk grew a
# hole. Both walks are driven over the full tag spaces by their falsifiers, so a
# new tag turns BOTH red rather than one.
#
# COST. One tree walk per terminal execution route. Per in-memory leaf: one
# `Int` compare (already bound against this registry -> done) or one refcount
# bump plus a `List.append`. It folds NO content bytes — `inmem_scan_binding`
# is called with `fold_content_identity=False`, because its default supplies
# `structural_id = ims.structural_id()`, an O(total batch bytes) fold on the
# driver, measured at 5-11% of driver cycles on join-heavy TPC-H queries. The
# binding this pass produces is a RESOLUTION TOKEN, not an identity, exactly as
# `optimizer_scan_dedup._bind_dedup_batch`'s is.
# =============================================================================

from komira_core.plan.expr import (
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
from komira_core.plan.logical_plan import (
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
from komira_core.plan.corr_subquery import corr_data_inner_plan_ref
from komira_core.source.scan_registry import ScanRegistry
from komira_core.source.source_variant import (
    SOURCE_VARIANT_IN_MEMORY,
    inmem_scan_binding,
)


comptime SCAN_BIND_PASS_UNMODELLED_TAG: StaticString = (
    "SCAN_BIND_PASS_UNMODELLED_TAG"
)
"""NAMED ERROR — the bind walk met a `PLAN_*` tag it has no arm for.

DISTINCT from `SCAN_BINDING_GATE_UNMODELLED_TAG` on purpose. The two walks have
the same tag coverage obligation and are separate code; a reader who sees this
token knows the BIND side grew the hole, which is the side whose hole breaks
queries rather than merely failing to check them.
"""


comptime SCAN_BIND_PASS_UNMODELLED_EXPR_TAG: StaticString = (
    "SCAN_BIND_PASS_UNMODELLED_EXPR_TAG"
)
"""NAMED ERROR — the bind walk met an `EXPR_*` tag it has no arm for.

`EXPR_CORRELATED_SUBQUERY` proves an expression can carry a whole
`LogicalPlan`, so an unmodelled expression tag can hide an entire plan subtree —
every in-memory leaf inside which would go UNBOUND while the caller saw success.
"""


def _bind_one_scan_source(
    registry: ScanRegistry, mut plan: LogicalPlan
) raises -> Int:
    """Bind THIS scan node's in-memory payload if it is not already validly
    bound against `registry`. Returns 1 if a fresh handle was minted, else 0.

    THE PREDICATE IS "IS THIS HANDLE VALID HERE", NOT "IS THERE A HANDLE" — see
    the module header's REBIND section. A binding whose epoch matches this
    registry AND whose slot is still live is left exactly as it is, so a
    re-executed plan does not mint a second slot for the same bytes.
    """
    ref sd = plan._scan.value()[]
    if sd.source.tag != SOURCE_VARIANT_IN_MEMORY:
        return 0
    if sd.source.has_carrier_binding():
        ref b = sd.source.carrier_binding_ref()
        if b.registry_epoch == registry.epoch() and registry.is_bound(
            b.kind_id, b.handle
        ):
            return 0
    # `fold_content_identity=False`: this binding is a RESOLUTION TOKEN, not an
    # identity. The default folds `ims.structural_id()`, an O(total batch bytes)
    # hash, on the driver, once per in-memory leaf per execution — and no value
    # assertion in the tree could see it come back, because the rows are
    # identical either way. See the module header.
    var payload = sd.source.carrier_payload_arc()
    var stamped = registry.bind(
        # THROUGH THE UNION'S OWN ACCESSOR, not `sd.source._in_memory.value()`.
        # Opening the arm here would make this a payload-read site OUTSIDE
        # `source_variant.mojo`. `carrier_scan_binding` is ONE dispatch arm
        # that goes to zero with `SourceVariant`; a read here would be one more
        # site to migrate.
        sd.source.carrier_scan_binding(fold_content_identity=False),
        payload^,
    )
    sd.source.attach_carrier_binding(stamped^)
    return 1


def bind_plan_inmem_payloads(
    registry: ScanRegistry, mut plan: LogicalPlan
) raises -> Int:
    """Bind every in-memory scan leaf in `plan` into `registry` and stamp each
    node with its handle. Returns the number of FRESH handles minted.

    ⚠ `registry` IS BORROWED, NOT `mut`. The bind
    mutates the registry's Arc-held store, not the handle — see the BINDING
    section header in `scan_registry.mojo` for why `mut` would be a false
    signal. It is what lets a WIDENING frame
    (`TypedSource.materialize_into_source`, handed `read scan_registry`) bind
    the inner plan it is about to execute at its own terminal.

    ⚠ THE RETURN IS "MINTED", NOT "IN-MEMORY LEAVES SEEN", and the difference is
    load-bearing for the caller's release: the watermark range
    `[num_slots()-before, num_slots())` is exactly the set this call acquired, so
    a leaf that was already validly bound must NOT be counted (it is somebody
    else's slot to release).

    RAISES `SCAN_BIND_PASS_UNMODELLED_TAG` / `SCAN_BIND_PASS_UNMODELLED_EXPR_TAG`
    for a tag with no arm — a hole in this walk is a node the binding readers
    cannot serve, so it must be loud rather than a quiet zero.
    """
    var tag = plan.tag

    # ---- LEAVES ------------------------------------------------------------
    if tag == PLAN_SCAN:
        # A payload-less PLAN_SCAN is a corrupt node and
        # `validate_plan_integrity` is the gate that says so; it carries no
        # source, hence nothing to bind. Mirrors the epoch gate's arm exactly.
        if not plan._scan:
            return 0
        var n = _bind_one_scan_source(registry, plan)
        # A SCAN IS NOT A LEAF OF THIS WALK. `ScanData.filter` is a pushed-down
        # predicate and is an `Expr` like any other, so it can carry a subquery
        # — which can carry a plan, which can carry an in-memory scan.
        ref sd = plan._scan.value()[]
        if sd.filter:
            n += bind_expr_inmem_payloads(registry, sd.filter.value())
        return n

    if tag == PLAN_VIEW_REF or tag == PLAN_CSE_REF:
        # Genuine leaves: an unresolved reference whose subtree is not spliced
        # in yet (VIEW_REF, until `view_resolution_pass` runs) or is spliced in
        # ELSEWHERE in this same plan (CSE_REF, which names the canonical
        # occurrence by hash and is walked where it actually lives). Neither
        # payload carries an `Expr`. Same answer, same reasons, as the gate's.
        return 0

    # ---- SINGLE-CHILD, WITH EXPRESSIONS ------------------------------------
    if tag == PLAN_FILTER:
        if not plan._filter:
            return 0
        ref f = plan._filter.value()[]
        var n = bind_expr_inmem_payloads(registry, f.predicate)
        return n + bind_plan_inmem_payloads(registry, f.child[])
    if tag == PLAN_PROJECT:
        if not plan._project:
            return 0
        ref p = plan._project.value()[]
        var n = 0
        for i in range(len(p.exprs)):
            n += bind_expr_inmem_payloads(registry, p.exprs[i])
        return n + bind_plan_inmem_payloads(registry, p.child[])
    if tag == PLAN_AGGREGATE:
        if not plan._aggregate:
            return 0
        ref a = plan._aggregate.value()[]
        var n = 0
        for i in range(len(a.group_by)):
            n += bind_expr_inmem_payloads(registry, a.group_by[i])
        for i in range(len(a.agg_exprs)):
            # ALL FOUR slots, not `num_children()` — that accessor STOPS at the
            # first empty slot, so a sparsely-populated AggExpr would hide the
            # later ones. A walk must not inherit a counter's short-circuit.
            ref ae = a.agg_exprs[i]
            if ae.child:
                n += bind_expr_inmem_payloads(registry, ae.child.value())
            if ae.child1:
                n += bind_expr_inmem_payloads(registry, ae.child1.value())
            if ae.child2:
                n += bind_expr_inmem_payloads(registry, ae.child2.value())
            if ae.child3:
                n += bind_expr_inmem_payloads(registry, ae.child3.value())
        return n + bind_plan_inmem_payloads(registry, a.child[])

    # ---- SINGLE-CHILD, NO EXPRESSIONS --------------------------------------
    # Each carries column NAMES (`List[String]`) rather than `Expr` values, so
    # there is no expression site to descend. `PartitionByData.partition_exprs`
    # is a `List[PartitionExpr]` and `PartitionExpr` is (func, column, offset,
    # default, frame, alias) — every field a scalar or a name, no nested `Expr`.
    if tag == PLAN_SORT:
        if not plan._sort:
            return 0
        return bind_plan_inmem_payloads(registry, plan._sort.value()[].child[])
    if tag == PLAN_LIMIT:
        if not plan._limit:
            return 0
        return bind_plan_inmem_payloads(registry, plan._limit.value()[].child[])
    if tag == PLAN_DISTINCT:
        if not plan._distinct:
            return 0
        return bind_plan_inmem_payloads(
            registry, plan._distinct.value()[].child[]
        )
    if tag == PLAN_TOPN:
        if not plan._topn:
            return 0
        return bind_plan_inmem_payloads(registry, plan._topn.value()[].child[])
    if tag == PLAN_PARTITION_BY:
        if not plan._partition_by:
            return 0
        return bind_plan_inmem_payloads(
            registry, plan._partition_by.value()[].child[]
        )
    if tag == PLAN_PARTITION_TOPN:
        if not plan._partition_topn:
            return 0
        return bind_plan_inmem_payloads(
            registry, plan._partition_topn.value()[].child[]
        )
    if tag == PLAN_CAST_TO_VARCHAR:
        if not plan._cast_to_varchar:
            return 0
        return bind_plan_inmem_payloads(
            registry, plan._cast_to_varchar.value()[].child[]
        )

    # ---- TWO-CHILD ---------------------------------------------------------
    # BOTH sides, always. A join whose RIGHT side is the in-memory one is the
    # shape a left-only walk would miss, and it is not exotic: the in-memory arm
    # is overwhelmingly a join's build side.
    if tag == PLAN_JOIN:
        if not plan._join:
            return 0
        ref j = plan._join.value()[]
        var n = bind_plan_inmem_payloads(registry, j.left[])
        n += bind_plan_inmem_payloads(registry, j.right[])
        # THE RESIDUAL is a non-equi predicate `Expr` the decompose pass leaves
        # on the node — an expression site like any other.
        if j.residual:
            n += bind_expr_inmem_payloads(registry, j.residual.value()[])
        return n
    if tag == PLAN_ASOF_JOIN:
        if not plan._asof_join:
            return 0
        ref a = plan._asof_join.value()[]
        # `AsofJoinData` carries key NAMES and a tolerance, no `Expr`.
        var n = bind_plan_inmem_payloads(registry, a.left[])
        return n + bind_plan_inmem_payloads(registry, a.right[])

    # ---- N-CHILD -----------------------------------------------------------
    if tag == PLAN_UNION:
        if not plan._union:
            return 0
        ref u = plan._union.value()[]
        var n = 0
        for i in range(u.num_children()):
            n += bind_plan_inmem_payloads(registry, u.children[i][])
        return n

    raise Error(
        String(SCAN_BIND_PASS_UNMODELLED_TAG)
        + String(": the in-memory bind walk has no arm for plan tag ")
        + String(Int(tag))
        + String(" (")
        + plan_tag_name(tag)
        + String("). A tag with no arm here is worse than a hole in a check:")
        + String(" an in-memory scan underneath it stays UNBOUND, so every")
        + String(" migrated payload-read site declines and the query breaks or")
        + String(" silently takes a legacy arm. Add the arm in")
        + String(" scan_binding_bind_pass.mojo — descend its children AND every")
        + String(" Expr it carries, or return 0 with a comment saying why it")
        + String(" is a genuine leaf.")
    )


def bind_expr_inmem_payloads(
    registry: ScanRegistry, mut expr: Expr
) raises -> Int:
    """The EXPRESSION half of the walk. Returns fresh handles minted.

    An expression is not a leaf of the plan tree: `EXPR_CORRELATED_SUBQUERY`
    carries a whole `LogicalPlan` (`CorrelatedSubqueryData`), which
    is how EXISTS / NOT EXISTS / scalar subquery / `IN (subquery)` are spelled.
    A plan-node-only walk cannot see any of them.

    Every `EXPR_*` tag has an arm; one without raises
    `SCAN_BIND_PASS_UNMODELLED_EXPR_TAG`.
    """
    var tag = expr.tag

    # ---- THE CROSS-EDGE: an expression that contains a PLAN ----------------
    if tag == EXPR_CORRELATED_SUBQUERY:
        if not expr._corr_subq:
            return 0
        ref cs = expr._corr_subq.value()[]
        # The plan is type-erased on
        # the payload so `Expr` need not name it; the accessor RAISES on a
        # tag mismatch instead of dereferencing blind, and it hands back a
        # MUTABLE ref here because this pass binds in place.
        return bind_plan_inmem_payloads(
            registry, corr_data_inner_plan_ref(cs)
        )

    # ---- GENUINE LEAVES ----------------------------------------------------
    if tag == EXPR_COL_REF or tag == EXPR_COL_IDX or tag == EXPR_LITERAL:
        # A name, an index, a scalar. No child `Expr`, no plan.
        return 0
    if tag == EXPR_WINDOW_FN:
        # `WindowFnData` carries column NAMES (`arg_col` / `partition_by` /
        # `order_by`) and an op, not child `Expr` values.
        return 0
    if tag == EXPR_BETWEEN or tag == EXPR_SORT_KEY:
        # Tags 10 / 11 are DECLARED in `expr.mojo` with no payload field and no
        # factory: nothing in the tree builds one. Enumerated rather than left
        # to the raise, so that adding a payload extends an arm instead of
        # discovering a hole.
        return 0

    # ---- ONE CHILD ---------------------------------------------------------
    if tag == EXPR_UNARY_OP:
        if not expr._unary:
            return 0
        return bind_expr_inmem_payloads(registry, expr._unary.value().child[])
    if tag == EXPR_CAST:
        if not expr._cast:
            return 0
        return bind_expr_inmem_payloads(registry, expr._cast.value().child[])
    if tag == EXPR_ALIAS:
        if not expr._alias:
            return 0
        return bind_expr_inmem_payloads(registry, expr._alias.value().child[])
    if tag == EXPR_STRING_OP:
        if not expr._string_op:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._string_op.value().child[]
        )
    if tag == EXPR_IN_LIST:
        # The VALUES are `ScalarValue` literals; only the child is an `Expr`.
        if not expr._in_list:
            return 0
        return bind_expr_inmem_payloads(registry, expr._in_list.value().child[])
    if tag == EXPR_AGG_FN:
        if not expr._agg_fn:
            return 0
        return bind_expr_inmem_payloads(registry, expr._agg_fn.value().child[])
    if tag == EXPR_REGEXP:
        if not expr._regexp:
            return 0
        return bind_expr_inmem_payloads(registry, expr._regexp.value().child[])
    if tag == EXPR_STRUCT_FIELD:
        if not expr._struct_field:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._struct_field.value().parent[]
        )
    if tag == EXPR_STRUCT_FIELD_IDX:
        if not expr._struct_field_idx:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._struct_field_idx.value().parent[]
        )
    if tag == EXPR_JSON_EXTRACT:
        if not expr._json_extract:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._json_extract.value().parent[]
        )
    if tag == EXPR_EXTRACT:
        if not expr._extract:
            return 0
        return bind_expr_inmem_payloads(registry, expr._extract.value().child[])
    if tag == EXPR_MATH_FN:
        if not expr._math_fn:
            return 0
        return bind_expr_inmem_payloads(registry, expr._math_fn.value().child[])
    if tag == EXPR_SUBSTRING:
        if not expr._substring:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._substring.value().child[]
        )
    if tag == EXPR_STRING_FN:
        if not expr._string_fn:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._string_fn.value().child[]
        )
    if tag == EXPR_STRING_FN_N:
        # N children, all ordinary expressions.
        if not expr._string_fn_n:
            return 0
        var sfnn_bound = 0
        for i in range(expr.string_fn_n_num_args()):
            sfnn_bound += bind_expr_inmem_payloads(
                registry, expr._string_fn_n.value().args[i]
            )
        return sfnn_bound
    if tag == EXPR_UDF_CALL:
        # One child, the UDF's argument.
        if not expr._udf_call:
            return 0
        return bind_expr_inmem_payloads(
            registry, expr._udf_call.value().child[]
        )

    # ---- TWO CHILDREN ------------------------------------------------------
    if tag == EXPR_BINARY_OP:
        if not expr._binary:
            return 0
        ref b = expr._binary.value()
        var n = bind_expr_inmem_payloads(registry, b.left[])
        return n + bind_expr_inmem_payloads(registry, b.right[])
    if tag == EXPR_MATH_FN2:
        if not expr._math_fn2:
            return 0
        ref m = expr._math_fn2.value()
        var n = bind_expr_inmem_payloads(registry, m.left[])
        return n + bind_expr_inmem_payloads(registry, m.right[])
    if tag == EXPR_MAP_GET:
        # BOTH sides: a Map key is itself an `Expr`.
        if not expr._map_get:
            return 0
        ref g = expr._map_get.value()
        var n = bind_expr_inmem_payloads(registry, g.parent[])
        return n + bind_expr_inmem_payloads(registry, g.key[])

    # ---- N CHILDREN --------------------------------------------------------
    if tag == EXPR_WHEN:
        if not expr._when:
            return 0
        ref w = expr._when.value()
        var n = 0
        for i in range(len(w.cases)):
            n += bind_expr_inmem_payloads(registry, w.cases[i].condition[])
            n += bind_expr_inmem_payloads(registry, w.cases[i].result[])
        return n + bind_expr_inmem_payloads(registry, w.default[])

    raise Error(
        String(SCAN_BIND_PASS_UNMODELLED_EXPR_TAG)
        + String(": the in-memory bind walk has no arm for expression tag ")
        + String(Int(tag))
        + String(" (")
        + expr_tag_name(tag)
        + String("). EXPR_CORRELATED_SUBQUERY proves an expression can contain")
        + String(" a whole LogicalPlan, so an unmodelled expression tag can")
        + String(" hide every in-memory leaf beneath it — UNBOUND, with the")
        + String(" caller seeing success. Add the arm in")
        + String(" scan_binding_bind_pass.mojo — descend its child expressions,")
        + String(" or return 0 with a comment saying why it cannot contain a")
        + String(" plan.")
    )
