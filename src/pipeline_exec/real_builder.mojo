# =============================================================================
# real_builder -- the SegmentBuilder over the real members
# =============================================================================
#
# `RealBuilder` constructs the members of a segment from its descriptor:
#
#   source   SOURCE_PARQUET       `ParquetSource` from the spec (`source_parquet`):
#                                 over the local file system when the spec's
#                                 store is local, else over the file system
#                                 the builder's opener opens on the spec's
#                                 bucket (`SCAN_FS_UNSERVED` when it was
#                                 given none, or the opener does not serve
#                                 the store)
#            SOURCE_BATCH         a copy of the resident batch the spec's handle
#                                 names (`source_batch`)
#            SOURCE_SINK_OUTPUT   the output of the producer the spec names,
#                                 moved out of `PublishedOutputs`
#                                 (`source_sink_output`)
#            SOURCE_CSV           the CSV file the spec names, decoded at its
#                                 bound column types and served as a resident
#                                 batch (`source_csv`)
#            SOURCE_ICEBERG       the data files the spec names, each with the
#                                 delete files that apply to it, decoded at the
#                                 spec's bound columns and served as a resident
#                                 batch (`source_iceberg`)
#            SOURCE_CONCAT        the outputs of the producers the spec names,
#                                 moved out of `PublishedOutputs` and
#                                 concatenated in the spec's order into one
#                                 batch read like a sink output (a UNION ALL)
#            SOURCE_JSONL         the batches the spec's file is read into at
#                                 the spec's schema, served as a `BatchSource`
#                                 (`source_jsonl`)
#   op       OP_FILTER            `FilterOp`  (`op_filter`)
#            OP_PROJECT           `MapOp`     (`op_project`)
#            OP_LIMIT             `LimitOp`   (`op_limit`)
#            OP_JOIN_PROBE        `HashProbeOp` (`op_hash_probe`), over the
#                                 index made from the rows the build segment
#                                 it names published
#   sink     SINK_COLLECT         `CollectSink` (`sink_collect`)
#            SINK_AGG, key NONE   `AggSink` (`sink_agg`), from the `AggSinkData`
#                                 the descriptor's `sink_param_id` names; it
#                                 folds by source position when the segment
#                                 is ORDER_ROW_RANGE
#            SINK_AGG, key I64,   `GroupAggSink` (`sink_group_agg`), from the
#            I32, F64, F32,       same kind of data; both behind `AnyAggSink`
#            DATE32, BOOL or
#            DECIMAL128
#            SINK_AGG, key STRING `StringGroupAggSink` (`sink_string_group_agg`)
#            (DICT_ENCODED or     from that data too, behind `AnyAggSink`. A
#            COLUMNAR)            DICT_ENCODED sink makes its Parquet source
#                                 keep string dictionaries.
#            SINK_AGG, key        `StringGroupAggSink` built `composite`, from
#            COMPOSITE (COLUMNAR) that data too, behind `AnyAggSink`: a key of
#                                 several columns of mixed types
#                                 A grouped sink folds its float aggregates by
#                                 source position when the segment is
#                                 ORDER_ROW_RANGE
#            SINK_SORT, key NONE  `SortSink` (`sink_sort`), from the `SortSinkData`
#                                 the descriptor's `sink_param_id` names
#            SINK_TOPN, key NONE  `SortSink` keeping a range of its order, from
#                                 the `TopNSinkData` the descriptor's
#                                 `sink_param_id` names
#            SINK_PARTITION_BY,   `WindowSink` (`sink_window`), from the
#            key NONE             `PartitionBySinkData` the descriptor's
#                                 `sink_param_id` names: the rows sorted by the
#                                 partition and order keys with one column per
#                                 window expression
#            SINK_PARTITION_TOPN, `PartitionTopNPipelineSink`
#            key NONE             (`sink_partition_topn`), from the
#                                 `PartitionTopNSinkData` the descriptor's
#                                 `sink_param_id` names: per partition, the
#                                 rows numbered at most k
#            SINK_HASH_BUILD,     `CollectSink`: the build side's rows, which the
#            key NONE             probe segment takes and indexes
#
# Anything else (the other sinks) is refused by name, because no member
# serves it yet.
#
# An ORDER_ROW_RANGE segment is the same bits on every worker count only when
# its source cuts the same morsels on every worker count. The three sources
# do: a resident batch and a producer's output are cut by the morsel size
# alone, and the Parquet source, with the scan options this builder gives it
# (no row-range split), cuts each row group by the morsel size alone. Its
# cursor-grain route, a process-wide switch that is off unless a caller turns
# it on, sizes its grains from the worker count, so an ORDER_ROW_RANGE
# segment over Parquet is refused by name while that switch is on.
#
# The workers of a segment each get their own operator instances, built from
# one set of shared parts the builder keeps per operator (the predicate, the
# registered projection expressions, the limit's row budget), so a limit counts
# the rows of all workers and an expression is registered once. The parts are
# those of one run: `build_source`, the first call of a segment run, drops
# the parts an earlier run of the segment left, so a plan run twice on one
# builder spends a fresh limit each time. It also makes the part of every
# OP_JOIN_PROBE of the segment, because it is the one call that sees the
# published outputs: it takes the build segment's rows (the build segment must
# be among the segment's dependencies) and indexes them once, before any
# worker starts (`op_hash_probe.HashProbeShared`).
#
# `op_tail` gives a RIGHT or FULL join probe's tail: the build rows its
# workers marked as matched by no probe row, in batches of the segment's
# morsel size (the default morsel size when the descriptor records none). The
# probe columns of those rows are NULL at the types the rows reaching the
# probe have: the source's schema as each projection and probe before it in
# the chain reshapes it (`_schema_at`, the same walk that names the output of
# a segment no row reaches), so the tail is typed even when no probe row
# arrived.
#
# The builder borrows the footer cache and the expression pool the Parquet
# source reads from; they belong to the caller and outlive every segment run.
# One footer cache serves the local and the remote sources of a run: each file
# system keys its entries under its own prefix (`FileSystem.key_prefix`), so
# a local file and an object of the same name never share an entry.
#
# The remote store a Parquet spec names is reached through a
# `ScanFsOpener` (`R`), handed to the builder by its caller with the plan: the
# builder is compiled for that opener's one file system type, and opens one
# file system on each bucket a spec names. A builder made without an opener
# reads the local file system only (`R` defaults to `LocalOnlyScanFs`).
# Resident batches are owned by the builder (`add_resident` returns the handle
# a SOURCE_BATCH spec names), and so is the sink data of the plan
# (`add_agg_sink` returns the id a descriptor's `sink_param_id` names). The
# builder also owns the segment pool the sinks draw their memory from
# (`set_memory_budget`; unbounded until set) and the spill directory it hands
# the grouped aggregation sinks over fixed-width keys (`set_spill_directory`;
# none until set, and then those sinks refuse a table the pool cannot grow
# instead of spilling it).

