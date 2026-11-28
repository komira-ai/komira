# =============================================================================
# lowered_plan -- the values `lower` takes and returns, and its refusal tokens
# =============================================================================
#
# `LoweringInputs` holds what the host read from the data before lowering (one
# `ScanFacts` per scan, in scan pre-order) and the `UdfRef` list the plan names
# its user functions by. `LoweredPlan` is the result: the segments in
# dependency order, the `ParamTable` their `sink_param_id`,
# `source_spec.batch_handle_id` and user-function calls index, and the id of
# the segment whose output is the query's result.
# =============================================================================

from physical_plan.iceberg_scan_spec import IcebergScanSpec
from physical_plan.physical_plan import (
    SegmentDescPod,
    AggSinkData,
    SortSinkData,
    TopNSinkData,
    PartitionBySinkData,
    PartitionTopNSinkData,
)
from containers.slab import Slab
from plan_ir.udf_ref import UdfRef
from plan_stats.table_stats import TableStats
from scan_source.in_memory_source import InMemorySource


comptime LOWERING_UNCUTTABLE_NODE = "LOWERING_UNCUTTABLE_NODE"
"""Refusal: the plan holds a node, or a node shape, the cutter does not cut."""

comptime LOWERING_SINK_UNSERVED = "LOWERING_SINK_UNSERVED"
"""Refusal: a segment's sink triple has no row in the sink capability table."""

comptime LOWERING_SCAN_NOT_TOTAL = "LOWERING_SCAN_NOT_TOTAL"
"""Refusal: a Parquet scan carries a field the segment's Parquet arm cannot."""

comptime LOWERING_INPUTS_SCAN_COUNT = "LOWERING_INPUTS_SCAN_COUNT"
"""Refusal: `LoweringInputs` does not hold exactly one entry per scan."""

comptime LOWERING_JOIN_UNSERVED = "LOWERING_JOIN_UNSERVED"
"""Refusal: a join the hash join does not serve (a join type the IR does not
define, a SEMI or ANTI join that builds its left side, a CROSS join with a key,
its keys, key types, residual, algorithm hint, build side or output names)."""

comptime LOWERING_WINDOW_UNSERVED = "LOWERING_WINDOW_UNSERVED"
"""Refusal: a window node the window sink does not serve (a key or argument
type, a function's arguments, a frame, or a column that is not the child's)."""

comptime LOWERING_UDF_UNDECLARED_READ = "LOWERING_UDF_UNDECLARED_READ"
"""Refusal: a user function would receive a column its read set does not
declare (a ROW call's argument, a frame's group key), or a ROW or frame
function declares no read set."""

comptime LOWERING_UDF_UNSERVED = "LOWERING_UDF_UNSERVED"
"""Refusal: a user-function call the cutter does not cut (an index with no
`UdfRef`, a kind its node or call cannot take, an argument count, a read set
naming a column its input lacks or holds twice, a grouped frame, a call
inside a larger expression, a filter or an aggregation)."""


@fieldwise_init
struct ScanFacts(Copyable, Movable):
    """What the host read about one scan before lowering."""

    var stats: Optional[TableStats]
    """The statistics of the scan's verified footers, or None."""
    var dict_encoded_columns: List[String]
    """The scan's columns that every row group of every pinned file stores
    dictionary encoded. A column not listed is lowered as by-value."""
    var iceberg: Optional[IcebergScanSpec]
    """An Iceberg table scan only: the files the host planned for it (the
    data files that survive pruning and the delete files that apply). None for
    every other scan, and for an Iceberg scan the host did not plan, which the
    cutter refuses."""


struct LoweringInputs(Copyable, Movable):
    """The resolved inputs of one `lower` call: one `ScanFacts` per scan of the
    plan, in scan pre-order (a node before its children), and the plan's
    `UdfRef` list. A shared-subplan reference is a leaf with no scan: the
    scans of the subplan it names are counted once, where its canonical
    subtree stands."""

    var scans: List[ScanFacts]
    var udfs: Slab[UdfRef]
    """The list the plan's user-function nodes and calls name by index
    (`udf_ref`): an optimized plan's `DeclaredNeeds.udfs`, in that order.
    Empty for a plan that calls none."""

    def __init__(out self):
        self.scans = List[ScanFacts]()
        self.udfs = Slab[UdfRef]()

    def __init__(out self, *, copy: Self):
        self.scans = copy.scans.copy()
        self.udfs = _copy_udfs(copy.udfs)

    def add_udf(mut self, var udf: UdfRef):
        """Append the next entry of the plan's `UdfRef` list."""
        self.udfs.append(udf^)

    def add_scan(
        mut self,
        var stats: Optional[TableStats] = None,
        var dict_encoded_columns: List[String] = List[String](),
    ):
        """Append the facts of the next scan."""
        self.scans.append(ScanFacts(stats^, dict_encoded_columns^, None))

    def add_iceberg_scan(
        mut self,
        var spec: IcebergScanSpec,
        var stats: Optional[TableStats] = None,
    ):
        """Append the facts of the next scan, an Iceberg table scan whose files
        the host planned into `spec`."""
        self.scans.append(
            ScanFacts(
                stats^,
                List[String](),
                Optional[IcebergScanSpec](spec^),
            )
        )


struct ParamTable(Movable):
    """The parameters the segments index. Each list is dense and follows the
    cut order, so equal inputs give equal indices.

    `SINK_AGG` segments index `agg` by `sink_param_id`, `SINK_SORT` segments
    index `sort`, `SINK_TOPN` segments index `topn`, `SINK_PARTITION_BY`
    segments index `window`, `SINK_PARTITION_TOPN` segments index
    `partition_topn`; a `SINK_COLLECT` or `SINK_HASH_BUILD` segment
    indexes nothing (`sink_param_id` is -1): a join's keys are on its
    OP_JOIN_PROBE. `SOURCE_BATCH` segments index `batches` by
    `source_spec.batch_handle_id`. Every user-function call (an
    OP_UDF_APPLY, an OP_UDF_FRAME, a SOURCE_UDF_STEP) indexes `udfs` by its
    `udf_index`: the inputs' `UdfRef` list, whole and in its order.
    """

    var agg: List[AggSinkData]
    var sort: List[SortSinkData]
    var topn: List[TopNSinkData]
    var window: List[PartitionBySinkData]
    var partition_topn: List[PartitionTopNSinkData]
    var batches: List[InMemorySource]
    var udfs: Slab[UdfRef]

    def __init__(out self):
        self.agg = List[AggSinkData]()
        self.sort = List[SortSinkData]()
        self.topn = List[TopNSinkData]()
        self.window = List[PartitionBySinkData]()
        self.partition_topn = List[PartitionTopNSinkData]()
        self.batches = List[InMemorySource]()
        self.udfs = Slab[UdfRef]()


struct LoweredPlan(Movable):
    """The result of `lower`: a value, with nothing a segment needs held
    outside it."""

    var segments: List[SegmentDescPod]
    """In dependency order: a segment's `deps` all come before it. A segment's
    id is its index."""
    var params: ParamTable
    var result_seg_id: Int
    """The segment whose output is the query's result."""

    def __init__(
        out self,
        var segments: List[SegmentDescPod],
        var params: ParamTable,
        result_seg_id: Int,
    ):
        self.segments = segments^
        self.params = params^
        self.result_seg_id = result_seg_id


def _copy_udfs(udfs: Slab[UdfRef]) -> Slab[UdfRef]:
    """A deep copy of a `UdfRef` list, in its order."""
    var out = Slab[UdfRef]()
    for i in range(len(udfs)):
        out.append(udfs[i].copy())
    return out^
