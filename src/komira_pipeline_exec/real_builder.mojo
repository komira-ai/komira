# =============================================================================
# real_builder -- the SegmentBuilder over the real members
# =============================================================================
#
# `RealBuilder` constructs the members of a segment from its descriptor:
#
#   source   SOURCE_PARQUET       `ParquetSource` from the spec (`source_parquet`)
#            SOURCE_BATCH         a copy of the resident batch the spec's handle
#                                 names (`source_batch`)
#            SOURCE_SINK_OUTPUT   the output of the producer the spec names,
#                                 moved out of `PublishedOutputs`
#                                 (`source_sink_output`)
#   op       OP_FILTER            `FilterOp`  (`op_filter`)
#            OP_PROJECT           `MapOp`     (`op_project`)
#            OP_LIMIT             `LimitOp`   (`op_limit`)
#   sink     SINK_COLLECT         `CollectSink` (`sink_collect`)
#
# Anything else (SOURCE_CONCAT, OP_JOIN_PROBE, the aggregation and sort sinks)
# is refused by name, because no member serves it yet.
#
# The workers of a segment each get their own operator instances, built from
# one set of shared parts the builder keeps per operator (the predicate, the
# registered projection expressions, the limit's row budget), so a limit counts
# the rows of all workers and an expression is registered once. The parts are
# those of one run: `build_source`, the first call of a segment run, drops
# the parts an earlier run of the segment left, so a plan run twice on one
# builder spends a fresh limit each time.
#
# The builder borrows the footer cache and the expression pool the Parquet
# source reads from; they belong to the caller and outlive every segment run.
# Resident batches are owned by the builder (`add_resident` returns the handle
# a SOURCE_BATCH spec names).

from std.memory import Pointer

from komira_arrow.schema import RecordBatch, Schema
from komira_buffer.constants import DEFAULT_MORSEL_ROWS
from komira_column_kernels.compiler_helpers import (
    copy_batch,
    empty_batch_like_schema,
)
from komira_morsel.morsel import Morsel
from komira_operator_api.map_op import MapOp
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    OP_FILTER,
    OP_LIMIT,
    OP_PROJECT,
    SegmentDescPod,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_BATCH,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
)
from komira_plan_expr.expr_pool import ExprPool

from .op_filter import FilterOp, FilterShared
from .op_limit import LimitOp, LimitShared
from .op_project import ProjectShared
from .op_variant import OpVariant
from .pipeline_sink import PipelineSink
from .published_outputs import PublishedOutputs
from .segment_builder import SegmentBuilder
from .sink_collect import CollectSink
from .source_batch import BatchSource
from .source_parquet import LocalParquetSource, build_parquet_source
from .source_sink_output import SinkOutputSource
from .source_variant import SourceVariant
from .unused_members import NoSink


struct _OpParts(Movable):
    """The parts the per-worker instances of one operator share."""

    var seg_id: Int
    var op_index: Int
    var filter: Optional[FilterShared]
    var project: Optional[ProjectShared]
    var limit: Optional[LimitShared]

    def __init__(out self, seg_id: Int, op_index: Int):
        self.seg_id = seg_id
        self.op_index = op_index
        self.filter = None
        self.project = None
        self.limit = None


