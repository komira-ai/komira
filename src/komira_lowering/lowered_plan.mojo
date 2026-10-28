# =============================================================================
# lowered_plan -- the values `lower` takes and returns, and its refusal tokens
# =============================================================================
#
# `LoweringInputs` holds what the host read from the data before lowering (one
# `ScanFacts` per scan, in scan pre-order). `LoweredPlan` is the result: the
# segments in dependency order, the `ParamTable` their `sink_param_id` and
# `source_spec.batch_handle_id` index, and the id of the segment whose output
# is the query's result.
# =============================================================================

from komira_physical_plan.physical_plan import (
    SegmentDescPod,
    AggSinkData,
    SortSinkData,
)
from komira_plan_stats.table_stats import TableStats
from komira_scan_source.in_memory_source import InMemorySource


comptime LOWERING_UNCUTTABLE_NODE = "LOWERING_UNCUTTABLE_NODE"
"""Refusal: the plan holds a node, or a node shape, the cutter does not cut."""

comptime LOWERING_SINK_UNSERVED = "LOWERING_SINK_UNSERVED"
"""Refusal: a segment's sink triple has no row in the sink capability table."""

comptime LOWERING_SCAN_NOT_TOTAL = "LOWERING_SCAN_NOT_TOTAL"
"""Refusal: a Parquet scan carries a field the segment's Parquet arm cannot."""

comptime LOWERING_INPUTS_SCAN_COUNT = "LOWERING_INPUTS_SCAN_COUNT"
"""Refusal: `LoweringInputs` does not hold exactly one entry per scan."""


@fieldwise_init
struct ScanFacts(Copyable, Movable):
    """What the host read about one scan before lowering."""

    var stats: Optional[TableStats]
    """The statistics of the scan's verified footers, or None."""
    var dict_encoded_columns: List[String]
    """The scan's columns that every row group of every pinned file stores
    dictionary encoded. A column not listed is lowered as by-value."""


struct LoweringInputs(Copyable, Movable):
    """The resolved inputs of one `lower` call: one `ScanFacts` per scan of the
    plan, in scan pre-order (a node before its children)."""

    var scans: List[ScanFacts]

    def __init__(out self):
        self.scans = List[ScanFacts]()

    def add_scan(
        mut self,
        var stats: Optional[TableStats] = None,
        var dict_encoded_columns: List[String] = List[String](),
    ):
        """Append the facts of the next scan."""
        self.scans.append(ScanFacts(stats^, dict_encoded_columns^))


struct ParamTable(Movable):
    """The parameters the segments index. Each list is dense and follows the
    cut order, so equal inputs give equal indices.

    `SINK_AGG` segments index `agg` by `sink_param_id`, `SINK_SORT` segments
    index `sort`; a `SINK_COLLECT` segment indexes nothing (`sink_param_id` is
    -1). `SOURCE_BATCH` segments index `batches` by
    `source_spec.batch_handle_id`.
    """

    var agg: List[AggSinkData]
    var sort: List[SortSinkData]
    var batches: List[InMemorySource]

    def __init__(out self):
        self.agg = List[AggSinkData]()
        self.sort = List[SortSinkData]()
        self.batches = List[InMemorySource]()


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
