# =============================================================================
# Order advisory -- compare a plan's join order with the reorderer's, and say
# when the written order is estimated worse
# =============================================================================
#
# `advise_join_order(author)` runs `reorder_joins_with_dp` (the inner-join
# reorderer this package ships) on a copy of `author`, then compares the two
# plans:
#
#   1. the join order: a signature of the join nesting and the leaves, `(L R)`
#      at each join and the leaf's output column names at each leaf;
#   2. the estimated intermediate rows: the sum of `estimate_cardinality`
#      over every join node.
#
# It fires when the written order sums strictly more rows; the two order
# signatures are reported, not compared. A reorder to an equal-cost order
# stays silent, so a chain that is already optimal never fires whichever
# equal-cost tree the reorderer returns. On a fire it bumps the process-global order-advisory counter
# (`komira_async.runtime.sched_trace.order_advisory_fire_inc`) and returns the
# finding; `OrderAdvisory.warning()` renders it as one line. It never prints
# and never changes the plan it is given: the caller decides whether to log
# the warning or run the reordered plan.
#
# One walk (`_walk`) collects the join count, the cost and the order
# signature of a plan in a single pass; `advise_join_order` runs it on the
# written plan and on the reordered one. It descends through Filter, Project,
# Limit, Aggregate, Sort, Distinct, PartitionBy and PartitionTopN to the joins
# below them (the reorderer reorders each inner-join subtree between such
# nodes); any other node, or a node without its payload, is a leaf.
# =============================================================================

from komira_async.runtime.sched_trace import order_advisory_fire_inc
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SORT,
)
from .optimizer_dpccp import reorder_joins_with_dp
from .optimizer_stats import estimate_cardinality


struct OrderAdvisory(Movable):
    """The advisory's finding for one plan.

    Fields:
        fired: True iff the written plan is estimated strictly costlier
            than the reordered one.
        blowup: `author_cost // max(optimal_cost, 1)` when fired (at least
            1, since the author cost is the larger); 1 when not fired.
        author_cost: estimated intermediate rows of the written plan (the
            sum of `estimate_cardinality` over its join nodes); 0 when the
            plan has no join.
        optimal_cost: the same sum over the reordered plan.
        author_order: the written plan's join-order signature ("" when the
            plan has no join).
        optimal_order: the reordered plan's signature.
    """

    var fired: Bool
    var blowup: Int
    var author_cost: Int
    var optimal_cost: Int
    var author_order: String
    var optimal_order: String

    def __init__(
        out self,
        fired: Bool,
        blowup: Int,
        author_cost: Int,
        optimal_cost: Int,
        var author_order: String,
        var optimal_order: String,
    ):
        self.fired = fired
        self.blowup = blowup
        self.author_cost = author_cost
        self.optimal_cost = optimal_cost
        self.author_order = author_order^
        self.optimal_order = optimal_order^

    def warning(self) -> String:
        """The finding as one line (meaningful when `fired`)."""
        return (
            "order advisory: author join order estimated "
            + String(self.blowup)
            + "x worse than optimal (author intermediate rows ~"
            + String(self.author_cost)
            + ", optimal ~"
            + String(self.optimal_cost)
            + "); reorder available. author="
            + self.author_order
            + " optimal="
            + self.optimal_order
        )


struct _JoinWalk(Movable):
    """What one walk of a plan collects."""

    var joins: Int
    var cost: Int
    var order: String

    def __init__(out self):
        self.joins = 0
        self.cost = 0
        self.order = String("")


def _leaf_label(plan: LogicalPlan) -> String:
    """A leaf's output column names, `[a,b]`: within a reorderable chain
    every leaf column name is unique, so this identifies the leaf across a
    reorder."""
    ref schema = plan.output_schema
    var out = String("[")
    for i in range(schema.num_columns()):
        if i > 0:
            out += ","
        out += schema.field_name(i)
    out += "]"
    return out^


def _walk(plan: LogicalPlan, mut acc: _JoinWalk):
    """Count the joins of `plan`, add each join's estimated output rows to
    `acc.cost`, and append its join-order signature to `acc.order`."""
    if plan.tag == PLAN_JOIN and plan._join:
        ref jd = plan.join_data_ref()
        acc.joins += 1
        acc.cost += estimate_cardinality(plan)
        acc.order += "("
        _walk(jd.left[], acc)
        acc.order += " "
        _walk(jd.right[], acc)
        acc.order += ")"
    elif plan.tag == PLAN_FILTER and plan._filter:
        _walk(plan.filter_data_ref().child[], acc)
    elif plan.tag == PLAN_PROJECT and plan._project:
        _walk(plan.project_data_ref().child[], acc)
    elif plan.tag == PLAN_LIMIT and plan._limit:
        _walk(plan.limit_data_ref().child[], acc)
    elif plan.tag == PLAN_AGGREGATE and plan._aggregate:
        _walk(plan.aggregate_data_ref().child[], acc)
    elif plan.tag == PLAN_SORT and plan._sort:
        _walk(plan.sort_data_ref().child[], acc)
    elif plan.tag == PLAN_DISTINCT and plan._distinct:
        _walk(plan.distinct_data_ref().child[], acc)
    elif plan.tag == PLAN_PARTITION_BY and plan._partition_by:
        _walk(plan.partition_by_data_ref().child[], acc)
    elif plan.tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        _walk(plan.partition_topn_data_ref().child[], acc)
    else:
        acc.order += _leaf_label(plan)


def advise_join_order(author: LogicalPlan) raises -> OrderAdvisory:
    """Reorder a copy of `author` and report whether its written join order
    is estimated worse (see the module header). A plan without a join is
    not reordered: the finding is silent with zero costs and empty orders.
    """
    var written = _JoinWalk()
    _walk(author, written)
    if written.joins < 1:
        return OrderAdvisory(False, 1, 0, 0, String(""), String(""))

    var reordered = reorder_joins_with_dp(author.copy())
    var best = _JoinWalk()
    _walk(reordered, best)

    var fired = written.cost > best.cost
    var blowup = 1
    if fired:
        # written.cost > best.cost >= 0, so the quotient is at least 1.
        blowup = written.cost // max(best.cost, 1)
        order_advisory_fire_inc()
    return OrderAdvisory(
        fired, blowup, written.cost, best.cost,
        written.order.copy(), best.order.copy(),
    )
