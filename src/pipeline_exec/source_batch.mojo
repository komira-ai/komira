# =============================================================================
# source_batch -- SOURCE_BATCH, a resident batch read as morsels
# =============================================================================
#
# `BatchSource` serves a batch that is already in memory, cut into morsels of
# `morsel_rows` rows that the workers claim from one shared cursor
# (`op_sources.BatchMorselSource`). The batch the plan names by handle
# stays with its owner; the source is built over a copy, because the morsel
# source consumes what it is given and a plan may read one batch twice. A
# SOURCE_JSONL segment serves the batches its file was read into the same way
# (`source_jsonl`), one cursor over all of them, and a SOURCE_ORC segment the
# batch its file was decoded into (`source_orc`).

from arrow.schema import RecordBatch, Schema
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_source import MorselSourceImpl, SourceCapabilities
from op_sources.batch_morsel_source import BatchMorselSource
from plan_stats.source_statistics import SourceStatistics


struct BatchSource(MorselSourceImpl):
    """The morsels of one resident batch, or of several read from a file."""

    var _inner: BatchMorselSource

    def __init__(out self, var batch: RecordBatch, morsel_rows: Int) raises:
        self._inner = BatchMorselSource(batch^, morsel_rows)

    def __init__(
        out self, var batches: Slab[RecordBatch], morsel_rows: Int
    ) raises:
        """The morsels of `batches`, in order; the schema is the first one's
        that has columns."""
        self._inner = BatchMorselSource(batches^, morsel_rows)

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
