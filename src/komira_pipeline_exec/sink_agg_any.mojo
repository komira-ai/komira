# =============================================================================
# sink_agg_any -- the aggregation sinks behind one slot of the sink variant
# =============================================================================
#
# `(SINK_AGG, KEY_DTYPE_NONE, ...)` is the ungrouped `AggSink`, the rows keyed
# by a fixed-width column are the `GroupAggSink`, and the rows keyed by strings
# are the `StringGroupAggSink`; all are one slot of `PipelineSink`, which a tag
# chooses between here.

from komira_arrow.schema import RecordBatch
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution

from .sink_agg import AggSink
from .sink_group_agg import GroupAggSink
from .sink_string_group_agg import StringGroupAggSink

comptime _PLAIN: Int = 0
comptime _KEYED: Int = 1
comptime _STRINGS: Int = 2


struct AnyAggSink(MorselSinkImpl):
    """An ungrouped, a fixed-width keyed or a string keyed aggregation sink."""

    var _kind: Int
    var _plain: Optional[AggSink]
    var _keyed: Optional[GroupAggSink]
    var _strings: Optional[StringGroupAggSink]

    def __init__(out self, var sink: AggSink):
        self._kind = _PLAIN
        self._plain = Optional[AggSink](sink^)
        self._keyed = Optional[GroupAggSink]()
        self._strings = Optional[StringGroupAggSink]()

    def __init__(out self, var sink: GroupAggSink):
        self._kind = _KEYED
        self._plain = Optional[AggSink]()
        self._keyed = Optional[GroupAggSink](sink^)
        self._strings = Optional[StringGroupAggSink]()

    def __init__(out self, var sink: StringGroupAggSink):
        self._kind = _STRINGS
        self._plain = Optional[AggSink]()
        self._keyed = Optional[GroupAggSink]()
        self._strings = Optional[StringGroupAggSink](sink^)

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if self._kind == _KEYED:
            self._keyed.value().consume(worker_id, morsel^)
        elif self._kind == _STRINGS:
            self._strings.value().consume(worker_id, morsel^)
        else:
            self._plain.value().consume(worker_id, morsel^)

    def finalize(mut self) raises:
        if self._kind == _KEYED:
            self._keyed.value().finalize()
        elif self._kind == _STRINGS:
            self._strings.value().finalize()
        else:
            self._plain.value().finalize()

    def resize_worker_state(mut self, num_workers: Int) -> None:
        if self._kind == _KEYED:
            self._keyed.value().resize_worker_state(num_workers)
        elif self._kind == _STRINGS:
            self._strings.value().resize_worker_state(num_workers)
        else:
            self._plain.value().resize_worker_state(num_workers)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        if self._kind == _KEYED:
            self._keyed.value().combine(pipeline)
        elif self._kind == _STRINGS:
            self._strings.value().combine(pipeline)
        else:
            self._plain.value().combine(pipeline)

    def take_output(mut self) raises -> RecordBatch:
        if self._kind == _KEYED:
            return self._keyed.value().take_output()
        if self._kind == _STRINGS:
            return self._strings.value().take_output()
        return self._plain.value().take_output()
