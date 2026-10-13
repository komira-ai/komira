# =============================================================================
# optimizer_driver -- the pass order: one logical plan in, one optimized out
# =============================================================================
#
# `optimize(plan, config, deps)` runs komira_optimizer's rewrite rules over a
# `LogicalPlan` in a fixed order and returns the rewritten `LogicalPlan`. It is
# a PURE function of its three inputs:
#
#   * `plan`: the logical plan, with views already resolved (see below) and
#     with whatever statistics the caller has injected on its scans
#     (`ScanData.table_stats`, `ScanData.row_count`). The driver reads those
#     only through the rules that consume them (join reordering, eager
#     aggregation); it computes and stores none.
#   * `config`: the `OptimizerConfig` the caller built. The driver reads
#     `eager_agg` and `semi_pushdown`; the other fields belong to rules that run
#     outside this pass order (scan-share planning, aggregate CSE) and do not
#     change its output.
#   * `deps`: the `ScalarDepTable` of engine-supplied scalar bindings. The two
#     subquery-folding passes fold a bound value and record a request for an
#     unbound one (`optimizer_scalar_deps.mojo`).
#
# It executes nothing, opens nothing and calls back into nothing. It returns the
# in-memory plan; turning it into bytes is `komira_plan_wire`'s job.
#
# WHAT THE CALLER DOES BEFORE AND AFTER
#
#   * View resolution (`view_resolution_pass`) needs the caller's view
#     registry, so it is the caller's first step, not one of these passes.
#   * One call is one round. When `deps.has_requests()` is True on return, at
#     least one scalar-subquery site is still unfolded; the caller executes the
#     requests, binds the results, clears the requests and calls `optimize`
#     again on the ORIGINAL plan, so each fold lands at its position in the
#     order below. That round loop, with its cap and the
#     `OPTIMIZE_REFUSAL_UNRESOLVED_DEPS` refusal, belongs to the caller that
#     executes plans; it is not here.
#
# THE ORDER (each pass runs once; nothing here iterates to a fixed point)
#
#   The node kinds the plan holds are scanned once after step 4 (`has_*`),
#   when the subquery passes have turned subquery expressions into plan nodes.
#   A pass gated on a kind runs only when the plan had one at that point;
#   `has_filter` is re-scanned after `push_join_residual_to_side`, the one
#   later pass that can create a node kind (a Filter) that later gates read.
#   Steps 18 and 19 scan the current plan instead.
#
#   1  partition_prune_scans, attach_hive_predicate        (scans, first)
#   2  scalar_subquery_decorrelate                          (before 3)
#   3  resolve_scalar_subqueries_rewrite(deps)              (before 4)
#   4  flatten_dependent_joins, join_predicate_decompose
#   5  push_join_residual_to_side                 [join]   then re-scan Filter
#   6  fold_constants, simplify_predicates                 (when there is work)
#   7  factor_or_conjuncts                        [filter] BEFORE 8
#   8  eliminate_common_subexpressions, rewrite_in_clauses
#                                     [filter or project or aggregate]
#   9  fuse_filters (consecutive filters only), decompose_symmetric_or,
#      factor_or_conjuncts, decompose_filters [join], push_predicates_down,
#      scalar_broadcast_rewrite(deps)             [filter]
#   10 eliminate_cross_join                       [join]
#   11 push_projections_down, prune_columns
#   12 elide_functionally_dependent_group_keys    [aggregate and project]
#   13 merge_projects, eliminate_identity_projects        [project]
#   14 eager_aggregate_pushdown [join, config.eager_agg],
#      absorb_expression_into_aggregate, convert_inner_to_semi   [join]
#   15 materialize_agg_input
#   16 push_predicates_down, eliminate_cross_join, push_semi_reducers_down
#      (config.semi_pushdown), reorder_joins_with_dp,
#      restore_join_reorder_output_columns, eliminate_identity_projects
#                                                 [join]
#      select_join_build_side                     (always)
#   17 push_limit_down, fuse_sort_limit (sort above limit only)  [limit]
#   18 optimize_window_rewrite      [PartitionBy or Project in the current plan]
#   19 fuse_partition_topn          [PartitionBy in the current plan]
#
# Each call below says what its position does.
#
# WHAT THE TESTS PIN. `tests/test_optimizer_driver_passes.mojo` (steps 1-10)
# and `tests/test_optimizer_driver_passes_late.mojo` (steps 10-19) show each
# pass changing some plan at its step, so dropping a pass fails a test, as
# do fourteen named moves of a pass out of its stated position.
# `tests/test_optimizer_driver_order.mojo` and `tests/test_optimizer_driver_
# order_steps.mojo` hold one plan per reorder that changes the plan, for
# these reorders only: two adjacent calls inside a step swapped; the last call
# of a step swapped with the first call of the next; a whole step swapped with
# the whole next step; and step 6 moved after step 8.
# `tests/test_optimizer_driver_gates.mojo` pins the gate arms a plan with a
# Filter cannot reach. komira#1297 lists every mutant; a reorder in these
# families whose two orders gave the same plan on every plan tried is argued
# there, not tested. Any other move of a pass is not pinned.
#
# NOT IN THIS ORDER, though the reference pipeline ran them at step 13:
#
#   * `detect_bypass_columns` returns its input unchanged (the column set it
#     collects is discarded), so calling it changes nothing.
#   * `late_materialize` narrows a scan under a Filter to the Filter's own
#     columns. The one Filter-over-scan this order leaves for it is the
#     scalar-broadcast fold over an in-memory scan (step 9), and there it
#     dropped columns the Filter outputs (komira#1292).
#
# ERRORS. A pass that raises stops the driver; `optimize` re-raises the pass's
# own `Error` unchanged. `optimize_status` is the non-raising twin: a `try` /
# `except` around the one `optimize` call, returning `OptimizeResult.ok(plan)`
# or `OptimizeResult.from_error(<message>)` (`optimizer_result.mojo` classifies
# the message by imported token). There is no second pass list to drift.
#
# THE PORTABLE PROFILE. `optimize_portable(plan, config, profile)` is the
# entry a producer calls when its output must be the same plan on every
# platform that runs it (komira-ai/komira#1094, §5.3). It runs the same
# pass order through the same function as `optimize`, with two
# differences (payload narrowing is not a pass of this order in either entry:
# the host lowering derives it, `komira_lowering_rules`):
#
#   * There is no `deps` argument. Steps 3 and 9 see an empty binding table,
#     so neither folds a value; a site that needs an executed sub-plan
#     records a request, and a plan that ends with one is refused with
#     `PORTABLE_REFUSAL_NEEDS_EXECUTION` (the producer executes nothing).
#   * A `PortableProfile` whose version this build does not implement is
#     refused with `PORTABLE_REFUSAL_UNKNOWN_PROFILE` before any pass runs.
#
# `config` is read only from the argument, as in `optimize`. What makes the
# output the same on every platform is a property of the passes, not of this
# entry: no pass reads the environment, a clock or an address; Dict and Set
# iteration is insertion order; every cost comparison is a total order
# (`optimizer_cost_order.dp_pair_beats` breaks equal DP costs on relation-set
# bits).
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
)
from komira_plan_ir.plan_helpers import (
    _plan_has_tag,
    _plan_has_consecutive_filters,
    _plan_has_sort_above_limit,
    _plan_has_foldable_exprs,
    _plan_has_simplifiable_exprs,
)

