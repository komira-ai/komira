# =============================================================================
# cut_sort -- the cutter's PLAN_SORT arm: a breaker
# =============================================================================
#
# A sort ends the open pipeline in a SINK_SORT segment (key NONE, COLUMNAR)
# whose SortSinkData is the next row of the ParamTable's `sort`, and opens a
# pipeline that reads that segment's output, marked as a sorted stream.
# =============================================================================

from lowering.cut_state import _Cutter, _Pipe
from lowering.lowered_plan import LoweringInputs
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import (
    SortSinkData,
    SINK_SORT,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def close_sort(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var pipe: _Pipe,
    inputs: LoweringInputs,
) -> _Pipe:
    """End the sort's child pipeline in its sink and open the pipeline that
    reads the sorted output."""
    ref sd = node.sort_data_ref()
    var pid = len(cutter.params.sort)
    cutter.params.sort.append(
        SortSinkData(
            sd.keys.copy(),
            sd.descending.copy(),
            0,
            sd.nulls_first.copy(),
        )
    )
    var seg = cutter._close(
        pipe^, SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, pid, inputs
    )
    var reopened = cutter._reopen(seg, node.output_schema)
    reopened.sorted_input = True
    return reopened^
