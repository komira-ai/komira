# =============================================================================
# engine_lower -- LoweringInputs from the context's footers, and the lowering call
# =============================================================================
#
# `lowering_inputs` walks the (optimized) plan in the order the cutter does and
# appends one scan's facts per scan from `ctx.footers`, the same cache the
# binder read, so the plan the binder saw and the plan that is lowered read one
# version of each file. A scan of a file registered on the context is checked
# against its registered schema (`add_catalog_scan`). A node the cutter does
# not cut is not descended into: the cutter refuses it by name before it asks
# for any scan below, so no facts are read for a plan that cannot lower.

from komira_host_profile.host_profile import HostProfile
from komira_lowering.lower import lower
from komira_lowering.lowered_plan import LoweredPlan, LoweringInputs
from komira_parquet_footers.lowering_facts import (
    add_catalog_scan,
    add_parquet_scan,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
)
from komira_scan_source.source_variant import (
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_PARQUET,
)

from .engine_context import EngineContext


def _add_scan_facts(
    mut inputs: LoweringInputs, node: LogicalPlan, ctx: EngineContext
) raises:
    ref sd = node.scan_data_ref()
    if sd.source.tag == SOURCE_VARIANT_PARQUET:
        ref ps = sd.source._parquet.value()
        if len(ps.paths) == 1:
            var path = String(ps.paths[0])
            for i in range(len(ctx.tables)):
                if ctx.tables[i].path == path:
                    add_catalog_scan(
                        inputs, ctx.catalog, ctx.tables[i].name, ctx.footers
                    )
                    return
            add_parquet_scan(inputs, ctx.footers, path, node.output_schema)
            return
    # An in-memory scan, or a Parquet scan of several files: no facts here;
    # the cutter serves the first and refuses the second by name.
    inputs.add_scan()


def _collect(
    mut inputs: LoweringInputs, node: LogicalPlan, ctx: EngineContext
) raises:
    var tag = node.tag
    if tag == PLAN_SCAN:
        _add_scan_facts(inputs, node, ctx)
    elif tag == PLAN_FILTER:
        _collect(inputs, node.filter_data_ref().child[], ctx)
    elif tag == PLAN_PROJECT:
        _collect(inputs, node.project_data_ref().child[], ctx)
    elif tag == PLAN_LIMIT:
        _collect(inputs, node.limit_data_ref().child[], ctx)
    elif tag == PLAN_AGGREGATE:
        _collect(inputs, node.aggregate_data_ref().child[], ctx)
    elif tag == PLAN_SORT:
        _collect(inputs, node.sort_data_ref().child[], ctx)


def lowering_inputs(
    plan: LogicalPlan, ctx: EngineContext
) raises -> LoweringInputs:
    """The facts of every scan of `plan`, in scan pre-order, from `ctx.footers`.

    Raises:
        Error naming the file when a footer does not read or the file was
        replaced since its footer was read, and naming the table, file and
        column when a registered schema disagrees with the file.
    """
    var inputs = LoweringInputs()
    _collect(inputs, plan, ctx)
    return inputs^


def lower_for_context(
    plan: LogicalPlan, ctx: EngineContext
) raises -> LoweredPlan:
    """`lower(plan, ctx.host_profile, inputs)`, with the inputs built from the
    context's footers."""
    var inputs = lowering_inputs(plan, ctx)
    return lower(plan, ctx.host_profile, inputs)
