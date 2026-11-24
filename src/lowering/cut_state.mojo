# =============================================================================
# cut_state -- what the cutter's arms share: the open pipeline and the cutter
# =============================================================================
#
# `_Pipe` is an open pipeline: a source and the operators fused onto it so far.
# `_Cutter` holds what the walk has produced so far (the segments, the schema
# that flows into each segment's sink, the ParamTable and the scans seen) and
# the two moves every breaker makes: `_close` ends a pipeline in a sink and
# records it as the next segment, `_reopen` opens the pipeline that reads that
# segment's output over an E3 edge. `CutResult` is what the cutter hands
# `lower`. The walk and its arms are `cut_walk` and the modules it names. The
# cutter also records the shared subplans it has cut (`cut_shared`): the
# canonical hashes the plan's references name and, for each canonical subtree
# cut so far, its schema and the segment its references read.
#
# Segment ids are dense and follow the cut order, which is dependency order:
# a producer is cut before its consumer. Every segment has one partition and
# is ORDER_NONE, except the one an arm asks to be ORDER_ROW_RANGE
# (`cut_aggregate`: an ungrouped float SUM or AVG). `card_estimate_rows` is the row count of the scan's footers when
# the host supplied one, an upper bound on the rows that reach the sink, and 0
# otherwise, and 0 for a pipeline with a join probe or a frame in it (either
# can give more rows than its input holds) and for a pipeline a step opens;
# `mem_estimate_bytes` is 0 (no memory decision is recorded).
# =============================================================================

from arrow.schema import Schema
from containers.slab import Slab
from lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    ParamTable,
    LOWERING_UNCUTTABLE_NODE,
)
from plan_ir.logical_plan import LogicalPlan, plan_tag_name
from physical_plan.physical_plan import (
    SegmentDescPod,
    SourceSpecPod,
    MorselOp,
    SOURCE_SINK_OUTPUT,
    EDGE_E3_PUBLISH_WAIT,
    ORDER_NONE,
)


struct CutResult(Movable):
    """What the cutter produced: the segments, the schema that flows into each
    segment's sink (for morsel sizing), the parameters and the result segment."""

    var segments: List[SegmentDescPod]
    var flow_schemas: List[Schema]
    var params: ParamTable
    var result_seg_id: Int

    def __init__(
        out self,
        var segments: List[SegmentDescPod],
        var flow_schemas: List[Schema],
        var params: ParamTable,
        result_seg_id: Int,
    ):
        self.segments = segments^
        self.flow_schemas = flow_schemas^
        self.params = params^
        self.result_seg_id = result_seg_id

    def into_lowered(deinit self) -> LoweredPlan:
        return LoweredPlan(self.segments^, self.params^, self.result_seg_id)


struct _Pipe(Movable):
    """An open pipeline: a source and the operators fused onto it so far."""

    var source_kind: UInt8
    var source_spec: SourceSpecPod
    var ops: Slab[MorselOp]
    var deps: List[Int]
    var edge_tags: List[UInt8]
    var schema: Schema
    """The schema of the rows the pipeline delivers."""
    var scan_index: Int
    """Pre-order index of the scan that is this pipeline's source; -1 when the
    source is a breaker's output or a union's concatenation."""
    var has_project: Bool
    var sorted_input: Bool
    """True while the rows the pipeline delivers are a sort's output in that
    sort's order: set when the pipeline opens on a sort or on a window with a
    partition or order key (its rows come out in key order), kept by every
    operator fused onto it, and false when it opens on an aggregation."""
    var broken_by: Int
    """The segment whose output this pipeline is, while no operator has been
    appended to it; -1 otherwise."""
    var has_join: Bool
    """True once a join probe or a frame (an OP_UDF_FRAME) is fused onto the
    pipeline: its rows are no longer bounded by the scan's row count, and a
    column name may no longer mean the scan's column."""

    def __init__(
        out self,
        source_kind: UInt8,
        var source_spec: SourceSpecPod,
        var schema: Schema,
        scan_index: Int,
    ):
        self.source_kind = source_kind
        self.source_spec = source_spec^
        self.ops = Slab[MorselOp]()
        self.deps = List[Int]()
        self.edge_tags = List[UInt8]()
        self.schema = schema^
        self.scan_index = scan_index
        self.has_project = False
        self.sorted_input = False
        self.broken_by = -1
        self.has_join = False

    def append_op(mut self, var op: MorselOp):
        self.ops.append(op^)
        self.broken_by = -1

    def append_ops(mut self, var ops: Slab[MorselOp]):
        """Append `ops`, in their order."""
        self.ops.extend(ops^)
        self.broken_by = -1

    def into_segment(
        deinit self,
        seg_id: Int,
        sink_kind: UInt8,
        key_dtype: UInt8,
        orientation: UInt8,
        param_id: Int,
        card_estimate_rows: Int,
        order_key_kind: UInt8,
    ) -> SegmentDescPod:
        """Consume the pipeline into the segment that ends it in a sink."""
        return SegmentDescPod(
            seg_id,
            self.source_kind,
            self.source_spec^,
            self.ops^,
            sink_kind,
            key_dtype,
            orientation,
            param_id,
            seg_id,
            self.deps^,
            self.edge_tags^,
            1,
            order_key_kind,
            0,
            card_estimate_rows,
        )


