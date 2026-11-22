# =============================================================================
# SegmentBuilder -- how the driver gets the members of a segment
# =============================================================================
#
# The driver knows a segment as a `SegmentDescPod` and cannot name the concrete
# types of its source, operators and sink. A `SegmentBuilder` names them: its
# three associated types are the closed variants the plan can use, and its
# methods construct the members of one segment from its descriptor.
#
# The builder owns what the descriptor refers to by index (the sink parameters
# and resident batches of a plan) and applies the source hooks the plan asks
# for before it returns the source, because the source trait requires them
# before the first pull. A dependent segment's source is built from what its
# producers published: `build_source` receives the `PublishedOutputs` and takes
# the batches it needs.
#
# An operator can owe rows after every worker of its segment has finished: a
# RIGHT or FULL join probe owes the build rows no probe row matched.
# `op_tail` returns them, once the dispatch has ended; the driver pushes them
# through the operators after that one and into the sink.

from arrow.schema import RecordBatch, Schema
from morsel.morsel_operator import MorselOperatorImpl
from morsel.morsel_sink import MorselSinkImpl
from morsel.morsel_source import MorselSourceImpl
from physical_plan.physical_plan import SegmentDescPod

from .published_outputs import PublishedOutputs


trait SegmentBuilder(Movable, Deinitable):
    """Constructs the source, the operators and the sink of one segment."""

    comptime Source: MorselSourceImpl
    comptime Op: MorselOperatorImpl
    comptime Sink: MorselSinkImpl

    def op_count(self, ref desc: SegmentDescPod) -> Int:
        """How many operators the segment's chain holds. The default reads the
        descriptor."""
        return desc.num_ops()

    def build_source(
        mut self,
        ref desc: SegmentDescPod,
        mut published: PublishedOutputs,
        num_workers: Int,
    ) raises -> Self.Source:
        """The segment's source, with its hooks applied. This call begins a
        run of the segment: a builder keeps per-run state (a limit's shared
        budget) from here to the next `build_source` of the same segment, and
        drops what an earlier run left. `num_workers` is the
        count of workers that will call `next_morsel`; a source that sizes
        per-worker state at construction needs it."""
        ...

    def build_op(
        mut self, ref desc: SegmentDescPod, op_index: Int, worker_id: Int
    ) raises -> Self.Op:
        """Operator `op_index` of the chain, for worker `worker_id`. Each worker
        owns its own instances."""
        ...

    def build_sink(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema
    ) raises -> Self.Sink:
        """The segment's sink. `source_schema` is the schema of the built
        source's morsels, for a sink that must name its output when no morsel
        reaches it."""
        ...

    def op_tail(
        mut self,
        ref desc: SegmentDescPod,
        op_index: Int,
        ref source_schema: Schema,
    ) raises -> List[RecordBatch]:
        """The rows operator `op_index` of `desc` emits after every worker of
        the segment has finished, in the order they are to be pushed on;
        `source_schema` is the schema of the built source's morsels. Called
        once per operator, in chain order, after the workers joined and
        before the sink combines. The default: no rows."""
        return List[RecordBatch]()
