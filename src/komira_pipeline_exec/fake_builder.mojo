# =============================================================================
# fake_builder -- a SegmentBuilder that builds the fake members from scripts
# =============================================================================
#
# One `FakeScript` per segment says which fake source, which operators and which
# sink the segment gets. The builder keeps a `Tally` per segment (read it with
# `tally(seg_id)`) and the order in which segments were built (`built_order`),
# which is the order the scheduler started them in.

from komira_arrow.schema import Schema
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    ORDER_NONE,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_BATCH,
    SourceSpecPod,
)

from .fake_members import (
    FakeBatchSource,
    FakeCountSink,
    FakeOp,
    FakeSink,
    FakeSource,
    SOURCE_CURSOR,
)
from .fake_support import Tally, batch_values
from .op_variant import OpVariant
from .pipeline_sink import PipelineSink
from .published_outputs import PublishedOutputs
from .segment_builder import SegmentBuilder
from .source_variant import SourceVariant
from .unused_members import NoOperator, NoSink, NoSource

comptime FROM_CURSOR = 0
"""The segment reads a `FakeSource` in `SOURCE_CURSOR` mode."""
comptime FROM_PER_WORKER = 1
"""The segment reads a `FakeSource` in `SOURCE_PER_WORKER` mode."""
comptime FROM_DEP = 2
"""The segment reads the output of segment `dep` through a `FakeBatchSource`."""

comptime TO_COLLECT = 0
"""The segment ends in a `FakeSink`."""
comptime TO_COUNT = 1
"""The segment ends in a `FakeCountSink`."""


def fake_desc(
    seg_id: Int,
    var deps: List[Int] = List[Int](),
    var edge_tags: List[UInt8] = List[UInt8](),
    order_key_kind: UInt8 = ORDER_NONE,
) -> SegmentDescPod:
    """A descriptor with the given id, dependencies, edge tags and order key,
    and no operators; the members come from the builder's script."""
    return SegmentDescPod(
        seg_id,
        SOURCE_BATCH,
        SourceSpecPod(),
        Slab[MorselOp](),
        SINK_COLLECT,
        KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR,
        -1,
        seg_id,
        deps^,
        edge_tags^,
        order_key_kind=order_key_kind,
    )


struct FakeOpSpec(Copyable, Movable):
    """One operator of a script: a `FakeOp` kind and its argument."""

    var kind: Int
    var arg: Int

    def __init__(out self, kind: Int, arg: Int = 0):
        self.kind = kind
        self.arg = arg


struct FakeScript(Copyable, Movable):
    """What one segment is made of."""

    var from_kind: Int
    var n_morsels: Int
    var rows: Int
    var fail_at_claim: Int
    var dep: Int
    var ops: List[FakeOpSpec]
    var to_kind: Int
    var budget_bytes: Int

    def __init__(
        out self,
        from_kind: Int = FROM_CURSOR,
        n_morsels: Int = 0,
        rows: Int = 1,
        fail_at_claim: Int = -1,
        dep: Int = -1,
        var ops: List[FakeOpSpec] = List[FakeOpSpec](),
        to_kind: Int = TO_COLLECT,
        budget_bytes: Int = -1,
    ):
        self.from_kind = from_kind
        self.n_morsels = n_morsels
        self.rows = rows
        self.fail_at_claim = fail_at_claim
        self.dep = dep
        self.ops = ops^
        self.to_kind = to_kind
        self.budget_bytes = budget_bytes


struct FakeBuilder(SegmentBuilder):
    """Builds the fake members for the segments of a plan from `FakeScript`s."""

    comptime Source = SourceVariant[FakeSource, FakeBatchSource, NoSource]
    comptime Op = OpVariant[FakeOp, NoOperator, NoOperator]
    comptime Sink = PipelineSink[FakeSink, FakeCountSink, NoSink]

    var scripts: List[FakeScript]
    var _tallies: List[Tally]
    var built_order: List[Int]
    var cancel_token: Optional[CancellationToken]

    def __init__(out self):
        self.scripts = List[FakeScript]()
        self._tallies = List[Tally]()
        self.built_order = List[Int]()
        self.cancel_token = None

    def add(mut self, var script: FakeScript) -> Int:
        """Add the script of the next segment; returns its segment id."""
        self.scripts.append(script^)
        self._tallies.append(Tally())
        return len(self.scripts) - 1

    def tally(self, seg_id: Int) -> Tally:
        """A handle on the counters of segment `seg_id`."""
        return self._tallies[seg_id].share()

    def op_count(self, ref desc: SegmentDescPod) -> Int:
        return len(self.scripts[desc.seg_id].ops)

    def build_source(
        mut self,
        ref desc: SegmentDescPod,
        mut published: PublishedOutputs,
        num_workers: Int,
    ) raises -> Self.Source:
        self.built_order.append(desc.seg_id)
        ref script = self.scripts[desc.seg_id]
        if script.from_kind == FROM_DEP:
            var taken = published.take(script.dep)
            return Self.Source.second(
                FakeBatchSource(
                    batch_values(taken),
                    script.rows,
                    self.tally(desc.seg_id),
                )
            )
        return Self.Source.first(
            FakeSource(
                script.from_kind,
                script.n_morsels,
                script.rows,
                self.tally(desc.seg_id),
                script.fail_at_claim,
            )
        )

    def build_op(
        mut self, ref desc: SegmentDescPod, op_index: Int, worker_id: Int
    ) raises -> Self.Op:
        ref spec = self.scripts[desc.seg_id].ops[op_index]
        var token = Optional[CancellationToken]()
        if self.cancel_token:
            token = Optional[CancellationToken](self.cancel_token.value().clone())
        return Self.Op.first(
            FakeOp(spec.kind, spec.arg, self.tally(desc.seg_id), token^)
        )

    def build_sink(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema
    ) raises -> Self.Sink:
        ref script = self.scripts[desc.seg_id]
        if script.to_kind == TO_COUNT:
            return Self.Sink.second(FakeCountSink(self.tally(desc.seg_id)))
        return Self.Sink.first(
            FakeSink(self.tally(desc.seg_id), script.budget_bytes)
        )