struct RealBuilder[
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
](SegmentBuilder):
    """Builds the real members of a segment: Parquet, batch and sink-output
    sources; filter, project and limit operators; the collect sink."""

    comptime Source = SourceVariant[
        LocalParquetSource[Self.cache_o, Self.pool_o, Self.filter_o],
        BatchSource,
        SinkOutputSource,
    ]
    comptime Op = OpVariant[FilterOp, MapOp, LimitOp]
    comptime Sink = PipelineSink[CollectSink, NoSink, NoSink]

    # The borrowed cache and pool, kept as pointers (private) because a struct
    # field cannot hold a `ref` argument; the caller's objects outlive the
    # builder.
    var _cache: Pointer[ParquetMetadataCache, Self.cache_o]
    var _pool: Pointer[ExprPool, Self.pool_o]
    var _resident: List[RecordBatch]
    var _parts: List[_OpParts]

    def __init__(
        out self,
        ref [Self.cache_o] cache: ParquetMetadataCache,
        ref [Self.pool_o] pool: ExprPool,
    ):
        self._cache = Pointer(to=cache)
        self._pool = Pointer(to=pool)
        self._resident = List[RecordBatch]()
        self._parts = List[_OpParts]()

    def add_resident(mut self, var batch: RecordBatch) -> Int:
        """Keep `batch` for SOURCE_BATCH segments; returns the handle their
        specs name."""
        self._resident.append(batch^)
        return len(self._resident) - 1

    def _drop_parts_of(mut self, seg_id: Int):
        var kept = List[_OpParts]()
        while len(self._parts) > 0:
            var parts = self._parts.pop()
            if parts.seg_id != seg_id:
                kept.append(parts^)
        self._parts = kept^

    def _parts_index(
        mut self, ref desc: SegmentDescPod, op_index: Int
    ) raises -> Int:
        """The shared parts of operator `op_index` of `desc`, made on first
        use."""
        for i in range(len(self._parts)):
            if (
                self._parts[i].seg_id == desc.seg_id
                and self._parts[i].op_index == op_index
            ):
                return i
        if op_index < 0 or op_index >= desc.num_ops():
            raise Error(
                "komira_pipeline_exec: segment "
                + String(desc.seg_id)
                + " has no operator "
                + String(op_index)
            )
        ref spec = desc.ops[op_index]
        var parts = _OpParts(desc.seg_id, op_index)
        if spec.tag == OP_FILTER:
            parts.filter = Optional(FilterShared(spec))
        elif spec.tag == OP_PROJECT:
            parts.project = Optional(ProjectShared(spec))
        elif spec.tag == OP_LIMIT:
            parts.limit = Optional(LimitShared(spec))
        else:
            raise Error(
                "komira_pipeline_exec: operator tag "
                + String(Int(spec.tag))
                + " of segment "
                + String(desc.seg_id)
                + " is not served (OP_FILTER, OP_PROJECT and OP_LIMIT are)"
            )
        self._parts.append(parts^)
        return len(self._parts) - 1

    def build_source(
        mut self,
        ref desc: SegmentDescPod,
        mut published: PublishedOutputs,
        num_workers: Int,
    ) raises -> Self.Source:
        # A segment run starts here. What the operators of an earlier run of
        # this segment shared (a limit's spent row budget) is not theirs.
        self._drop_parts_of(desc.seg_id)
        ref spec = desc.source_spec
        var morsel_rows = desc.morsel_rows
        if desc.source_kind == SOURCE_PARQUET:
            return Self.Source.first(
                build_parquet_source[
                    Self.cache_o, Self.pool_o, Self.filter_o
                ](spec, morsel_rows, num_workers, self._cache[], self._pool[])
            )
        if morsel_rows <= 0:
            morsel_rows = DEFAULT_MORSEL_ROWS
        if desc.source_kind == SOURCE_BATCH:
            var handle = spec.batch_handle_id
            if handle < 0 or handle >= len(self._resident):
                raise Error(
                    "komira_pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " reads resident batch "
                    + String(handle)
                    + ", and the builder holds "
                    + String(len(self._resident))
                )
            return Self.Source.second(
                BatchSource(copy_batch(self._resident[handle]), morsel_rows)
            )
        if desc.source_kind == SOURCE_SINK_OUTPUT:
            if len(spec.dep_seg_ids) != 1:
                raise Error(
                    "komira_pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " reads the output of "
                    + String(len(spec.dep_seg_ids))
                    + " segments; a SOURCE_SINK_OUTPUT reads one"
                )
            var producer = spec.dep_seg_ids[0]
            var is_dep = False
            for i in range(len(desc.deps)):
                if desc.deps[i] == producer:
                    is_dep = True
            if not is_dep:
                raise Error(
                    "komira_pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " reads the output of segment "
                    + String(producer)
                    + ", which is not among its dependencies"
                )
            return Self.Source.third(
                SinkOutputSource(
                    published.take(producer), producer, morsel_rows
                )
            )
        raise Error(
            "komira_pipeline_exec: source kind "
            + String(Int(desc.source_kind))
            + " of segment "
            + String(desc.seg_id)
            + " is not served (SOURCE_PARQUET, SOURCE_BATCH and"
            " SOURCE_SINK_OUTPUT are)"
        )

    def build_op(
        mut self, ref desc: SegmentDescPod, op_index: Int, worker_id: Int
    ) raises -> Self.Op:
        var at = self._parts_index(desc, op_index)
        ref parts = self._parts[at]
        if parts.filter:
            return Self.Op.first(parts.filter.value().make())
        if parts.project:
            return Self.Op.second(parts.project.value().make())
        return Self.Op.third(parts.limit.value().make())

    def build_sink(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema
    ) raises -> Self.Sink:
        if (
            desc.sink_kind != SINK_COLLECT
            or desc.sink_key_dtype != KEY_DTYPE_NONE
            or desc.sink_orientation != SINK_ORIENT_COLUMNAR
        ):
            raise Error(
                "komira_pipeline_exec: the sink of segment "
                + String(desc.seg_id)
                + " is not served; only (SINK_COLLECT, KEY_DTYPE_NONE,"
                " SINK_ORIENT_COLUMNAR) is"
            )
        return Self.Sink.first(CollectSink(self._result_schema(desc, source_schema)))

    def _result_schema(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema
    ) -> Optional[Schema]:
        """The schema the segment's rows have: the source's, as each
        projection of the chain reshapes it. A projection is asked by running
        it over a batch of no rows. None when that fails."""
        try:
            var schema = source_schema.copy()
            for i in range(desc.num_ops()):
                if desc.ops[i].tag != OP_PROJECT:
                    continue
                var at = self._parts_index(desc, i)
                var probe = self._parts[at].project.value().make()
                var m = Morsel(empty_batch_like_schema(schema), 0, 0)
                _ = probe.execute(m)
                schema = m.batch.schema.copy()
            return Optional(schema^)
        except:
            return None
