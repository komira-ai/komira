# =============================================================================
# corr_subquery — the ONE place a subquery's inner plan is unboxed
# =============================================================================
#
# ⭐ THE OTHER HALF OF KEEPING `Expr` A LEAF.
#
# `plan/expr.mojo` may not name `LogicalPlan` — that import would be the single
# edge holding `Expr` inside a large strongly-connected component and pulling
# most of `komira_core` into its translation-unit closure. The payload
# therefore holds the plan in an `ErasedBox` (`corr_subquery_data.mojo`), and
# THIS module — which is downstream of both `expr` and `logical_plan`, so it may
# name either — is where the type comes back.
#
# ── THE TWO ACCESSORS, AND WHY THE NAME MATTERS ─────────────────────────────
#
#     corr_subq_inner_plan_ref(e)      from an `Expr`
#     corr_data_inner_plan_ref(cs)     from the payload
#
# The cross-edge from the expression tree into the plan tree is *the* thing a
# plan-node-only walk cannot see: a walk that forgets it silently skips every
# plan hanging off a subquery while its caller sees success. Naming the edge
# is what makes it greppable: `git grep corr_subq_inner_plan_ref` enumerates
# every walk that crosses it.
#
# ★ THE EDGE IS ALSO CHECKED. These accessors RAISE on an `ErasedBox` type-tag
# mismatch, so there is no way to reach a subquery's plan that is not both
# greppable and checked.
#
# ⚠ THERE IS NO FIELD ACCESS TO THE PLAN, DELIBERATELY. A by-hand field access
# would let consumers reach the plan with nothing enumerating who did.
# =============================================================================

from .logical_plan import LogicalPlan
from .corr_subquery_data import (
    CorrelatedSubqueryData,
    CORR_SUBQ_PLAN_TYPE_TAG,
)
from .expr import Expr


comptime CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH: StaticString = (
    "CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH"
)
"""NAMED ERROR — an `ErasedBox` reached through a correlated-subquery payload
did not hold a `LogicalPlan`.

⚠ IT RAISES RATHER THAN DEREFERENCING, AND THAT IS THE WHOLE GUARD. The box's
bytes carry no type: a `bitcast` to the wrong type is not a crash, it is a
plausible-looking struct read out of foreign bytes — the silent-wrong-answer
class. The tag is minted from the boxed type itself
(`BoxablePlan.erased_type_tag`), never asserted by the boxing site, so a second
boxable type gets a distinct tag automatically instead of inheriting this one.

Unreachable today by construction — `LogicalPlan` is the only `BoxablePlan`
conformer in this tree — which is exactly why it must stay: the check is what
makes "only one conformer" a fact the compiler enforces at the seam rather than
a comment that rots the day someone adds the second one."""


@always_inline
def corr_data_inner_plan_ref(
    ref cs: CorrelatedSubqueryData,
) raises -> ref [origin_of(cs._plan._home)] LogicalPlan:
    """The subquery's inner plan, from the payload. RAISES on a tag mismatch.

    ⚠ THIS IS THE ONE CROSS-EDGE FROM THE EXPRESSION TREE BACK INTO THE PLAN
    TREE — the only `LogicalPlan` reachable outside a plan node's own child
    slot, and therefore the one way a whole plan (scan leaves included) hides
    somewhere a plan-node-only walk will never look.

    Mutability follows the argument: pass `cs` mutably and the returned `ref` is
    mutable, which is what `scan_binding_bind_pass.bind_plan_inmem_payloads`
    needs — it binds in place. (That in-place mutation is also the reason the
    plan is OWNED per payload rather than shared behind a registry handle; see
    `corr_subquery_data.mojo`'s header.)"""
    if cs._plan.type_tag() != CORR_SUBQ_PLAN_TYPE_TAG:
        raise Error(String(CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH))
    return cs._plan.unsafe_as[LogicalPlan]()


@always_inline
def corr_subq_inner_plan_ref(
    ref expr: Expr,
) raises -> ref [origin_of(expr._corr_subq.value()[]._plan._home)] LogicalPlan:
    """The subquery's inner plan, from the `Expr`. Requires
    tag == EXPR_CORRELATED_SUBQUERY.

    ⚠ THE NAME IS LOAD-BEARING — see the module
    header. `git grep corr_subq_inner_plan_ref` must keep enumerating every walk
    that crosses from an expression into a plan."""
    if expr._corr_subq.value()[]._plan.type_tag() != CORR_SUBQ_PLAN_TYPE_TAG:
        raise Error(String(CORR_SUBQ_PLAN_TYPE_TAG_MISMATCH))
    return expr._corr_subq.value()[]._plan.unsafe_as[LogicalPlan]()


def corr_subq_inner_plan_copy(expr: Expr) raises -> LogicalPlan:
    """A deep copy of the subquery's inner plan.

    The common consumer shape — `flatten_dependent_joins` and
    `scalar_subquery_decorrelate` both take a clone and lower it — spelled once
    so the tag check cannot be forgotten at a call site that only wanted a
    copy."""
    return corr_subq_inner_plan_ref(expr).copy()