from std.memory import Pointer

from arrow.concat import concat_record_batches_nway
from arrow.schema import RecordBatch, Schema, SchemaBuilder
from byte_buffer.constants import DEFAULT_MORSEL_ROWS
from column_kernels.compiler_helpers import (
    copy_batch,
    empty_batch_like_schema,
)
from morsel.morsel import Morsel
from operator_api.map_op import MapOp
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_scan.cursor_grain_feed import cursor_grain_enabled
from physical_plan.physical_plan import (
    KEY_DTYPE_BOOL,
    KEY_DTYPE_COMPOSITE,
    KEY_DTYPE_DATE32,
    KEY_DTYPE_DECIMAL128,
    KEY_DTYPE_F32,
    KEY_DTYPE_F64,
    KEY_DTYPE_I32,
    KEY_DTYPE_I64,
    KEY_DTYPE_NONE,
    KEY_DTYPE_STRING,
    OP_FILTER,
    OP_JOIN_PROBE,
    OP_LIMIT,
    OP_PROJECT,
    ORDER_ROW_RANGE,
    AggSinkData,
    SegmentDescPod,
    SINK_AGG,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_PARTITION_BY,
    SINK_PARTITION_TOPN,
    SINK_SORT,
    SINK_TOPN,
    SortSinkData,
    TopNSinkData,
    PartitionBySinkData,
    PartitionTopNSinkData,
    SINK_ORIENT_COLUMNAR,
    SINK_ORIENT_DICT_ENCODED,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_ICEBERG,
    SOURCE_JSONL,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
)
from containers.slab import Slab
from fs.scan_fs import ScanFsOpener, scan_fs_unserved
from plan_expr.expr_pool import ExprPool

