# =============================================================================
# source_sink_output -- SOURCE_SINK_OUTPUT, a finished segment's output
# =============================================================================
#
# A breaker ends a pipeline and starts one whose source is the breaker's
# output. `SinkOutputSource` serves the batch a finished producer segment
# published (`PublishedOutputs`), cut into morsels of `morsel_rows` rows that
# the workers claim from one shared cursor. The batch is moved in, not copied:
# it is this reader's own, the producer's output itself for its last reader
# and a copy for every other (`PublishedOutputs.take`).

from arrow.schema import RecordBatch, Schema
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from op_sources.batch_morsel_source import BatchMorselSource
from plan_stats.source_statistics import SourceStatistics


struct SinkOutputSource(MorselSourceImpl):
    """The morsels of the output of one finished segment."""

    var _inner: BatchMorselSource
    var _producer: Int

    def __init__(
        out self, var output: RecordBatch, producer: Int, morsel_rows: Int
    ) raises:
        self._inner = BatchMorselSource(output^, morsel_rows)
        self._producer = producer

    def producer(self) -> Int:
        """The segment whose output this source reads."""
        return self._producer

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        return self._inner.next_morsel(worker_id)

    def output_schema(self) -> Schema:
        return self._inner.output_schema()

    def partition_hint(self) -> Int:
        return self._inner.partition_hint()

    def row_count_hint(self) -> Int:
        return self._inner.row_count_hint()

    def capabilities(self) -> SourceCapabilities:
        return self._inner.capabilities()

    def statistics(self) -> SourceStatistics:
        return self._inner.statistics()
