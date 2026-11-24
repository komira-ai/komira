# =============================================================================
# cut_step -- the cutter's PLAN_STEP arm: a source
# =============================================================================
#
# A step (a STEP function, run once per run with literal arguments) opens a
# pipeline whose source is SOURCE_UDF_STEP: the call, its literals and the
# names of its output columns, the node's schema. A step is not a scan: it
# takes no `ScanFacts` and its pipeline has no row estimate. A function of
# another kind, or a literal count other than the function's declared
# argument count, is refused with LOWERING_UDF_UNSERVED (`udf_check`).
# =============================================================================

from lowering.cut_state import _Pipe
from lowering.lowered_plan import LoweringInputs
from lowering.udf_check import _step_call_spec
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import SourceSpecPod, SOURCE_UDF_STEP


def _open_step(node: LogicalPlan, inputs: LoweringInputs) raises -> _Pipe:
    """The pipeline a PLAN_STEP node opens, or its refusal."""
    return _Pipe(
        SOURCE_UDF_STEP,
        SourceSpecPod.step(_step_call_spec(node, inputs)),
        node.output_schema.copy(),
        -1,
    )