from .optimizer_config import OptimizerConfig
from .optimizer_result import OptimizeResult
from .optimizer_scalar_deps import ScalarDepTable

from .partition_prune_scans import partition_prune_scans
from .attach_hive_predicate import attach_hive_predicate
from .scalar_subquery_decorrelate import scalar_subquery_decorrelate
from .optimizer_resolve_scalar_subqueries import resolve_scalar_subqueries_rewrite
from .flatten_dependent_joins import flatten_dependent_joins
from .join_predicate_decompose import join_predicate_decompose
from .optimizer_filter import (
    push_join_residual_to_side,
    fuse_filters,
    decompose_filters,
    push_predicates_down,
    eliminate_cross_join,
)
from .optimizer_expr import (
    fold_constants,
    simplify_predicates,
    eliminate_common_subexpressions,
    rewrite_in_clauses,
)
from .optimizer_or_factoring import factor_or_conjuncts
from .optimizer_symmetric_or import decompose_symmetric_or
from .optimizer_scalar_broadcast import scalar_broadcast_rewrite
from .optimizer_projection import (
    push_projections_down,
    prune_columns,
    merge_projects,
    eliminate_identity_projects,
)
from .optimizer_agg_group_fd import elide_functionally_dependent_group_keys
from .optimizer_eager_agg import eager_aggregate_pushdown
from .optimizer_join import (
    absorb_expression_into_aggregate,
    convert_inner_to_semi,
    push_semi_reducers_down,
    join_reorder_output_names,
    restore_join_reorder_output_columns,
    select_join_build_side,
)
from .optimizer_materialize_agg_input import materialize_agg_input
from .optimizer_dpccp import reorder_joins_with_dp
from .optimizer_misc import push_limit_down, fuse_sort_limit
from .optimizer_window_rewrite import optimize_window_rewrite
from .optimizer_partition_topn import fuse_partition_topn