from .op_filter import FilterOp, FilterShared
from .op_hash_probe import HashProbeOp, HashProbeShared
from .op_limit import LimitOp, LimitShared
from .op_project import ProjectShared
from .op_variant import OpVariant
from .pipeline_sink import PipelineSink
from .published_outputs import PublishedOutputs
from .segment_builder import SegmentBuilder
from .segment_pool import SegmentPool
from .sink_agg import AggSink
from .sink_agg_any import AnyAggSink
from .sink_collect import CollectSink
from .sink_group_agg import GroupAggSink
from .sink_sort import SortSink
from .sink_partition_topn import PartitionTopNPipelineSink
from .sink_window import WindowSink
from .sink_string_group_agg import StringGroupAggSink
from .source_batch import BatchSource
from .source_csv import build_csv_source
from .source_iceberg import build_iceberg_source
from .source_jsonl import build_jsonl_source
from .source_parquet import (
    LocalOnlyScanFs,
    LocalParquetSource,
    ParquetSourceOn,
    build_parquet_source,
    build_parquet_source_on,
)
from .source_sink_output import SinkOutputSource
from .source_variant import SourceVariant
from .unused_members import NoSource


def _check_reads_a_dependency(ref desc: SegmentDescPod, producer: Int) raises:
    """Raise unless `producer` is among the dependencies of `desc`."""
    for i in range(len(desc.deps)):
        if desc.deps[i] == producer:
            return
    raise Error(
        "pipeline_exec: segment "
        + String(desc.seg_id)
        + " reads the output of segment "
        + String(producer)
        + ", which is not among its dependencies"
    )


def _nullable_union(ref batches: Slab[RecordBatch]) raises -> Schema:
    """The first batch's schema with each column nullable when that column is
    nullable in any of `batches`."""
    var builder = SchemaBuilder()
    for c in range(batches[0].schema.num_columns()):
        var field = batches[0].schema.field_at(c)
        for b in range(1, len(batches)):
            if batches[b].schema.field_nullable(c):
                field.nullable = True
        builder.add_field(field^)
    return builder.build()


struct _OpParts(Movable):
    """The parts the per-worker instances of one operator share."""

    var seg_id: Int
    var op_index: Int
    var filter: Optional[FilterShared]
    var project: Optional[ProjectShared]
    var limit: Optional[LimitShared]
    var probe: Optional[HashProbeShared]

    def __init__(out self, seg_id: Int, op_index: Int):
        self.seg_id = seg_id
        self.op_index = op_index
        self.filter = None
        self.project = None
        self.limit = None
        self.probe = None


