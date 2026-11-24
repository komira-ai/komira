# =============================================================================
# cut_limit -- the cutter's PLAN_LIMIT arm: a streaming operator, or a range
# of a sort's output
# =============================================================================
#
# A limit that reaches a PLAN_SORT or a PLAN_TOPN through nothing but
# projections and other limits keeps a range of that sort's order: rows
# [offset, offset + n). The range is not an operator. The cutter walks the
# sort's child, ends it in a SINK_TOPN segment that keeps exactly those rows
# (`cut_topn`), and fuses the projections that stood between the limit and the
# sort onto the pipeline that reads it, bottom up. Every limit of the chain is
# folded into the one range, the innermost applied first: a limit (n, offset)
# over a range (start, count) keeps the range (start + offset,
# min(n, count - offset)), at least zero rows. A projection keeps every row,
# so it does not change the range.
#
# Any other limit is fused onto the open pipeline as an OP_LIMIT of its count.
#
# Refused (LOWERING_UNCUTTABLE_NODE), before the child is walked: a limit with
# a negative count or a negative offset, and a limit with an offset that does
# not reach a sort (the rows it would skip are in no stated order). Refused
# after the child is walked: a limit over a sorted stream that is not such a
# chain (a filter stands between it and the sort, or it reads a shared sort
# through a reference), and a chain one of whose nodes below the limit is a
# shared subplan other readers read whole (`cut_walk._range_holds_shared`): a
# segment records no order, so the rows the limit would keep are not defined.
# =============================================================================

from lowering.cut_state import _Pipe, _uncuttable
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SORT,
    PLAN_TOPN,
)
from physical_plan.physical_plan import MorselOp


comptime ROWS_UNBOUNDED: Int = Int.MAX
"""The count of a range with no upper bound."""


@fieldwise_init
struct RowRange(Copyable, Movable):
    """Rows [start, start + count) of a sort's order. `count` is
    `ROWS_UNBOUNDED` for every row from `start` on."""

    var start: Int
    var count: Int

    @staticmethod
    def every_row() -> RowRange:
        return RowRange(0, ROWS_UNBOUNDED)

    def under_limit(self, n: Int, offset: Int) -> RowRange:
        """The range a limit of `n` rows after `offset` keeps when it reads
        the rows of a node that keeps `self`'s range: this range is applied to
        the limit's output, the limit to the node's. Both arguments are at
        least zero."""
        var start = _saturating_add(offset, self.start)
        var room = n - self.start
        if room < 0:
            room = 0
        return RowRange(start, min(self.count, room))


def _saturating_add(a: Int, b: Int) -> Int:
    """`a + b` for `a, b >= 0`, `ROWS_UNBOUNDED` where the sum would not fit."""
    if a > ROWS_UNBOUNDED - b:
        return ROWS_UNBOUNDED
    return a + b


def _check_limit(node: LogicalPlan) raises:
    """Refuse a limit whose count or offset is negative."""
    ref ld = node.limit_data_ref()
    if ld.n < 0:
        raise _uncuttable(node, "a limit with a negative count")
    if ld.offset < 0:
        raise _uncuttable(node, "a limit with a negative offset")


def _reaches_sort(node: LogicalPlan) -> Bool:
    """True when `node`, a limit, reads a PLAN_SORT or a PLAN_TOPN through
    nothing but projections without a UDF and other limits."""
    if node.tag == PLAN_SORT or node.tag == PLAN_TOPN:
        return True
    if node.tag == PLAN_LIMIT:
        return _reaches_sort(node.limit_data_ref().child[])
    if node.tag == PLAN_PROJECT:
        if node.project_data_ref().has_udf():
            return False
        return _reaches_sort(node.project_data_ref().child[])
    return False


def _limit_op(node: LogicalPlan) raises -> MorselOp:
    """The operator a PLAN_LIMIT node that does not reach a sort fuses, or
    its refusal. Called before the child is walked."""
    _check_limit(node)
    ref ld = node.limit_data_ref()
    if ld.offset != 0:
        raise _uncuttable(
            node,
            "a limit with an offset over rows in no stated order; only a"
            " sort's output can skip rows",
        )
    return MorselOp.limit(ld.n)


def _sorted_stream_refusal(node: LogicalPlan) -> Error:
    """The refusal of limit `node` over a sorted stream it cannot keep a
    range of."""
    return _uncuttable(
        node,
        "a limit over a sorted stream that is not one range of its sort (a"
        " filter or a shared subplan stands between them); no order is"
        " recorded on a segment",
    )


def _fuse_limit(mut pipe: _Pipe, node: LogicalPlan, var op: MorselOp) raises:
    """Fuse the limit's operator onto its child's pipeline, or refuse a limit
    over a sorted stream."""
    if pipe.sorted_input:
        raise _sorted_stream_refusal(node)
    pipe.append_op(op^)
