# =============================================================================
# optimizer_resolve_scalar_subqueries
# =============================================================================
#
# The entry point of the `resolve_scalar_subqueries` pass (the pure recursive
# walkers live in `komira_optimizer/resolve_scalar_subqueries.mojo`).
# `optimizer_driver.optimize` runs this pass after `scalar_subquery_decorrelate`
# and before `flatten_dependent_joins`, constant folding (`fold_constants`) and
# `push_predicates_down` (see `optimizer_scalar_deps.mojo`).
#
# ⛔ THIS PASS EXECUTES NOTHING (the pure-optimizer rule "Optimizer's job is
# just to convert a logical plan to a physical plan"). It does not run the
# inner sub-plan; a callback that did would make this function PARAMETRIC on a
# trait conformer and two mutable origins, and `@export` refuses a parametric
# function.
#
# INSTEAD: a plan DEPENDENCY (`optimizer_scalar_deps.ScalarDepTable`).
# The pass looks each site's inner-plan hash up in the table's BINDINGS; on a
# HIT it folds the bound value in as a literal, on a MISS it records a REQUEST
# and leaves the plan untouched. The protocol this is designed for: a caller
# that executes plans (komira has none in this tree) resolves the requests and
# runs the passes again with them bound, so the fold happens at THIS position
# with the bound value. See `optimizer_scalar_deps.mojo` for the protocol, its
# termination argument, and the capability-cost analysis.
#
# 3-phase design (same shape as
# `optimizer_scalar_broadcast.scalar_broadcast_rewrite`):
#
#   Phase 1 (pure, recursive -- in komira_optimizer):
#     `_collect_scalar_subquery_sites(plan, sites)` enumerates every
#     uncorrelated SCALAR `EXPR_CORRELATED_SUBQUERY` (kind == SCALAR,
#     outer_refs == []) reachable through Filter predicates / Project
#     exprs / metadata passthroughs (Sort/Limit/Distinct/TopN), pushing
#     one `ScalarSubquerySite{inner_plan, inner_hash}` per site (a clone).
#
#   Phase 2 (THIS body -- now PURE and NON-PARAMETRIC, a FLAT for-loop):
#     For each collected site, look `inner_hash` up in the dependency table.
#     A HIT reuses the bound `ScalarValue` (and because the lookup is BY HASH,
#     the "same scalar subquery appears N times" Q15 win the old stack-local
#     `Dict[UInt64, ScalarValue]` bought is preserved -- one binding serves
#     every occurrence). A MISS records a request; the plan passes through
#     unchanged.
#
#   Phase 3 (pure, recursive -- in komira_optimizer):
#     `_rewrite_scalar_subquery_sites(plan, scalars, next_idx)` re-walks
#     in lockstep with Phase 1's enumeration order, splicing
#     `Expr.literal(scalars[i])` for the i-th site.
#
# ⚠ THE SHAPE VALIDATION BELONGS TO EXECUTION. "inner plan must return exactly
# 1 column" and `SCALAR_SUBQUERY_MULTIPLE_ROWS` are assertions about an
# EXECUTED `RecordBatch`; with no execution here there is no batch to assert on.
# They belong to the caller that executes the request, which should raise them
# with the `SCALAR_SUBQUERY_MULTIPLE_ROWS` token so the SQL-shaped error
# contract holds. What raises HERE is the collect/rewrite lockstep guard, which
# is an assertion about OUR OWN completeness and is unrelated to execution.
#
# No phase in this file is parametric and none reaches a FileHandle.
# =============================================================================

from std.collections import List

from komira_collections.slab import Slab

from komira_optimizer.resolve_scalar_subqueries import (
    ScalarSubquerySite,
    SCALAR_SUBQUERY_MULTIPLE_ROWS,
    _collect_scalar_subquery_sites,
    _rewrite_scalar_subquery_sites,
)
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_expr.scalar_value import ScalarValue

from komira_plan_ir.plan_helpers import _copy_plan
from .optimizer_scalar_deps import ScalarDepTable, DEP_SCALAR_SUBQUERY


def resolve_scalar_subqueries_rewrite(
    var plan: LogicalPlan,
    mut deps: ScalarDepTable,
) raises -> LogicalPlan:
    """Resolve every uncorrelated scalar subquery in `plan` to a literal, using
    values already bound in `deps`.

    PURE and NON-PARAMETRIC. See module-doc for the 3-phase design and for what
    this replaced. Returns the input plan unchanged when no uncorrelated SCALAR
    subquery is present (the common case) AND when one is present but not yet
    bound -- in the latter case `deps` carries the requests for a caller that
    executes plans to resolve before it runs the passes again.

    Args:
        plan: The (sub-)plan to rewrite. Consumed.
        deps: The dependency channel -- bindings in, requests out.

    Returns:
        Rewritten plan (uncorrelated scalar subqueries inlined as literals), or
        the input plan unchanged.
    """
    # ---- Phase 1: collect sites (pure, no execution). ----
    var sites = Slab[ScalarSubquerySite]()
    _collect_scalar_subquery_sites(plan, sites)
    if len(sites) == 0:
        return plan^

    # ---- Phase 2: bind (or request) per site. PURE. ----
    # The dependency table is keyed on `inner_plan.structural_hash()` -- the
    # same key the retired stack-local `Dict[UInt64, ScalarValue]` used, so N
    # occurrences of one subquery still resolve to ONE execution.
    var scalars = List[ScalarValue]()
    scalars.reserve(len(sites))
    var all_bound = True
    for i in range(len(sites)):
        var h = sites[i].inner_hash
        var bi = deps.binding_index(DEP_SCALAR_SUBQUERY, h)
        if bi < 0:
            # MISS: request it. Keep walking rather than returning here, so
            # ONE round of execution resolves EVERY site in the plan instead
            # of one per re-plan.
            all_bound = False
            deps.request(
                DEP_SCALAR_SUBQUERY, h, _copy_plan(sites[i].inner_plan)
            )
            continue
        scalars.append(deps.bound_scalar(bi))

    if not all_bound:
        # At least one dependency is unresolved. Leave EVERY site intact --
        # a partial rewrite would break Phase 3's lockstep invariant, and the
        # protocol runs this pass again with the bindings in hand.
        return plan^

    # ---- Phase 3: rewrite (pure, no execution). ----
    var next_idx: Int = 0
    var rewritten = _rewrite_scalar_subquery_sites(plan^, scalars, next_idx)
    # Lockstep invariant: every collected site was consumed exactly once.
    if next_idx != len(sites):
        raise Error(  # cov: unreachable the collect and rewrite walks visit the same nodes and exprs, so every site is consumed
            "resolve_scalar_subqueries: rewrite consumed " + String(next_idx)  # cov: unreachable see the line above
            + " sites but Phase 1 collected " + String(len(sites))  # cov: unreachable see the line above
            + " -- collect/rewrite walk-coverage drifted"  # cov: unreachable see the line above
        )
    return rewritten^
