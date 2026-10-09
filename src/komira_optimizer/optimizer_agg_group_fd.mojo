# =============================================================================
# Optimizer rule: elide a GROUP BY key that is a deterministic
# FUNCTION of the other group keys, and recompute it above the aggregate.
# =============================================================================
#
# ── THE REWRITE, IN ONE LINE ────────────────────────────────────────────────
#
#     GROUP BY a, f(a), g(a)    ==    GROUP BY a,  then project f(a), g(a)
#
# ── WHY IT IS UNCONDITIONALLY VALUE-PRESERVING ──────────────────────────────
#
# Two rows land in the same group iff they agree on EVERY key. They already
# agree on `a`; `f` is a deterministic function, so they necessarily agree on
# `f(a)` too. The partition induced by `(a, f(a), g(a))` is therefore EXACTLY
# the partition induced by `(a)` -- for every `f`, injective or not, NULLs
# included (a GROUP BY groups NULLs together, and `f(NULL)` is one value).
# Since `f(a)` is constant within a group, recomputing it ONCE PER GROUP above
# the aggregate produces the same tuple the per-ROW evaluation did.
#
# ⛔ THE ONE PLACE THAT ARGUMENT BREAKS, AND THE GUARD FOR IT. The argument
# needs "the grouping's equality on `a` implies equality of `f(a)`". That is
# true when the grouping compares by VALUE IDENTITY and false when it treats
# two DISTINCT values as one key. Floating point is exactly that case: `-0.0`
# and `0.0` group together, yet `1/(-0.0)` and `1/0.0` are `-inf` and `+inf`,
# so `GROUP BY x, 1/x` really does have more groups than `GROUP BY x`.
# ⇒ `_grouping_is_value_identity` REFUSES a derived key that reads a FLOAT16 /
#   FLOAT32 / FLOAT64 column. Integers, booleans, temporal (int-backed),
#   decimals (int-backed at a fixed column scale) and strings (byte equality)
#   are all identity, so they are served.
#
# ⛔ DETERMINISM. The only scalar construct in this engine that is not a pure
# function of its inputs is `EXPR_UDF_CALL` (there is no `random()`, no `now()`
# -- checked, not assumed). `_derived_key_is_deterministic` runs the ONE
# maintained UDF walk (`expr_udf_sites.collect_udf_calls`) rather than a second
# hand-written ladder, and takes `refuse_correlated_subquery=True` so a
# correlated subquery inside a key is a DECLINE, not a silent accept.
#
# ── THE SHAPE IT MATCHES, AND WHY THE MATCH IS AT THE **PROJECT** ───────────
#
#   Project [outer]                 <- the SQL binder's post-aggregate list
#     Aggregate [k0 .. kn, aggs]
#       Project [inner]             <- where the computed keys are evaluated
#         <anything>
#
# The SQL binder mints `__grp_key_<n>` for a computed GROUP BY term
# and splices the inner Project; the group keys reaching the Aggregate are then
# bare `EXPR_COL_REF`s. So "is this key computed, and from what?" is a question
# about the INNER project's entry, not about the key.
#
# ⭐ THE MATCH IS ANCHORED AT THE OUTER PROJECT ON PURPOSE. The elided key's
# expression has to be re-emitted ABOVE the aggregate, and the outer Project is
# already there -- so the rewrite FOLDS INTO IT and the plan gains no node. The
# alternative (insert a second Project and let `merge_projects` fold the
# stack) was rejected: the merge substitution then descended only COL_REF /
# BINARY / UNARY / CAST / ALIAS, so an outer expression of any other tag that
# named an elided key would come out of the merge with a DANGLING col_ref.
# (Since 2026-09-25 `optimizer_project_merge_guard.substitute_project_refs`
# also descends MathFn / CASE / string / IN-list nodes and REFUSES a merge that
# would still dangle; the fold-here design stands.)
# Folding here means the substitution is a two-case match on the outer entry's
# own shape (`col_ref(k)` / `alias(col_ref(k), out)`), and ANY other outer entry
# that so much as MENTIONS an elided key aborts the whole rewrite.
#
# ── WHAT DuckDB DOES HERE (v1.5.5) ─────────────────────
# NOTHING. `src/optimizer/remove_duplicate_groups.cpp:39` skips any group
# expression that is not a `BOUND_COLUMN_REF`, so `GROUP BY ClientIP,
# ClientIP-1, ClientIP-2, ClientIP-3` keeps all four keys; nothing else under
# `src/optimizer/` does functional-dependency elimination. It does not need to:
# `plan_aggregate.cpp:239` extracts every group expression into a streaming
# `PhysicalProjection` FIRST and then picks a route, so a computed key costs it
# a projection and nothing else. Ours is an admission ladder whose decline
# routes the aggregate onto a strictly worse operator -- which is why the same
# query is 4.2 s here and 0.34 s there, and why REMOVING the key is worth more
# to us than it would be to them.
#
# ── MEASURED (ClickBench Q35, this fixture) ─────────────────────────────────
# `GROUP BY client_ip, client_ip-1, client_ip-2, client_ip-3` and
# `GROUP BY client_ip` produce the SAME 9,762,046 groups. The four-key form
# routes to `resident_grace_hash_spill` (13.7 GB resident, 1.2 effective
# cores); the one-key form routes to the fused `vector_decode_leaf` RADIX leaf.
# =============================================================================

