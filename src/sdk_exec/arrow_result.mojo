"""The answer of `run_sql` as batches checked to cross the Arrow C Stream
Interface.

`arrow_result(outcome)` turns a `SqlOutcome` into an `ArrowResult`, or raises.
A C entry point that fills a caller's `struct ArrowArrayStream` runs it first
and writes the stream only when it returns: every way the export can fail is
found here, before the caller's struct is touched, and never later inside
the consumer's `get_schema` or `get_next`. The stream itself is written by
`arrow_ipc.c_data_stream.build_record_batch_stream(result.take_batches(),
result.take_schema(), out)`, in the module that owns the C entry point, the
one place a pointer is held. Nothing here holds a pointer.

The result owns its batches and their schema and keeps no reference to the
`EngineContext` that ran the query: the context may be dropped first.
"""

from arrow.schema import RecordBatch, Schema
from arrow_ipc.c_data_stream_check import check_record_batch_stream
from column_kernels.compiler_helpers import materialize_selection_if_present
from containers.slab import Slab

from .engine_plan import SqlOutcome


struct ArrowResult(Movable):
    """The batches of one answer and the schema they share, in answer order,
    each one known to export whole (`check_record_batch_stream`)."""

    var batches: Slab[RecordBatch]
    var schema: Schema

    def __init__(out self, var batches: Slab[RecordBatch], var schema: Schema):
        self.batches = batches^
        self.schema = schema^

    def take_batches(mut self) -> Slab[RecordBatch]:
        """Move the batches out, leaving none."""
        var out = self.batches^
        self.batches = Slab[RecordBatch]()
        return out^

    def take_schema(mut self) -> Schema:
        """Move the schema out, leaving an empty one."""
        var out = self.schema^
        self.schema = Schema()
        return out^


def arrow_result(var outcome: SqlOutcome) raises -> ArrowResult:
    """The batches of `outcome`, ready for the Arrow C stream, or a raise.

    Raises with the step and the step's message when `run_sql` refused, and
    when the answer has no batch (there is no schema to export). A batch with
    a selection mask is replaced by the rows the mask keeps. The schema is the
    first batch's; a column the export cannot carry is refused naming the
    column and its Arrow type (`check_record_batch_stream`).
    """
    if outcome.refusal:
        ref refusal = outcome.refusal.value()
        raise Error(
            "run_sql refused at step "
            + refusal.step
            + ": "
            + refusal.reason
        )
    var n = len(outcome.batches)
    if n == 0:
        raise Error("ArrowResult: the answer has no batch, so no schema")
    outcome.batches.reverse()
    var batches = Slab[RecordBatch].with_capacity(n)
    while len(outcome.batches) > 0:
        batches.append(materialize_selection_if_present(outcome.batches.pop()))
    var schema = batches[0].schema.copy()
    check_record_batch_stream(schema, batches)
    return ArrowResult(batches^, schema^)
