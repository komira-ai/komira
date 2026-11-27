# =============================================================================
# op_udf_apply -- OP_UDF_APPLY: one column-kind UDF call, appended as a column
# =============================================================================
#
# Lowering cuts a projection column that is wholly a UDF call into an
# OP_UDF_APPLY ahead of the projection (`lowering.cut_project`): the op
# evaluates the call's argument expressions over the batch, calls the UDF the
# plan's UdfRef list names at `UdfCallSpec.udf_index`, and appends its answer
# as the column `UdfCallSpec.out_names[0]` (`__udf_apply:<i>`), every input
# column kept; the OP_PROJECT after it reads that column by name.
#
# The call runs on the UDF runtime of the run's `UdfBinding`
# (`udf_host.runtime`): each worker's operator opens its own context and
# instance in it (`udf_host.instance.UdfInstance`, slot = the worker's
# number) on its first batch with rows, and closes them when it is dropped,
# at the end of the segment run. What the call owes the UDF and checks of
# it (NULL propagation, the row ceiling, the per-batch deadline, the
# post-conditions, the error table) is the instance's.
#
# A batch still carrying an unapplied selection mask is made dense first: a
# UDF observes every row it is given, so it must be given only the selected
# ones. A batch of no rows is passed on without a call.
#
# Served kinds: SCALAR and MAP_BATCHES_COLUMN (the binding refused any other
# before the run started). A ROW call is refused here by name, before any
# worker starts.
# =============================================================================

from std.builtin.swap import swap
from std.memory import ArcPointer, OwnedPointer
from std.time import perf_counter_ns

from arrow.column import Column
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from batch_eval.eval_column import _eval_column_expr
from byte_buffer.heap_region import HeapRegion
from column_kernels.compiler_helpers import (
    empty_batch_like_schema,
    materialize_selection_if_present,
)
from exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from metrics.metrics_set import MetricsSet, MetricsSnapshot, new_owned_metrics_set
from morsel.morsel import Morsel
from morsel.morsel_operator import MorselOperatorImpl
from physical_plan.physical_plan import MorselOp, OP_UDF_APPLY
from plan_expr.expr_id import ExprId
from plan_expr.expr_pool import ExprPool
from plan_expr.udf_data import UDF_NULL_MANUAL
from plan_ir.udf_ref import UDF_REF_KIND_ROW
from udf_host.instance import UdfInstance
from udf_host.runtime import UdfBinding, result_field

comptime PIPELINE_UDF_UNBOUND = "PIPELINE_UDF_UNBOUND"
"""Refusal: an OP_UDF_APPLY names a UDF the run's binding does not hold."""


def udf_output_field(ref binding: UdfBinding, udf_index: Int, name: String) -> Field:
    """The field an OP_UDF_APPLY appends: `name` and the UDF's return type,
    nullable as the type says, and nullable whatever it says under
    NULL_PROPAGATE, whose NULL rows the host fills with NULL."""
    ref u = binding.ref_at(udf_index)
    var f = result_field(u)
    f.name = name
    if u.null_mode != UDF_NULL_MANUAL:
        f.nullable = True
    return f^