from std.collections import Optional, Set
from std.memory import OwnedPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_ALIAS,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
)
from komira_plan_ir.expr_udf_sites import collect_udf_calls
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
)
from komira_plan_ir.plan_helpers import (
    _collect_expr_columns,
    _copy_agg_expr_array,
    _copy_plan,
)


# =============================================================================
# Guards
# =============================================================================


def _grouping_is_value_identity(schema: Schema, col_name: String) -> Bool:
    """Does GROUP BY compare `col_name` by VALUE IDENTITY?

    See the header: the FD argument needs "two rows the grouping calls equal on
    `a` agree on `f(a)`", which fails for floating point (`-0.0` / `0.0` group
    together but `1/x` separates them). Everything else this engine groups on
    is identity: integers, bool, temporal (int-backed), decimal (int-backed at
    one column scale), and strings (byte equality).

    A column that is NOT IN THE SCHEMA answers False -- "cannot tell" is never
    a licence here.
    """
    for i in range(schema.num_columns()):
        if schema.field_name(i) == col_name:
            var t = schema.field_arrow_type(i)
            if t == ArrowType.FLOAT16 or t == ArrowType.FLOAT32 or t == ArrowType.FLOAT64:
                return False
            return True
    return False


def _derived_key_is_deterministic(body: Expr) -> Bool:
    """Is `body` a pure, deterministic function of the columns it reads?

    ⭐ RUNS THE ONE MAINTAINED UDF WALK, not a second tag ladder. A hand-written
    allow-list over `EXPR_*` is the defect class `expr_walk.mojo`'s header
    documents three production instances of -- a ladder whose fall-through is a
    silent accept.

    `refuse_correlated_subquery=True` makes a correlated subquery inside the key
    RAISE, which is caught here and reported as "not deterministic" (a decline).
    An `EXPR_AGG_FN` / `EXPR_WINDOW_FN` / `EXPR_COL_IDX` at the top is rejected
    outright: the first two cannot legally be group keys (the binder raises),
    and a POSITIONAL reference would silently re-bind under the narrowed schema
    this rewrite produces.
    """
    if (
        body.tag == EXPR_AGG_FN
        or body.tag == EXPR_WINDOW_FN
        or body.tag == EXPR_CORRELATED_SUBQUERY
        or body.tag == EXPR_COL_IDX
    ):
        return False
    var sites = List[Expr]()
    try:
        collect_udf_calls(body, sites, refuse_correlated_subquery=True)
    except:
        return False
    return len(sites) == 0


def _name_index(names: List[String], want: String) -> Int:
    for i in range(len(names)):
        if names[i] == want:
            return i
    return -1


# =============================================================================
# The rewrite
# =============================================================================


def elide_functionally_dependent_group_keys(var plan: LogicalPlan) raises -> LogicalPlan:
    """Wrapper around the in-place form."""
    elide_functionally_dependent_group_keys_inplace(plan)
    return plan^


def elide_functionally_dependent_group_keys_inplace(mut plan: LogicalPlan) raises:
    """Walk the plan, rewriting every `Project(Aggregate(Project(..)))` whose
    group-key set contains a key that is a deterministic function of the others.

    IDEMPOTENT: after a rewrite no elidable derived key remains, so a second
    run declines. A plan the rule does not match is returned structurally
    untouched (no copy, no rebuild).
    """
    if plan.tag == PLAN_PROJECT:
        # ⚠ RECURSE PAST THE AGGREGATE, NOT INTO IT, WHEN THIS IS THE MATCH
        # SITE. Recursing into the child normally would let a nested match fire
        # first and change the shape under our feet.
        if plan._project.value()[].child[].tag == PLAN_AGGREGATE:
            elide_functionally_dependent_group_keys_inplace(
                plan._project.value()[].child[]._aggregate.value()[].child[]
            )
            var rebuilt = _build_fd_elided(plan)
            if rebuilt:
                plan = rebuilt.take()
            return
        elide_functionally_dependent_group_keys_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        elide_functionally_dependent_group_keys_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_FILTER:
        elide_functionally_dependent_group_keys_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        elide_functionally_dependent_group_keys_inplace(plan._join.value()[].left[])
        elide_functionally_dependent_group_keys_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        elide_functionally_dependent_group_keys_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        elide_functionally_dependent_group_keys_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        elide_functionally_dependent_group_keys_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        elide_functionally_dependent_group_keys_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN,
    # PLAN_UNION: this rule does not apply. Leave unchanged.


