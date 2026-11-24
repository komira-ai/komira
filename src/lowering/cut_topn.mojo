# =============================================================================
# cut_topn -- a range of a sort's order as a breaker: SINK_TOPN
# =============================================================================
#
# A PLAN_TOPN, and a PLAN_SORT read by a chain of limits (`cut_limit`), end
# the sort's child pipeline in a SINK_TOPN segment (key NONE, COLUMNAR) whose
# TopNSinkData is the next row of the ParamTable's `topn`: the sort's keys,
# directions and NULL placements, and the range it keeps as `n` rows after
# `offset`. The pipeline that reads that segment's output is opened and marked
# as a sorted stream, as after a full sort.
#
# A PLAN_TOPN with a negative count is refused (LOWERING_UNCUTTABLE_NODE)
# before its child is walked.
# =============================================================================

from arrow.schema import Schema
from lowering.cut_limit import RowRange
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import LoweringInputs
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import (
    TopNSinkData,
    SINK_TOPN,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def _check_topn(node: LogicalPlan) raises:
    """Refuse a PLAN_TOPN whose count is negative."""
    if node.topn_data_ref().n < 0:
        raise _uncuttable(node, "a top-n with a negative count")


def _close_topn(
    mut cutter: _Cutter,
    var keys: List[String],
    var descending: List[Bool],
    var nulls_first: List[Bool],
    rows: RowRange,
    var pipe: _Pipe,
    output_schema: Schema,
    inputs: LoweringInputs,
) -> _Pipe:
    """End the sort's child pipeline in a SINK_TOPN keeping `rows` of the
    order, and open the pipeline that reads them."""
    var pid = len(cutter.params.topn)
    cutter.params.topn.append(
        TopNSinkData(
            keys^, descending^, rows.count, nulls_first^, offset=rows.start
        )
    )
    var seg = cutter._close(
        pipe^, SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, pid, inputs
    )
    var reopened = cutter._reopen(seg, output_schema)
    reopened.sorted_input = True
    return reopened^
