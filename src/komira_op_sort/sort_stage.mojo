# =============================================================================
# sort_stage -- Stage_Sort, the sort breaker as a fused morsel operator
# =============================================================================
#
# `Stage_Sort[KB, *Payloads]` owns a `SortBuffer[KB, *Payloads]` whose key and
# payload columns are bound to input columns at compile time (each column
# type's `col` parameter). `process_batch` feeds every row of the batch into
# the buffer (no per-row expression evaluation) and emits nothing; `finalize`
# drains the buffer in sorted order. The per-key directions are the buffer's
# (`SortBuffer.set_direction`, or the `make_sort_buffer_*` factories).
# =============================================================================

from std.collections import Optional

from komira_arrow.batch_view import BatchView
from komira_arrow.schema import RecordBatch, Schema
from komira_exec_types.process_result import ProcessResult
from komira_operator_api.fused_morsel_op import FusedMorselOp
from komira_udf.column_resolver import ColumnResolver

from .sort_stage_buffer import SortBuffer, SortKeyBlockTrait
from .sort_stage_payloads import PayloadColumn


struct Stage_Sort[KB: SortKeyBlockTrait, *Payloads: PayloadColumn](
    FusedMorselOp
):
    """The sort breaker over a `SortBuffer[KB, *Payloads]`.

    Fields:
        buffer: the sort buffer (key block, payload pack, directions).
        output_schema: the drain's schema (keys then payloads, native DType).
    """

    var buffer: SortBuffer[Self.KB, *Self.Payloads]
    var output_schema: Schema

    def __init__(
        out self,
        var buffer: SortBuffer[Self.KB, *Self.Payloads],
        var output_schema: Schema,
    ):
        self.buffer = buffer^
        self.output_schema = output_schema^

    def bind(mut self, resolver: ColumnResolver) raises:
        """No-op: the columns are bound at compile time (`col`); there is no
        expression to bind."""
        pass

    def process_batch[
        bo: Origin[mut=False],
    ](
        mut self,
        batch: BatchView[bo],
    ) raises -> ProcessResult:
        """Feed every row; emit nothing (the sorted frame comes from
        `finalize`)."""
        var n = batch.n_rows()
        var i = 0
        while i < n:
            self.buffer.feed_row[bo](batch, i)
            i = i + 1
        return ProcessResult.need_input(Optional[RecordBatch](None))

    def finalize(var self) raises -> Optional[RecordBatch]:
        """Drain the buffer: the keys and payloads, sorted by the buffer's
        per-key directions."""
        return self.buffer.drain_to_record_batch()