def _build_fd_elided(imm plan: LogicalPlan) raises -> Optional[LogicalPlan]:
    """`plan` is a PLAN_PROJECT over a PLAN_AGGREGATE. Return the rewritten
    subtree, or None when ANY gate declines.

    Every gate returns None -- a decline costs one walk and nothing else, and
    is always the safe answer.
    """
    ref outer_pd = plan._project.value()[]
    if outer_pd.udf:
        return None
    ref agg_plan = outer_pd.child[]
    ref agg = agg_plan._aggregate.value()[]
    if agg.udf:
        return None
    ref inner_plan = agg.child[]
    if inner_plan.tag != PLAN_PROJECT:
        return None
    ref inner_pd = inner_plan._project.value()[]
    if inner_pd.udf:
        return None

    var n_keys = len(agg.group_by)
    var n_aggs = len(agg.agg_exprs)
    if n_keys < 2:
        return None

    ref agg_schema = agg_plan.output_schema
    if agg_schema.num_columns() != n_keys + n_aggs:
        return None

    # ── (1) every key is a bare col_ref whose name IS its own output name ────
    # A mismatch means `_disambiguate_field` renamed a key; the restore side
    # would then have to reason about a name the key does not carry. Decline.
    var key_names = List[String]()
    for i in range(n_keys):
        if agg.group_by[i].tag != EXPR_COL_REF:
            return None
        var nm = agg.group_by[i].col_ref_name()
        if agg_schema.field_name(i) != nm:
            return None
        key_names.append(nm)

    # ── (2) resolve each key to its entry in the inner Project ──────────────
    ref inner_schema = inner_plan.output_schema
    var n_inner = len(inner_pd.exprs)
    if inner_schema.num_columns() != n_inner:
        return None
    var key_entry = List[Int]()
    for i in range(n_keys):
        var idx = -1
        for j in range(n_inner):
            if inner_schema.field_name(j) == key_names[i]:
                idx = j
                break
        if idx < 0:
            return None
        key_entry.append(idx)

    # ── (3) classify: PASS-THROUGH keys provide base columns ────────────────
    var is_base = List[Bool]()
    var base_cols = List[String]()
    for i in range(n_keys):
        ref e = inner_pd.exprs[key_entry[i]]
        if e.tag == EXPR_COL_REF and e.col_ref_name() == key_names[i]:
            is_base.append(True)
            base_cols.append(key_names[i])
        else:
            is_base.append(False)
    if len(base_cols) == 0:
        return None

    # ── (4) which derived keys are functionally determined by the base set ──
    var elide = List[Bool]()
    var n_elide = 0
    for i in range(n_keys):
        if is_base[i]:
            elide.append(False)
            continue
        ref e = inner_pd.exprs[key_entry[i]]
        # Only an explicit alias: copying it reproduces the output NAME exactly.
        # A bare computed entry is auto-named by `_infer_expr_field` and that
        # name is not something this rule should be re-deriving.
        if e.tag != EXPR_ALIAS:
            elide.append(False)
            continue
        if e.alias_name() != key_names[i]:
            elide.append(False)
            continue
        if not _derived_key_is_deterministic(e.alias_child_ref()):
            elide.append(False)
            continue
        var cols = Set[String]()
        _collect_expr_columns(e.alias_child_ref(), cols)
        if len(cols) == 0:
            # A constant key. The binder already elides those (its `const_canon`
            # arm); doing it here too would duplicate a rule that owns the
            # "last surviving key" reasoning.
            elide.append(False)
            continue
        var ok = True
        for c in cols:
            if _name_index(base_cols, c) < 0:
                ok = False
                break
            if not _grouping_is_value_identity(agg_schema, c):
                ok = False
                break
        if not ok:
            elide.append(False)
            continue
        elide.append(True)
        n_elide += 1

    if n_elide == 0:
        return None
    if n_keys - n_elide < 1:
        return None  # cov: unreachable only derived keys are elided and step (3) required a base key, so a key survives

    # ── (5) the new OUTER project, folded ───────────────────────────────────
    # Built FIRST because it is the gate most likely to decline: an outer entry
    # of any shape other than `col_ref(k)` / `alias(col_ref(k), out)` that
    # MENTIONS an elided key aborts the whole rewrite.
    var new_outer = ExprArray()
    for k in range(len(outer_pd.exprs)):
        ref oe = outer_pd.exprs[k]
        var ref_name = String("")
        var wrapped = False
        if oe.tag == EXPR_COL_REF:
            ref_name = oe.col_ref_name()
        elif oe.tag == EXPR_ALIAS and oe.alias_child_ref().tag == EXPR_COL_REF:
            ref_name = oe.alias_child_ref().col_ref_name()
            wrapped = True
        else:
            # Anything else: safe to copy verbatim ONLY if it names no elided
            # key. `_collect_expr_columns` is the ONE maintained column walk.
            var ocols = Set[String]()
            _collect_expr_columns(oe, ocols)
            for i in range(n_keys):
                if elide[i] and key_names[i] in ocols:
                    return None
            new_outer.append(oe.copy())
            continue

        var ki = _name_index(key_names, ref_name)
        if ki < 0 or not elide[ki]:
            new_outer.append(oe.copy())
            continue

        # The restore expression IS the inner Project's own entry for that key
        # -- `alias(<body>, __grp_key_n)`. Reusing the node verbatim is what
        # makes this rewrite need NO expression substitution walk at all.
        if wrapped:
            var body = inner_pd.exprs[key_entry[ki]].alias_child_ref().copy()
            new_outer.append(Expr.alias(body^, oe.alias_name()))
        else:
            new_outer.append(inner_pd.exprs[key_entry[ki]].copy())

    # ── (6) the new INNER project: drop the now-dead derived entries ────────
    var needed = Set[String]()
    for i in range(n_keys):
        if not elide[i]:
            needed.add(key_names[i])
    for a in range(n_aggs):
        ref ae = agg.agg_exprs[a]
        if ae.child:
            _collect_expr_columns(ae.child.value(), needed)
        if ae.child1:
            _collect_expr_columns(ae.child1.value(), needed)
        if ae.child2:
            _collect_expr_columns(ae.child2.value(), needed)
        if ae.child3:
            _collect_expr_columns(ae.child3.value(), needed)

    var new_inner_exprs = ExprArray()
    for j in range(n_inner):
        var drop = False
        for i in range(n_keys):
            if elide[i] and key_entry[i] == j:
                if not (inner_schema.field_name(j) in needed):
                    drop = True
                break
        if not drop:
            new_inner_exprs.append(inner_pd.exprs[j].copy())

    # ── (7) rebuild, bottom-up ──────────────────────────────────────────────
    var grandchild = _copy_plan(inner_pd.child[])
    var new_inner = LogicalPlan.project(new_inner_exprs^, grandchild^)

    var new_gb = ExprArray()
    for i in range(n_keys):
        if not elide[i]:
            new_gb.append(Expr.col_ref(key_names[i]))
    var new_aggs = _copy_agg_expr_array(agg.agg_exprs)
    var new_agg = LogicalPlan.aggregate(new_gb^, new_aggs^, new_inner^)
    # The group SET is unchanged by construction, so the estimate still holds.
    if agg.estimated_groups:
        new_agg._aggregate.value()[].estimated_groups = Optional(
            agg.estimated_groups.value()
        )

    # ── (8) POST-CONDITIONS. Abandon rather than emit a plan we cannot prove ─
    # (a) the new aggregate must not have re-disambiguated any surviving name.
    var n_surv = n_keys - n_elide
    ref new_agg_schema = new_agg.output_schema
    if new_agg_schema.num_columns() != n_surv + n_aggs:
        return None  # cov: unreachable LogicalPlan.aggregate emits one column per group key and one per aggregate
    var s = 0
    for i in range(n_keys):
        if not elide[i]:
            if new_agg_schema.field_name(s) != key_names[i]:
                return None
            s += 1
    for a in range(n_aggs):
        if new_agg_schema.field_name(n_surv + a) != agg_schema.field_name(n_keys + a):
            return None

    var new_project = LogicalPlan.project(new_outer^, new_agg^)

    # (b) the SUBTREE's own output schema is the contract with everything above
    # it. Names AND arrow types, both directions.
    ref old_schema = plan.output_schema
    ref out_schema = new_project.output_schema
    if out_schema.num_columns() != old_schema.num_columns():
        return None
    for i in range(old_schema.num_columns()):
        if out_schema.field_name(i) != old_schema.field_name(i):
            return None
        if out_schema.field_arrow_type(i) != old_schema.field_arrow_type(i):
            return None

    return Optional(new_project^)