def optimize(
    var plan: LogicalPlan,
    config: OptimizerConfig,
    mut deps: ScalarDepTable,
) raises -> LogicalPlan:
    """Run the optimizer's passes over `plan` in their fixed order.

    Args:
        plan: The logical plan, views already resolved. Consumed.
        config: The options; `eager_agg` and `semi_pushdown` are read here.
        deps: Scalar bindings in, requests out (one round; the caller loops).

    Returns:
        The optimized logical plan.

    Raises:
        The first pass's `Error` that refuses the plan, unchanged.
    """
    return _run_pass_order(plan^, config, deps)


def _run_pass_order(
    var plan: LogicalPlan,
    config: OptimizerConfig,
    mut deps: ScalarDepTable,
) raises -> LogicalPlan:
    """The pass order, shared by `optimize` and `optimize_portable`: one list,
    so the two entries cannot run different passes or a different order.
    """
    # 1. Scans. Partition pruning first: it reads a Filter directly over a
    # partitioned scan (the shape before pushdown rewrites it), and a smaller
    # path list means less work for everything after. `attach_hive_predicate`
    # handles the lazy dir-scanning Hive shape `partition_prune_scans` declines,
    # so the two never both act on one scan. Both run before decorrelation,
    # so a scan inside a scalar subquery gets no Hive predicate; the other
    # order would attach one (the reference order, kept and pinned).
    plan = partition_prune_scans(plan^)
    plan = attach_hive_predicate(plan^)

    # 2-3. Uncorrelated scalar subqueries. Decorrelation first: a subquery whose
    # inner plan is provably at most one row becomes a broadcast cross join and
    # needs no binding. What it leaves is folded from `deps` (or requested).
    # Both run before `flatten_dependent_joins`, whose correlation hoist is for
    # subqueries with outer references.
    plan = scalar_subquery_decorrelate(plan^)
    plan = resolve_scalar_subqueries_rewrite(plan^, deps)

    # 4. Correlated subqueries become joins, and `predicate=` join residuals
    # are split into equi keys and a plain residual. Both run before every
    # structural rewrite, because they create joins those rewrites optimize.
    plan = flatten_dependent_joins(plan^)
    plan = join_predicate_decompose(plan^)

    # --- Which node kinds the plan holds, now that subqueries are lowered. ---
    # Steps 2-4 turn subquery expressions into joins, aggregates, projects and
    # filters, which a scan of the input cannot see (the inner plan lives inside
    # an expression). No gate is read before this point.
    var has_filter = _plan_has_tag(plan, PLAN_FILTER)
    var has_project = _plan_has_tag(plan, PLAN_PROJECT)
    var has_aggregate = _plan_has_tag(plan, PLAN_AGGREGATE)
    var has_join = _plan_has_tag(plan, PLAN_JOIN)
    var has_limit = _plan_has_tag(plan, PLAN_LIMIT)

    # 5. A join's single-side residual conjuncts become a Filter on the owning
    # child. That can create the first Filter in the plan, so `has_filter` is
    # re-scanned: the filter passes below must see the new node.
    if has_join:
        plan = push_join_residual_to_side(plan^)
        has_filter = _plan_has_tag(plan, PLAN_FILTER)

    # 6. Expression simplification, each pass behind a precheck. Folding
    # first: it turns `NOT ((1 = 1) AND NOT x)` into `NOT NOT x`, which
    # simplification then removes. The prechecks read Filter predicates,
    # Project expressions and scan filters only, so a plan whose one foldable
    # or simplifiable expression is an aggregate argument or a join residual
    # skips the pass, although the pass rewrites those slots (komira#1306).
    # Both run after step 5, so a residual step 5 moved into a Filter folds,
    # and before steps 7-8, which read their output: a removed double
    # negation exposes an OR to factoring, and a folded constant makes two
    # expressions equal for CSE.
    if _plan_has_foldable_exprs(plan):
        plan = fold_constants(plan^)
    if _plan_has_simplifiable_exprs(plan):
        plan = simplify_predicates(plan^)

    # 7-8. OR factoring BEFORE common-subexpression elimination. A conjunct C
    # shared by every branch of an OR occurs N times, so CSE would hoist it into
    # a synthesized column of a Project, and a predicate on a synthesized column
    # can no longer be pushed into a scan. Factoring first leaves C once, as a
    # top-level conjunct (`C AND (rest)`), which CSE leaves alone and pushdown
    # can route. CSE's gate includes Aggregate so its aggregate-argument axis
    # runs on plans with no Filter or Project. CSE runs before the IN rewrite,
    # which collapses an OR of equalities on one column: `(a + b) = 1 OR
    # (a + b) = 2` is one only after CSE has named `a + b`.
    if has_filter:
        plan = factor_or_conjuncts(plan^)
    if has_filter or has_project or has_aggregate:
        plan = eliminate_common_subexpressions(plan^)
        plan = rewrite_in_clauses(plan^)

    # 9. Filters. Symmetric-OR inference runs before pushdown so the
    # single-column ORs it infers are pushed to their join side. The second OR
    # factoring catches an OR the first one skipped: a branch holding a
    # CASE/WHEN halts factoring, and once CSE has replaced a repeated WHEN with
    # a synthesized column the shared conjuncts factor out. It runs after
    # symmetric-OR inference, so an OR it reduces to a swap pattern gets no
    # inferred IN lists (the reference order, kept and pinned). Splitting
    # AND-trees into nested Filters lets pushdown move each conjunct to its own
    # join side; without a join there is nowhere to push, so it is gated on
    # one. The scalar-broadcast fold runs where the reference ran it, after
    # pushdown and before step 10, so a binding keyed on an Aggregate over a
    # cross join still matches it; a bound site becomes a Filter over an
    # in-memory scan, which is why `late_materialize` is not in this order.
    if has_filter:
        if _plan_has_consecutive_filters(plan):
            plan = fuse_filters(plan^)
        plan = decompose_symmetric_or(plan^)
        plan = factor_or_conjuncts(plan^)
        if has_join:
            plan = decompose_filters(plan^)
        plan = push_predicates_down(plan^)
        plan = scalar_broadcast_rewrite(plan^, deps)
    # 10. A Filter of equalities over a cross join becomes an equi-join.
    if has_join:
        plan = eliminate_cross_join(plan^)

    # 11. Projection pushdown and column pruning.
    plan = push_projections_down(plan^)
    plan = prune_columns(plan^)

    # 12. A GROUP BY key that is a function of the other keys is elided and
    # recomputed above the aggregate. After step 11 as in the reference order
    # (on every plan tried, running it before step 11 gave the same plan),
    # and BEFORE step 13: dropping the computed key usually leaves the
    # aggregate's child Project an identity, and step 13 is what removes it.
    if has_aggregate and has_project:
        plan = elide_functionally_dependent_group_keys(plan^)

    # 13. Adjacent Projects merge, then identity Projects go.
    if has_project:
        plan = merge_projects(plan^)
        plan = eliminate_identity_projects(plan^)

    # 14. Joins and aggregates, in the reference order: eager aggregation, then
    # absorb, then inner-to-semi. Eager aggregation therefore sees an
    # Aggregate over a computed-input Project (which absorb would remove) and
    # declines it (komira#1293). Inner-to-semi runs after step 10, which turns
    # a Filter of equalities over a cross join into the INNER join it converts.
    # `config.eager_agg` False skips eager aggregation. Absorb runs before
    # inner-to-semi, and step 15 after it, so a join over a unique side under
    # an Aggregate stays INNER where either other order would make it SEMI
    # (the reference order, kept and pinned). Step 13 runs first: eager
    # aggregation declines an Aggregate over two stacked Projects, which
    # `merge_projects` makes one.
    if has_join:
        if config.eager_agg:
            plan = eager_aggregate_pushdown(plan^)
        plan = absorb_expression_into_aggregate(plan^)
        plan = convert_inner_to_semi(plan^)

    # 15. Computed aggregate inputs move into a Project under the Aggregate.
    # AFTER `absorb_expression_into_aggregate`, which produces that shape.
    plan = materialize_agg_input(plan^)

    # 16. Join order. Pushdown and cross-join elimination run again first. A
    # conjunct the second OR factoring hoisted above a CSE-introduced Project
    # stays above that Project in step 9; the re-run here moves it to its join
    # side and, when it is an equality over a cross join, folds it into that
    # join's keys. The SEMI/ANTI reducer pushdown runs AFTER
    # `convert_inner_to_semi` (whose placement it corrects) and BEFORE the
    # reorder: on a SEMI over a chain of INNER joins it can decline on the
    # chain as written where, after the reorder, it would push the SEMI into
    # the reordered chain. Reordering exchanges join operands, which permutes
    # the output columns; the output order is the query's, so it is captured
    # before the reorder and restored after it.
    if has_join:
        plan = push_predicates_down(plan^)
        plan = eliminate_cross_join(plan^)
        plan = push_semi_reducers_down(plan^, config)
        var pre_reorder_out = join_reorder_output_names(plan)
        plan = reorder_joins_with_dp(plan^)
        plan = restore_join_reorder_output_columns(plan^, pre_reorder_out^)
        # A Project already above a reordered join can be an identity over the
        # order-restoring Project, and step 13 has already run, so identity
        # Projects are removed again here. (On the corpus of
        # test_optimizer_driver_corpus, `optimize` stays idempotent without
        # this call since the build-side rule stopped exchanging operands.)
        plan = eliminate_identity_projects(plan^)

    # Build side: recorded on every join, in `JoinData.build_side`; no operand
    # moves (docs/design/optimized_plan.md §5.1, §5.2). AFTER the reorder,
    # which builds new join nodes with no decision on them. NOT GATED on
    # `has_join`: that scan does not descend a Union, an as-of join or a
    # CastToVarchar, and a join below one of them must be decided too. Every
    # pass after this one carries the field when it rebuilds a join.
    plan = select_join_build_side(plan^)

    # 17. Limits: push down, then Sort over Limit becomes TopN.
    if has_limit:
        plan = push_limit_down(plan^)
        if _plan_has_sort_above_limit(plan):
            plan = fuse_sort_limit(plan^)

    # 18-19. Windows: co-locate and fuse PartitionBy nodes, elide a Sort the
    # PartitionBy already satisfies, then fuse PartitionBy + Filter into
    # PartitionTopN, in the reference order. A fused PartitionBy carries more
    # than one function, which `fuse_partition_topn` declines, so on
    # Filter(rn <= K) over two same-window PartitionBys this order keeps the
    # Filter where the opposite order would fuse (komira#1293). Both gates
    # read the current plan.
    if _plan_has_tag(plan, PLAN_PARTITION_BY) or _plan_has_tag(plan, PLAN_PROJECT):
        plan = optimize_window_rewrite(plan^)
    if _plan_has_tag(plan, PLAN_PARTITION_BY):
        plan = fuse_partition_topn(plan^)

    return plan^


