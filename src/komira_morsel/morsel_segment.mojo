# =============================================================================
# morsel_segment -- DEPRECATED back-compat shim
# =============================================================================
#
# As of RFC v3.1 chunk 1, the PhysicalPlan IR types previously defined in
# this module have been LIFTED into `komira_physical_plan.physical_plan`.
# This file remains as a transitional re-export shim so that callers that
# still spell the old import path keep compiling. New code MUST import
# from `komira_physical_plan.physical_plan` directly.
#
# Removal: this shim is scheduled to be deleted in RFC v3.1 chunk 5
# alongside the rename of `MorselSegment` -> `PhysicalPlanFragment` /
# `CompiledFragment` -> `PhysicalPlan`. In-tree callers were migrated as
# part of chunk 1; the shim covers any out-of-tree consumers and any
# callers we missed during the mechanical sweep.
#
# Reference: an internal doc §6.1, §8 chunk 1.
# =============================================================================

from komira_physical_plan.physical_plan import (
    # Tag constants
    SOURCE_PARQUET,
    SOURCE_BATCH,
    SOURCE_SINK_OUTPUT,
    OP_FILTER,
    OP_PROJECT,
    OP_LIMIT,
    OP_JOIN_PROBE,
    SINK_AGG,
    SINK_SORT,
    SINK_TOPN,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_PARTITION_BY,
    SINK_PARTITION_TOPN,
    SINK_SMJ_BUILD,
    SINK_ASOF_JOIN,
    # IR variant data
    ParquetSourceData,
    AggSinkData,
    SortSinkData,
    TopNSinkData,
    PartitionBySinkData,
    PartitionTopNSinkData,
    AsofJoinSinkData,
    HashBuildSinkData,
    SMJBuildSinkData,
    # Tagged unions + container
    MorselOp,
)
