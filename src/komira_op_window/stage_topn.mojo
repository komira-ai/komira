# =============================================================================
# stage_topn -- the top-N breaker over one INT64 key expression
# =============================================================================
#
# `Stage_TopN_1_I64[KeyExpr, N]` (capacity N at compile time) and
# `Stage_TopN_Dynamic_1_I64[KeyExpr]` (capacity at run time) are
# `FusedMorselOp`s: `process_batch` evaluates the key expression per row and
# pushes (key, row index) into a `topn_stage` heap; `finalize` emits a
# 2-column batch (key INT64, payload INT64 = the row's index among all rows
# fed so far, across batches), best first. Rows with equal keys come out in
# row order, so the rows and their order are those of a stable sort of the
# whole input. The direction is the scaffold's `sort_dir`.
#
# The key is an `ExprXI64`, which has no NULL channel: a NULL key is read as
# the value its expression yields for the row.
# =============================================================================

from std.collections import Optional

from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch, Schema
from komira_exec_types.process_result import ProcessResult
from komira_expr.expr_x import ExprXI64
from komira_operator_api.fused_morsel_op import FusedMorselOp
from komira_udf.column_resolver import ColumnResolver

from .bounded_heap import HeapSlot
from .topn_stage import TopNStageScaffoldI64, TopNStageScaffoldI64Dynamic


def _emit_key_payload(entries: List[HeapSlot], var schema: Schema) raises -> RecordBatch:
    """The (key, payload) batch of the drained entries, in their order."""
    var n = len(entries)
    var keys = List[Scalar[DType.int64]](capacity=n)
    var pays = List[Scalar[DType.int64]](capacity=n)
    for i in range(n):
        keys.append(entries[i].key)
        pays.append(entries[i].payload_row_id)
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(keys)),
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(pays)),
    )


struct Stage_TopN_1_I64[KeyExpr: ExprXI64, N: Int](FusedMorselOp):
    """The top-N breaker over one INT64 key expression, N at compile time.

    Fields:
        scaffold: the heap and its direction.
        output_schema: the 2-column (key, payload) schema.
    """

    var scaffold: TopNStageScaffoldI64[Self.N]
    var output_schema: Schema
    var key_expr: Self.KeyExpr
    var rows_seen: Int64

    def __init__(out self, var scaffold: TopNStageScaffoldI64[Self.N], var output_schema: Schema):
        self.scaffold = scaffold^
        self.output_schema = output_schema^
        self.key_expr = Self.KeyExpr()
        self.rows_seen = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        """Bind the key expression's columns."""
        self.key_expr.bind(resolver)

    def process_batch[bo: Origin[mut=False]](mut self, batch: BatchView[bo]) raises -> ProcessResult:
        """Push every row's key; emit nothing until `finalize`."""
        var n = batch.n_rows()
        for i in range(n):
            self.scaffold.push_row(
                self.key_expr.eval_scalar_s[bo](batch, i), self.rows_seen + Int64(i)
            )
        self.rows_seen += Int64(n)
        return ProcessResult.need_input(Optional[RecordBatch](None))

    def finalize(var self) raises -> Optional[RecordBatch]:
        """The kept (key, payload) rows, best first."""
        var entries = self.scaffold.finalize_emit()
        return Optional[RecordBatch](_emit_key_payload(entries, self.output_schema.copy()))


struct Stage_TopN_Dynamic_1_I64[KeyExpr: ExprXI64](FusedMorselOp):
    """`Stage_TopN_1_I64` with a run-time capacity."""

    var scaffold: TopNStageScaffoldI64Dynamic
    var output_schema: Schema
    var key_expr: Self.KeyExpr
    var rows_seen: Int64

    def __init__(out self, var scaffold: TopNStageScaffoldI64Dynamic, var output_schema: Schema):
        self.scaffold = scaffold^
        self.output_schema = output_schema^
        self.key_expr = Self.KeyExpr()
        self.rows_seen = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        """Bind the key expression's columns."""
        self.key_expr.bind(resolver)

    def process_batch[bo: Origin[mut=False]](mut self, batch: BatchView[bo]) raises -> ProcessResult:
        """Push every row's key; emit nothing until `finalize`."""
        var n = batch.n_rows()
        for i in range(n):
            self.scaffold.push_row(
                self.key_expr.eval_scalar_s[bo](batch, i), self.rows_seen + Int64(i)
            )
        self.rows_seen += Int64(n)
        return ProcessResult.need_input(Optional[RecordBatch](None))

    def finalize(var self) raises -> Optional[RecordBatch]:
        """The kept (key, payload) rows, best first."""
        var entries = self.scaffold.finalize_emit()
        return Optional[RecordBatch](_emit_key_payload(entries, self.output_schema.copy()))