def optimize_status(
    var plan: LogicalPlan,
    config: OptimizerConfig,
    mut deps: ScalarDepTable,
) -> OptimizeResult:
    """`optimize`, without `raises`: the plan, or a status code and the
    refusing pass's message (`OptimizeResult.from_error`).

    The body is one `try` / `except` around one `optimize` call. An OK result
    says no pass refused; it says nothing about `deps.has_requests()`, which the
    caller still checks.
    """
    try:
        return OptimizeResult.ok(optimize(plan^, config, deps))
    except e:
        return OptimizeResult.from_error(String(e))


comptime PORTABLE_PROFILE_V1: Int = 1
"""The one `PortableProfile` version this build implements: the driver's pass
order with no scalar bindings (see the module header)."""

comptime PORTABLE_REFUSAL_UNKNOWN_PROFILE = "OPTIMIZE_PORTABLE_UNKNOWN_PROFILE"
"""`optimize_portable` was given a profile version this build does not
implement. Raised before any pass runs."""

comptime PORTABLE_REFUSAL_NEEDS_EXECUTION = "OPTIMIZE_PORTABLE_NEEDS_EXECUTION"
"""The plan holds a scalar site that only an executed sub-plan can fold (an
uncorrelated scalar subquery that decorrelation cannot prove single-row, or a
Filter comparing against an aggregate of its own grouped input). A producer
executes nothing, so `optimize_portable` refuses it."""


