# =============================================================================
# sink_agg_any -- the aggregation sinks behind one slot of the sink variant
# =============================================================================
#
# `(SINK_AGG, KEY_DTYPE_NONE, ...)` is the ungrouped `AggSink` and the rows
# keyed by a fixed-width column are the `GroupAggSink`; both are one slot of
# `PipelineSink`, which a tag chooses between here.

from komira_arrow.schema import RecordBatch
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution

from .sink_agg import AggSink
from .sink_group_agg import GroupAggSink


struct AnyAggSink(MorselSinkImpl):
    """An ungrouped or a grouped aggregation sink."""

    var _grouped: Bool
    var _plain: Optional[AggSink]
    var _keyed: Optional[GroupAggSink]

    def __init__(out self, var sink: AggSink):
        self._grouped = False
        self._plain = Optional[AggSink](sink^)
        self._keyed = Optional[GroupAggSink]()

    def __init__(out self, var sink: GroupAggSink):
        self._grouped = True
        self._plain = Optional[AggSink]()
        self._keyed = Optional[GroupAggSink](sink^)

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if self._grouped:
            self._keyed.value().consume(worker_id, morsel^)
        else:
            self._plain.value().consume(worker_id, morsel^)

    def finalize(mut self) raises:
        if self._grouped:
            self._keyed.value().finalize()
        else:
            self._plain.value().finalize()

    def resize_worker_state(mut self, num_workers: Int) -> None:
        if self._grouped:
            self._keyed.value().resize_worker_state(num_workers)
        else:
            self._plain.value().resize_worker_state(num_workers)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        if self._grouped:
            self._keyed.value().combine(pipeline)
        else:
            self._plain.value().combine(pipeline)

    def take_output(mut self) raises -> RecordBatch:
        if self._grouped:
            return self._keyed.value().take_output()
        return self._plain.value().take_output()