struct UdfApplyShared(Movable):
    """What the per-worker operators of one OP_UDF_APPLY share: the
    registered argument expressions, the UDF's index and the output's
    field, and the run's binding."""

    var _pool: ArcPointer[ExprPool]
    var _ids: List[ExprId]
    var _udf_index: Int
    var _field: Field
    var _binding: ArcPointer[UdfBinding]

    def __init__(out self, ref spec: MorselOp, binding: ArcPointer[UdfBinding]) raises:
        if spec.tag != OP_UDF_APPLY or not spec.udf:
            raise Error("pipeline_exec: an OP_UDF_APPLY carries no UDF call")
        ref call = spec.udf.value()
        if call.udf_index < 0 or call.udf_index >= binding[].count():
            raise Error(
                String(PIPELINE_UDF_UNBOUND) + ": an OP_UDF_APPLY calls UDF " + String(call.udf_index)
                + ", and the run binds " + String(binding[].count())
            )
        if call.kind == UDF_REF_KIND_ROW:
            raise Error(
                String(PIPELINE_UDF_UNBOUND) + ": " + binding[].name_of(call.udf_index)
                + " is a ROW call, which no operator serves yet"
            )
        if len(call.out_names) != 1:
            raise Error(
                "pipeline_exec: an OP_UDF_APPLY names " + String(len(call.out_names))
                + " output columns, not one"
            )
        var pool = ExprPool()
        var ids = List[ExprId]()
        for i in range(len(call.args)):
            ids.append(pool.register(call.args[i].copy()))
        self._pool = ArcPointer[ExprPool](pool^)
        self._ids = ids^
        self._udf_index = call.udf_index
        self._field = udf_output_field(binding[], call.udf_index, call.out_names[0])
        self._binding = binding

    def output_field(self) -> Field:
        return self._field.copy()

    def make(self, worker_id: Int) raises -> UdfApplyOp:
        """The operator of worker `worker_id`."""
        return UdfApplyOp(
            ArcPointer(copy=self._pool), self._ids.copy(), self._udf_index, self._field.copy(),
            self._binding, worker_id,
        )


struct UdfApplyOp(MorselOperatorImpl):
    """One worker's OP_UDF_APPLY: the argument expressions evaluated, the UDF
    called on its own instance, the answer appended."""

    var _pool: ArcPointer[ExprPool]
    var _ids: List[ExprId]
    var _udf_index: Int
    var _field: Field
    var _binding: ArcPointer[UdfBinding]
    var _worker: Int
    var _instance: Optional[UdfInstance]
    var _metrics: OwnedPointer[MetricsSet]

    def __init__(
        out self,
        var pool: ArcPointer[ExprPool],
        var ids: List[ExprId],
        udf_index: Int,
        var field: Field,
        binding: ArcPointer[UdfBinding],
        worker: Int,
    ) raises:
        self._pool = pool^
        self._ids = ids^
        self._udf_index = udf_index
        self._field = field^
        self._binding = binding
        self._worker = worker
        self._instance = None
        var ms = new_owned_metrics_set()
        _ = ms[].register_counter["rows_processed"]()
        _ = ms[].register_time["elapsed_compute"]()
        self._metrics = ms^

    def metrics_snapshot(self) -> MetricsSnapshot:
        return self._metrics[].reduce()

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        var t0 = perf_counter_ns()
        if morsel.batch.has_selection_mask():
            var extracted = RecordBatch()
            swap(morsel.batch, extracted)
            morsel.replace_batch(materialize_selection_if_present(extracted^))
        var rows = morsel.num_rows()
        var args = List[Column[HeapRegion]](capacity=len(self._ids))
        for i in range(len(self._ids)):
            args.append(_eval_column_expr(self._pool[].resolve(self._ids[i]), morsel.batch))
        var answer: Column[HeapRegion]
        if rows == 0:
            answer = _empty_like(morsel.batch, self._field)
        else:
            if not self._instance:
                self._instance = Optional(UdfInstance(self._binding, self._udf_index, self._worker))
            answer = self._instance.value().call(args, rows)
        var b = RecordBatchBuilder.with_capacity(morsel.batch.num_columns() + 1)
        var sb = SchemaBuilder()
        for c in range(morsel.batch.num_columns()):
            sb.add_field(morsel.batch.schema.field_at(c))
            b.add_column(morsel.batch.column_at(c).share())
        sb.add_field(self._field.copy())
        b.add_column(answer^)
        morsel.replace_batch(b.build(sb.build()))
        self._metrics[].counter["rows_processed"]().inc_in_pipeline(Int64(rows), worker_id=0)
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)


def _empty_like(ref batch: RecordBatch, field: Field) raises -> Column[HeapRegion]:
    """A column of no rows of `field`'s type: the answer to a batch of no
    rows, which calls nothing."""
    var sb = SchemaBuilder()
    sb.add_field(field.copy())
    var empty = empty_batch_like_schema(sb.build())
    return empty.column_at(0).share()
