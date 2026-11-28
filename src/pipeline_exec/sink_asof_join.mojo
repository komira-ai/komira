# =============================================================================
# sink_asof_join -- (SINK_ASOF_JOIN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# =============================================================================
#
# `AsofSink` is the as-of join of a segment's rows (the left side) with the
# rows of the segment its `AsofJoinSinkData` names as `right_seg_id` (the
# right side), which the builder takes from the published outputs when the
# segment's source is built and hands the sink.
#
# The workers' morsels go to a `CollectSink`, so the left side is collected in
# source position order whatever the schedule was. `combine` runs once after
# the workers have joined: it takes those rows and runs
# `op_asof.asof_join_sink.AsofJoinSink` over them and the right rows. That
# sort is stable and both sides arrive in their sources' order, so among right
# rows tied on the keys and the ASOF value the one met first in the right
# side's order is the one a left row matches, on any worker count.
#
# The output is the node's columns: every left column, then every right
# column made nullable, renamed `<name>_right` when a left column has its
# name, one row per left row in the sorted left order. A segment with no left
# row answers no row at the node's output schema.
# =============================================================================

from arrow.schema import RecordBatch, Schema
from column_kernels.compiler_helpers import empty_batch_like_schema
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution
from op_asof.asof_join_sink import AsofJoinSink
from physical_plan.physical_plan import AsofJoinSinkData

from .sink_collect import CollectSink


def _copy_spec(ref d: AsofJoinSinkData) -> AsofJoinSinkData:
    """A copy of `d`: the builder keeps its own for a later run."""
    return AsofJoinSinkData(
        d.left_keys.copy(),
        d.right_keys.copy(),
        d.left_asof,
        d.right_asof,
        d.strategy,
        d.tolerance,
        d.left_sort_keys.copy(),
        d.left_sort_desc.copy(),
        d.right_sort_keys.copy(),
        d.right_sort_desc.copy(),
        d.output_schema.copy(),
        asof_dtype=d.asof_dtype,
        right_seg_id=d.right_seg_id,
    )


struct AsofSink(MorselSinkImpl):
    """The as-of join of the rows the workers hand it with the right rows it
    is built with."""

    var _left: CollectSink
    var _spec: Optional[AsofJoinSinkData]
    var _right: Optional[RecordBatch]
    var _out: Optional[RecordBatch]

    def __init__(
        out self,
        ref spec: AsofJoinSinkData,
        var right: RecordBatch,
        var left_schema: Optional[Schema],
    ):
        self._left = CollectSink(left_schema^)
        self._spec = Optional(_copy_spec(spec))
        self._right = Optional(right^)
        self._out = None

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._left.resize_worker_state(num_workers)

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        self._left.consume(worker_id, morsel^)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        self._left.combine(pipeline)
        var left = self._left.take_output()
        var spec = self._spec.take()
        if left.num_rows() == 0:
            self._out = Optional(empty_batch_like_schema(spec.output_schema))
            return
        var join = AsofJoinSink.new(spec^)
        join.consume(left^)
        self._out = Optional(join.materialize_with_right(self._right.take()))

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._out:
            raise Error(
                "pipeline_exec: the as-of join sink was read before it was"
                " combined"
            )
        return self._out.take()