def _uncuttable(node: LogicalPlan, what: String) -> Error:
    return Error(
        String(LOWERING_UNCUTTABLE_NODE)
        + ": "
        + plan_tag_name(node.tag)
        + " ("
        + what
        + ") is not cut"
    )


struct _Cutter(Movable):
    var segments: List[SegmentDescPod]
    var flow_schemas: List[Schema]
    var params: ParamTable
    var scans_seen: Int
    var referenced: List[UInt64]
    """The canonical hash of every shared-subplan reference in the plan
    (`cut_shared`); empty when the plan has none, and then no node is
    hashed."""
    var shared_hashes: List[UInt64]
    """The canonical subtrees cut so far, in cut order; the lists below are
    parallel to it."""
    var shared_schemas: List[Schema]
    var shared_segs: List[Int]
    """The segment whose output the subtree is, or -1 for a streaming subtree,
    which is cut again at every reference."""
    var shared_sorted: List[Bool]
    var shared_first_scan: List[Int]
    """The pre-order index of the subtree's first scan."""
    var shared_plans: Slab[LogicalPlan]
    """A copy of each subtree with every reference in it replaced by the
    subtree it names: the subtree as it stood before its producer folded it,
    whose `structural_hash()` is the hash references carry."""
    var shared_recuts: Slab[LogicalPlan]
    """A copy of each subtree as it stands in the plan, its references kept:
    what a streaming subtree's references cut again, so a reference inside it
    takes its own subtree's scans, as in the plan."""

    def __init__(out self):
        self.segments = List[SegmentDescPod]()
        self.flow_schemas = List[Schema]()
        self.params = ParamTable()
        self.scans_seen = 0
        self.referenced = List[UInt64]()
        self.shared_hashes = List[UInt64]()
        self.shared_schemas = List[Schema]()
        self.shared_segs = List[Int]()
        self.shared_sorted = List[Bool]()
        self.shared_first_scan = List[Int]()
        self.shared_plans = Slab[LogicalPlan]()
        self.shared_recuts = Slab[LogicalPlan]()

    def _shared_at(self, h: UInt64) -> Int:
        """The index of the canonical subtree of hash `h` cut so far, or -1."""
        for i in range(len(self.shared_hashes)):
            if self.shared_hashes[i] == h:
                return i
        return -1

    def finish(deinit self, result_seg_id: Int) -> CutResult:
        return CutResult(
            self.segments^, self.flow_schemas^, self.params^, result_seg_id
        )

    def _reopen(mut self, seg_id: Int, schema: Schema) -> _Pipe:
        """The pipeline that reads the output of breaker `seg_id`."""
        var pipe = _Pipe(
            SOURCE_SINK_OUTPUT,
            SourceSpecPod.from_sink_output(seg_id),
            schema.copy(),
            -1,
        )
        pipe.deps.append(seg_id)
        pipe.edge_tags.append(EDGE_E3_PUBLISH_WAIT)
        pipe.broken_by = seg_id
        return pipe^

    def _close(
        mut self,
        var pipe: _Pipe,
        sink_kind: UInt8,
        key_dtype: UInt8,
        orientation: UInt8,
        param_id: Int,
        inputs: LoweringInputs,
        order_key_kind: UInt8 = ORDER_NONE,
    ) -> Int:
        """End `pipe` in a sink and record it as the next segment, whose
        combine order is `order_key_kind`."""
        var seg_id = len(self.segments)
        var card = 0
        if pipe.scan_index >= 0 and not pipe.has_join:
            ref stats = inputs.scans[pipe.scan_index].stats
            if stats:
                card = stats.value().row_count
        self.flow_schemas.append(pipe.schema.copy())
        self.segments.append(
            pipe^.into_segment(
                seg_id,
                sink_kind,
                key_dtype,
                orientation,
                param_id,
                card,
                order_key_kind,
            )
        )
        return seg_id