struct PortableProfile(Copyable, Movable):
    """The portable profile a producer passes to `optimize_portable`
    (komira-ai/komira#1094, §5.3). A required argument with no default, so a
    caller states which pass set it wants.

    Fields:
        version: The profile version. `PORTABLE_PROFILE_V1` is the only one
            this build implements; any other value is refused.
    """

    var version: Int

    def __init__(out self, version: Int):
        """A profile of `version` (checked when it is used, not here)."""
        self.version = version


def optimize_portable(
    var plan: LogicalPlan,
    config: OptimizerConfig,
    profile: PortableProfile,
) raises -> LogicalPlan:
    """Run the driver's pass order under the portable profile.

    The same function `optimize` runs, with an empty scalar binding table: no value is folded from an execution, and a
    plan that would need one is refused.

    Args:
        plan: The logical plan, views already resolved. Consumed.
        config: The options; read only from this argument (`eager_agg` and
            `semi_pushdown` are read by the passes).
        profile: The portable profile; its version must be
            `PORTABLE_PROFILE_V1`.

    Returns:
        The optimized logical plan.

    Raises:
        `PORTABLE_REFUSAL_UNKNOWN_PROFILE` for a profile version this build
        does not implement; `PORTABLE_REFUSAL_NEEDS_EXECUTION` with the number
        of sites when the plan needs an executed sub-plan; otherwise the first
        pass's `Error`, unchanged.
    """
    if profile.version != PORTABLE_PROFILE_V1:
        raise Error(
            PORTABLE_REFUSAL_UNKNOWN_PROFILE + ": version "
            + String(profile.version) + ", this build implements "
            + String(PORTABLE_PROFILE_V1)
        )
    var deps = ScalarDepTable()
    var out = _run_pass_order(plan^, config, deps)
    if deps.has_requests():
        raise Error(
            PORTABLE_REFUSAL_NEEDS_EXECUTION + ": "
            + String(deps.num_requests())
            + " scalar site(s) need an executed sub-plan"
        )
    return out^
