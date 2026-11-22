# =============================================================================
# engine_lower -- LoweringInputs from the context's footers, and the lowering call
# =============================================================================
#
# `lowering_inputs` walks the (optimized) plan in the order the cutter does and
# appends one scan's facts per scan from `ctx.footers`, the same cache the
# binder read, so the plan the binder saw and the plan that is lowered read one
# version of each file. A scan of a file registered on the context is checked
# against its registered schema (`add_catalog_table_scan`), for the files the scan holds only (a subset of
# the table's files after partition pruning); any other Parquet scan reads the
# facts of each of its files (`add_parquet_files_scan`). A node the cutter does
# not cut is not descended into: the cutter refuses it by name before it asks
# for any scan below, so no facts are read for a plan that cannot lower.

from host_profile.host_profile import HostProfile
from lowering.lower import lower
from lowering.lowered_plan import LoweredPlan, LoweringInputs
from parquet_footers.lowering_facts import (
    add_catalog_table_scan,
    add_parquet_files_scan,
)
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    PLAN_UNION,
)
from scan_source.source_variant import (
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_PARQUET,
)

from .engine_context import EngineContext


def _table_of_paths(ps_paths: List[String], ctx: EngineContext) raises -> String:
    """The name of a registered table whose files include every path of a scan,
    or the empty string. The optimizer's partition pruning can leave a subset
    of a table's files, so a scan of some of them is still that table's scan."""
    for i in range(len(ctx.tables)):
        var t = ctx.catalog.table_of(ctx.tables[i].name)
        ref table_paths = t.source._parquet.value().paths
        var all_in = True
        for p in range(len(ps_paths)):
            var found = False
            for q in range(len(table_paths)):
                if table_paths[q] == ps_paths[p]:
                    found = True
                    break
            if not found:
                all_in = False
                break
        if all_in:
            return String(ctx.tables[i].name)
    return String("")


def _add_scan_facts(
    mut inputs: LoweringInputs, node: LogicalPlan, ctx: EngineContext
) raises:
    ref sd = node.scan_data_ref()
    if sd.source.tag == SOURCE_VARIANT_PARQUET:
        ref ps = sd.source._parquet.value()
        var table = _table_of_paths(ps.paths, ctx)
        if table.byte_length() > 0:
            add_catalog_table_scan(inputs, ctx.catalog, table, ctx.footers, ps)
        else:
            add_parquet_files_scan(inputs, ctx.footers, ps)
        return
    # An in-memory or CSV scan: no facts here; the cutter serves both.
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
    elif tag == PLAN_DISTINCT:
        _collect(inputs, node.distinct_data_ref().child[], ctx)
    elif tag == PLAN_SORT:
        _collect(inputs, node.sort_data_ref().child[], ctx)
    elif tag == PLAN_TOPN:
        _collect(inputs, node.topn_data_ref().child[], ctx)
    elif tag == PLAN_UNION:
        # Branch order is the cutter's order.
        ref ud = node.union_data_ref()
        for i in range(len(ud.children)):
            _collect(inputs, ud.children[i][], ctx)


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
