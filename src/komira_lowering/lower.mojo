# =============================================================================
# lower -- the entry: a bound plan, a host profile and the resolved inputs to a
# LoweredPlan
# =============================================================================
#
# In this order and no other:
#   1. the cutter (`cut_walk.cut_plan`): segments, edges and the ParamTable;
#   2. the morsel size of each segment from the host profile
#      (`komira_host_profile.morsel_sizing_policy.record_segment_morsel_rows`);
#   3. the purity gate: no segment carries a logical plan;
#   4. admission: every segment's sink triple is a row of the sink capability
#      table.
#
# `lower` opens no file, reads no clock and no environment variable and
# touches no global; equal arguments give a `LoweredPlan` that renders
# byte-equal.
# =============================================================================

from komira_host_profile.host_profile import HostProfile
from komira_host_profile.morsel_sizing_policy import record_segment_morsel_rows
from komira_lowering.cut_walk import cut_plan
from komira_lowering.lowered_plan import LoweredPlan, LoweringInputs
from komira_lowering.sink_capability import admit_plan
from komira_physical_plan.physical_plan import assert_physical_plan_ir_version_compatible
from komira_physical_plan.physical_plan_purity_gate import (
    assert_physical_plan_carries_no_logical_plan,
)
from komira_plan_ir.logical_plan import LogicalPlan


def lower(
    plan: LogicalPlan, host_profile: HostProfile, inputs: LoweringInputs
) raises -> LoweredPlan:
    """Lower `plan` for a host.

    Raises a named refusal (see `lowered_plan`) for a node the cutter does not
    cut, a sink the capability table does not serve, a scan the Parquet arm
    cannot carry, or inputs that do not match the plan's scans.
    """
    var cut = cut_plan(plan, inputs)
    for i in range(len(cut.segments)):
        record_segment_morsel_rows(
            host_profile, cut.segments[i], cut.flow_schemas[i]
        )
    # The gate raises when a segment carries a logical plan; the value it
    # returns on success is not needed here.
    _ = assert_physical_plan_carries_no_logical_plan(cut.segments)
    assert_physical_plan_ir_version_compatible(cut.segments)
    admit_plan(cut.segments)
    return cut^.into_lowered()
