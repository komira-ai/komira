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

from komira_arrow.schema import Schema
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.morsel_source import MorselSourceImpl
from komira_physical_plan.physical_plan import SegmentDescPod

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
        """The segment's source, with its hooks applied. `num_workers` is the
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