struct RealBuilder[
    cache_o: Origin[mut=True],
    pool_o: Origin[mut=True],
    filter_o: Origin[mut=True],
    R: ScanFsOpener = LocalOnlyScanFs,
](SegmentBuilder):
    """Builds the real members of a segment: Parquet (local, or on the store
    `R` opens), batch, sink-output, CSV, concatenation and JSONL sources;
    filter, project, limit and join probe operators; the collect, aggregation,
    sort, window, partition top-n and hash build sinks."""

    comptime ParquetArm = SourceVariant[
        LocalParquetSource[Self.cache_o, Self.pool_o, Self.filter_o],
        ParquetSourceOn[Self.R.FS, Self.cache_o, Self.pool_o, Self.filter_o],
        NoSource,
    ]
    """A Parquet source: over the local file system (first) or over the
    remote store's (second)."""
    comptime Source = SourceVariant[
        Self.ParquetArm,
        BatchSource,
        SinkOutputSource,
    ]
    comptime Op = OpVariant[FilterOp, MapOp, LimitOp, HashProbeOp]
    comptime Sink = PipelineSink[
        CollectSink, AnyAggSink, SortSink, WindowSink, PartitionTopNPipelineSink
    ]

    # The borrowed cache and pool, kept as pointers (private) because a struct
    # field cannot hold a `ref` argument; the caller's objects outlive the
    # builder.
    var _cache: Pointer[ParquetMetadataCache, Self.cache_o]
    var _pool: Pointer[ExprPool, Self.pool_o]
    var _resident: List[RecordBatch]
    var _parts: List[_OpParts]
    var _agg_sinks: List[AggSinkData]
    var _sort_sinks: List[SortSinkData]
    var _topn_sinks: List[TopNSinkData]
    var _window_sinks: List[PartitionBySinkData]
    var _partition_topn_sinks: List[PartitionTopNSinkData]
    var _segment_pool: SegmentPool
    var _opener: Optional[Self.R]
    var _spill_dir: String

    def __init__(
        out self,
        ref [Self.cache_o] cache: ParquetMetadataCache,
        ref [Self.pool_o] pool: ExprPool,
    ):
        """A builder that reads the local file system only."""
        self._cache = Pointer(to=cache)
        self._pool = Pointer(to=pool)
        self._resident = List[RecordBatch]()
        self._parts = List[_OpParts]()
        self._agg_sinks = List[AggSinkData]()
        self._sort_sinks = List[SortSinkData]()
        self._topn_sinks = List[TopNSinkData]()
        self._window_sinks = List[PartitionBySinkData]()
        self._partition_topn_sinks = List[PartitionTopNSinkData]()
        self._segment_pool = SegmentPool()
        self._opener = None
        self._spill_dir = String("")

    def __init__(
        out self,
        ref [Self.cache_o] cache: ParquetMetadataCache,
        ref [Self.pool_o] pool: ExprPool,
        var opener: Self.R,
    ):
        """A builder that reads the local file system and the remote store
        `opener` opens a file system on."""
        self = Self(cache, pool)
        self._opener = Optional[Self.R](opener^)

    def add_agg_sink(mut self, var data: AggSinkData) -> Int:
        """Keep `data` for SINK_AGG segments; returns the id their
        `sink_param_id` names."""
        self._agg_sinks.append(data^)
        return len(self._agg_sinks) - 1

    def add_sort_sink(mut self, var data: SortSinkData) -> Int:
        """Keep `data` for SINK_SORT segments; returns the id their
        `sink_param_id` names."""
        self._sort_sinks.append(data^)
        return len(self._sort_sinks) - 1

    def add_topn_sink(mut self, var data: TopNSinkData) -> Int:
        """Keep `data` for SINK_TOPN segments; returns the id their
        `sink_param_id` names."""
        self._topn_sinks.append(data^)
        return len(self._topn_sinks) - 1
    def add_window_sink(mut self, var data: PartitionBySinkData) -> Int:
        """Keep `data` for SINK_PARTITION_BY segments; returns the id their
        `sink_param_id` names."""
        self._window_sinks.append(data^)
        return len(self._window_sinks) - 1

    def add_partition_topn_sink(mut self, var data: PartitionTopNSinkData) -> Int:
        """Keep `data` for SINK_PARTITION_TOPN segments; returns the id their
        `sink_param_id` names."""
        self._partition_topn_sinks.append(data^)
        return len(self._partition_topn_sinks) - 1

    def set_memory_budget(mut self, bytes: Int):
        """Bound the memory the sinks of later segment runs may draw, in
        bytes (a negative value removes the bound). Replaces the pool, so call
        it between runs."""
        self._segment_pool = SegmentPool(bytes)

    def set_spill_directory(mut self, var dir: String):
        """Let the grouped aggregation sinks of later segment runs spill
        their group tables under `dir` instead of refusing a table the pool
        cannot grow (`sink_group_agg`); the empty string, the default, turns
        spill off. Call it between runs."""
        self._spill_dir = dir^

    def pool_granted(self) -> Int:
        """The bytes the sinks hold from the pool now; zero between runs."""
        return self._segment_pool.granted()

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
                "pipeline_exec: segment "
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
                "pipeline_exec: operator tag "
                + String(Int(spec.tag))
                + " of segment "
                + String(desc.seg_id)
                + " is not served (OP_FILTER, OP_PROJECT and OP_LIMIT are,"
                " and OP_JOIN_PROBE once its segment's source is built)"
            )
        self._parts.append(parts^)
        return len(self._parts) - 1

    def _make_probe_parts(
        mut self, ref desc: SegmentDescPod, mut published: PublishedOutputs
    ) raises:
        """Take the build rows of every OP_JOIN_PROBE of `desc` and index
        them, one shared part per operator."""
        for i in range(desc.num_ops()):
            ref spec = desc.ops[i]
            if spec.tag != OP_JOIN_PROBE:
                continue
            var build_seg = spec.probe_build_seg
            if not _is_dep(desc, build_seg):
                raise Error(
                    "pipeline_exec: the join probe of segment "
                    + String(desc.seg_id)
                    + " reads the build side of segment "
                    + String(build_seg)
                    + ", which is not among its dependencies"
                )
            var parts = _OpParts(desc.seg_id, i)
            parts.probe = Optional(
                HashProbeShared(spec, published.take(build_seg))
            )
            self._parts.append(parts^)

    def build_source(
        mut self,
        ref desc: SegmentDescPod,
        mut published: PublishedOutputs,
        num_workers: Int,
    ) raises -> Self.Source:
        # A segment run starts here. What the operators of an earlier run of
        # this segment shared (a limit's spent row budget) is not theirs.
        self._drop_parts_of(desc.seg_id)
        self._make_probe_parts(desc, published)
        ref spec = desc.source_spec
        var morsel_rows = desc.morsel_rows
        if desc.source_kind == SOURCE_PARQUET:
            if desc.order_key_kind == ORDER_ROW_RANGE and cursor_grain_enabled():
                raise Error(
                    "pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " is ORDER_ROW_RANGE over Parquet while the scan's"
                    " cursor-grain route is on; that route cuts morsels by the"
                    " worker count, so the float sums would not be the same"
                    " bits on every worker count"
                )
            var preserve_dict = (
                desc.sink_kind == SINK_AGG
                and desc.sink_key_dtype == KEY_DTYPE_STRING
                and desc.sink_orientation == SINK_ORIENT_DICT_ENCODED
            )
            if spec.parquet_fs.is_local():
                return Self.Source.first(
                    Self.ParquetArm.first(
                        build_parquet_source[
                            Self.cache_o, Self.pool_o, Self.filter_o
                        ](
                            spec,
                            morsel_rows,
                            num_workers,
                            self._cache[],
                            self._pool[],
                            preserve_dict=preserve_dict,
                        )
                    )
                )
            if not self._opener:
                raise scan_fs_unserved(spec.parquet_fs.url_prefix())
            var fs = self._opener.value().open_scan_fs(
                spec.parquet_fs.scheme, spec.parquet_fs.bucket
            )
            return Self.Source.first(
                Self.ParquetArm.second(
                    build_parquet_source_on[
                        Self.R.FS, Self.cache_o, Self.pool_o, Self.filter_o
                    ](
                        spec,
                        fs^,
                        morsel_rows,
                        num_workers,
                        self._cache[],
                        self._pool[],
                        preserve_dict=preserve_dict,
                    )
                )
            )
        if morsel_rows <= 0:
            morsel_rows = DEFAULT_MORSEL_ROWS
        if desc.source_kind == SOURCE_BATCH:
            var handle = spec.batch_handle_id
            if handle < 0 or handle >= len(self._resident):
                raise Error(
                    "pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " reads resident batch "
                    + String(handle)
                    + ", and the builder holds "
                    + String(len(self._resident))
                )
            return Self.Source.second(
                BatchSource(copy_batch(self._resident[handle]), morsel_rows)
            )
        if desc.source_kind == SOURCE_CSV:
            return Self.Source.second(build_csv_source(spec, morsel_rows))
        if desc.source_kind == SOURCE_ICEBERG:
            return Self.Source.second(build_iceberg_source(spec, morsel_rows))
        if desc.source_kind == SOURCE_JSONL:
            return Self.Source.second(build_jsonl_source(spec, morsel_rows))
        if desc.source_kind == SOURCE_SINK_OUTPUT:
            if len(spec.dep_seg_ids) != 1:
                raise Error(
                    "pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " reads the output of "
                    + String(len(spec.dep_seg_ids))
                    + " segments; a SOURCE_SINK_OUTPUT reads one"
                )
            var producer = spec.dep_seg_ids[0]
            _check_reads_a_dependency(desc, producer)
            return Self.Source.third(
                SinkOutputSource(
                    published.take(producer), producer, morsel_rows
                )
            )
        if desc.source_kind == SOURCE_CONCAT:
            if len(spec.dep_seg_ids) == 0:
                raise Error(
                    "pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " concatenates the outputs of no segment"
                )
            # Every producer is checked before any output is taken, so a
            # refused segment leaves every published output in place.
            for i in range(len(spec.dep_seg_ids)):
                _check_reads_a_dependency(desc, spec.dep_seg_ids[i])
            var batches = Slab[RecordBatch]()
            for i in range(len(spec.dep_seg_ids)):
                batches.append(published.take(spec.dep_seg_ids[i]))
            # The concatenation keeps the first producer's schema; a column is
            # nullable when any producer's is.
            var merged = _nullable_union(batches)
            var concatenated = concat_record_batches_nway(batches^)
            concatenated.schema = merged^
            return Self.Source.third(
                SinkOutputSource(
                    concatenated^,
                    spec.dep_seg_ids[0],
                    morsel_rows,
                )
            )
        raise Error(
            "pipeline_exec: source kind "
            + String(Int(desc.source_kind))
            + " of segment "
            + String(desc.seg_id)
            + " is not served (SOURCE_PARQUET, SOURCE_BATCH,"
            " SOURCE_SINK_OUTPUT, SOURCE_CSV, SOURCE_ICEBERG, SOURCE_CONCAT and"
            " SOURCE_JSONL are)"
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
        if parts.probe:
            return Self.Op.fourth(parts.probe.value().make())
        return Self.Op.third(parts.limit.value().make())

    def build_sink(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema
    ) raises -> Self.Sink:
        var composite = (
            desc.sink_kind == SINK_AGG
            and desc.sink_key_dtype == KEY_DTYPE_COMPOSITE
            and desc.sink_orientation == SINK_ORIENT_COLUMNAR
        )
        if composite or (
            desc.sink_kind == SINK_AGG
            and desc.sink_key_dtype == KEY_DTYPE_STRING
            and (
                desc.sink_orientation == SINK_ORIENT_COLUMNAR
                or desc.sink_orientation == SINK_ORIENT_DICT_ENCODED
            )
        ):
            var id = desc.sink_param_id
            if id < 0 or id >= len(self._agg_sinks):
                raise Error(
                    "pipeline_exec: segment "
                    + String(desc.seg_id)
                    + " names aggregation sink data "
                    + String(id)
                    + ", and the builder holds "
                    + String(len(self._agg_sinks))
                )
            return Self.Sink.second(
                AnyAggSink(
                    StringGroupAggSink(
                        self._agg_sinks[id],
                        desc.sink_orientation == SINK_ORIENT_DICT_ENCODED,
                        self._segment_pool.share(),
                        desc.seg_id,
                        composite=composite,
                        by_position=(desc.order_key_kind == ORDER_ROW_RANGE),
                    )
                )
            )
        if desc.sink_orientation == SINK_ORIENT_COLUMNAR:
            if (
                desc.sink_kind == SINK_COLLECT
                or desc.sink_kind == SINK_HASH_BUILD
            ) and desc.sink_key_dtype == KEY_DTYPE_NONE:
                return Self.Sink.first(
                    CollectSink(self._result_schema(desc, source_schema))
                )
            var key = desc.sink_key_dtype
            var keyed = (
                key == KEY_DTYPE_I64
                or key == KEY_DTYPE_I32
                or key == KEY_DTYPE_F64
                or key == KEY_DTYPE_F32
                or key == KEY_DTYPE_DATE32
                or key == KEY_DTYPE_BOOL
                or key == KEY_DTYPE_DECIMAL128
            )
            if desc.sink_kind == SINK_AGG and (key == KEY_DTYPE_NONE or keyed):
                var id = desc.sink_param_id
                if id < 0 or id >= len(self._agg_sinks):
                    raise Error(
                        "pipeline_exec: segment "
                        + String(desc.seg_id)
                        + " names aggregation sink data "
                        + String(id)
                        + ", and the builder holds "
                        + String(len(self._agg_sinks))
                    )
                if keyed:
                    return Self.Sink.second(
                        AnyAggSink(
                            GroupAggSink(
                                self._agg_sinks[id],
                                key,
                                self._segment_pool.share(),
                                desc.seg_id,
                                spill_dir=self._spill_dir,
                                by_position=(
                                    desc.order_key_kind == ORDER_ROW_RANGE
                                ),
                            )
                        )
                    )
                return Self.Sink.second(
                    AnyAggSink(
                        AggSink(
                            self._agg_sinks[id],
                            self._segment_pool.share(),
                            desc.seg_id,
                            by_position=(
                                desc.order_key_kind == ORDER_ROW_RANGE
                            ),
                        )
                    )
                )
            if desc.sink_kind == SINK_SORT and key == KEY_DTYPE_NONE:
                var id = desc.sink_param_id
                if id < 0 or id >= len(self._sort_sinks):
                    raise Error(
                        "pipeline_exec: segment "
                        + String(desc.seg_id)
                        + " names sort sink data "
                        + String(id)
                        + ", and the builder holds "
                        + String(len(self._sort_sinks))
                    )
                var rows_schema = self._result_schema(desc, source_schema)
                return Self.Sink.third(
                    SortSink(
                        self._sort_sinks[id],
                        self._segment_pool.share(),
                        desc.seg_id,
                        rows_schema^,
                    )
                )
            if desc.sink_kind == SINK_TOPN and key == KEY_DTYPE_NONE:
                var id = desc.sink_param_id
                if id < 0 or id >= len(self._topn_sinks):
                    raise Error(
                        "pipeline_exec: segment "
                        + String(desc.seg_id)
                        + " names top-n sink data "
                        + String(id)
                        + ", and the builder holds "
                        + String(len(self._topn_sinks))
                    )
                var rows_schema = self._result_schema(desc, source_schema)
                return Self.Sink.third(
                    SortSink(
                        self._topn_sinks[id],
                        self._segment_pool.share(),
                        desc.seg_id,
                        rows_schema^,
                    )
                )
            if desc.sink_kind == SINK_PARTITION_BY and key == KEY_DTYPE_NONE:
                var id = desc.sink_param_id
                if id < 0 or id >= len(self._window_sinks):
                    raise Error(
                        "pipeline_exec: segment "
                        + String(desc.seg_id)
                        + " names window sink data "
                        + String(id)
                        + ", and the builder holds "
                        + String(len(self._window_sinks))
                    )
                return Self.Sink.fourth(
                    WindowSink(
                        self._window_sinks[id],
                        self._segment_pool.share(),
                        desc.seg_id,
                    )
                )
            if desc.sink_kind == SINK_PARTITION_TOPN and key == KEY_DTYPE_NONE:
                var id = desc.sink_param_id
                if id < 0 or id >= len(self._partition_topn_sinks):
                    raise Error(
                        "pipeline_exec: segment "
                        + String(desc.seg_id)
                        + " names partition top-n sink data "
                        + String(id)
                        + ", and the builder holds "
                        + String(len(self._partition_topn_sinks))
                    )
                return Self.Sink.fifth(
                    PartitionTopNPipelineSink(
                        self._partition_topn_sinks[id],
                        self._segment_pool.share(),
                        desc.seg_id,
                    )
                )
        raise Error(
            "pipeline_exec: the sink of segment "
            + String(desc.seg_id)
            + " is not served; only (SINK_COLLECT, KEY_DTYPE_NONE,"
            " SINK_ORIENT_COLUMNAR), (SINK_AGG, KEY_DTYPE_NONE, I64, I32,"
            " F64, F32, DATE32, BOOL or DECIMAL128, SINK_ORIENT_COLUMNAR),"
            " (SINK_AGG, KEY_DTYPE_STRING,"
            " SINK_ORIENT_COLUMNAR or SINK_ORIENT_DICT_ENCODED),"
            " (SINK_AGG, KEY_DTYPE_COMPOSITE, SINK_ORIENT_COLUMNAR),"
            " (SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR),"
            " (SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR),"
            " (SINK_PARTITION_BY, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR),"
            " (SINK_PARTITION_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR) and"
            " (SINK_HASH_BUILD, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR) are"
        )

    def op_tail(
        mut self,
        ref desc: SegmentDescPod,
        op_index: Int,
        ref source_schema: Schema,
    ) raises -> List[RecordBatch]:
        """The unmatched build rows of a RIGHT or FULL join probe, in batches
        of the segment's morsel size, with the probe columns NULL at the types
        the chain gives them before the probe; no rows for any other
        operator."""
        if desc.ops[op_index].tag != OP_JOIN_PROBE:
            return List[RecordBatch]()
        var at = self._parts_index(desc, op_index)
        if not self._parts[at].probe.value().has_tail():
            return List[RecordBatch]()
        var probe_schema = self._schema_at(desc, source_schema, op_index)
        var rows = DEFAULT_MORSEL_ROWS
        if desc.morsel_rows > 0:
            rows = desc.morsel_rows
        return self._parts[at].probe.value().unmatched_build_rows(
            probe_schema, rows
        )

    def _schema_at(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema, upto: Int
    ) raises -> Schema:
        """The schema of the rows that reach operator `upto` of the chain (the
        segment's output for `upto` = the operator count): the source's, as
        each projection and join probe before it reshapes it. A projection is
        asked by running it over a batch of no rows; a probe gives its output
        schema."""
        var schema = source_schema.copy()
        for i in range(upto):
            if desc.ops[i].tag == OP_JOIN_PROBE:
                var at = self._parts_index(desc, i)
                schema = self._parts[at].probe.value().output_schema(schema)
                continue
            if desc.ops[i].tag != OP_PROJECT:
                continue
            var at = self._parts_index(desc, i)
            var probe = self._parts[at].project.value().make()
            var m = Morsel(empty_batch_like_schema(schema), 0, 0)
            _ = probe.execute(m)
            schema = m.batch.schema.copy()
        return schema^

    def _result_schema(
        mut self, ref desc: SegmentDescPod, ref source_schema: Schema
    ) -> Optional[Schema]:
        """The schema the segment's rows have (`_schema_at` past the last
        operator), or None when that fails."""
        try:
            return Optional(
                self._schema_at(desc, source_schema, desc.num_ops())
            )
        except:
            return None


def _is_dep(ref desc: SegmentDescPod, seg_id: Int) -> Bool:
    """True when `seg_id` is among `desc`'s dependencies."""
    for i in range(len(desc.deps)):
        if desc.deps[i] == seg_id:
            return True
    return False
