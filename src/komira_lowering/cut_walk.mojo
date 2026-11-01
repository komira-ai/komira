# =============================================================================
# cut_walk -- the cutter: a bound plan to segments, edges and a ParamTable
# =============================================================================
#
# One walk of the plan, bottom up. Every node is one of three roles:
#
#   source    PLAN_SCAN: opens a pipeline (SOURCE_PARQUET, or SOURCE_BATCH for
#             an in-memory scan);
#   streaming PLAN_FILTER, PLAN_PROJECT, PLAN_LIMIT: appended to the open
#             pipeline's `ops`;
#   breaker   PLAN_AGGREGATE, PLAN_SORT: ends the open pipeline in a sink and
#             opens a pipeline whose source is that segment's output
#             (SOURCE_SINK_OUTPUT), joined by an E3 edge.
#
# The root is a SINK_COLLECT segment, unless the plan's top node is a breaker:
# then that breaker's segment is the result and nothing is appended.
#
# Any other node is refused with LOWERING_UNCUTTABLE_NODE naming its tag. The
# cutter never replaces a node it cannot cut by a resident batch or a generic
# collect.
#
# A limit above a sort (with only filters and projections between) is refused:
# a segment records no order, so the rows a limit would keep are not defined.
#
# Segment ids are dense and follow the cut order, which is dependency order:
# a producer is cut before its consumer. Every segment is ORDER_NONE with one
# partition. A float SUM or AVG is therefore cut with ORDER_NONE: its result
# is not bit-reproducible across worker counts until a segment can carry
# ORDER_ROW_RANGE. `card_estimate_rows` is the row count of the scan's footers when
# the host supplied one, an upper bound on the rows that reach the sink, and 0
# otherwise; `mem_estimate_bytes` is 0 (no memory decision is recorded).
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from komira_lowering.sum_fuse import lowered_agg_expr
from komira_lowering.lowered_plan import (
    LoweredPlan,
    LoweringInputs,
    ParamTable,
    LOWERING_UNCUTTABLE_NODE,
    LOWERING_SINK_UNSERVED,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_INPUTS_SCAN_COUNT,
)
from komira_plan_expr.agg_expr import AGG_UDF
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    AggExprArray,
    copy_expr_array,
    plan_tag_name,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
)
from komira_plan_ir.logical_plan_variants import AggregateData
from komira_plan_ir.plan_decisions import (
    AGG_MODE_UNSET,
    AGG_MODE_SINGLE,
    SCAN_BOUNDED,
)
from komira_physical_plan.physical_plan import (
    SegmentDescPod,
    SourceSpecPod,
    MorselOp,
    AggSinkData,
    SortSinkData,
    SOURCE_PARQUET,
    SOURCE_BATCH,
    SOURCE_SINK_OUTPUT,
    SINK_AGG,
    SINK_SORT,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SINK_ORIENT_DICT_ENCODED,
    KEY_DTYPE_NONE,
    KEY_DTYPE_I64,
    KEY_DTYPE_I32,
    KEY_DTYPE_F64,
    KEY_DTYPE_F32,
    KEY_DTYPE_STRING,
    EDGE_E3_PUBLISH_WAIT,
    ORDER_NONE,
)
from komira_scan_source.source_variant import (
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
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
    source is a breaker's output."""
    var has_project: Bool
    var sorted_input: Bool
    """True while the rows the pipeline delivers are a sort's output in that
    sort's order: set when the pipeline opens on a sort, kept by every
    operator fused onto it, and false when it opens on an aggregation."""
    var broken_by: Int
    """The segment whose output this pipeline is, while no operator has been
    appended to it; -1 otherwise."""

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

    def append_op(mut self, var op: MorselOp):
        self.ops.append(op^)
        self.broken_by = -1

    def into_segment(
        deinit self,
        seg_id: Int,
        sink_kind: UInt8,
        key_dtype: UInt8,
        orientation: UInt8,
        param_id: Int,
        card_estimate_rows: Int,
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
            ORDER_NONE,
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


def _key_dtype_of(arrow_type: ArrowType) -> Int:
    """The `KEY_DTYPE_*` of a group key column of this type, or -1."""
    if arrow_type == ArrowType.INT64:
        return Int(KEY_DTYPE_I64)
    if arrow_type == ArrowType.INT32:
        return Int(KEY_DTYPE_I32)
    if arrow_type == ArrowType.FLOAT64:
        return Int(KEY_DTYPE_F64)
    if arrow_type == ArrowType.FLOAT32:
        return Int(KEY_DTYPE_F32)
    if arrow_type == ArrowType.STRING:
        return Int(KEY_DTYPE_STRING)
    return -1


def _unserved(what: String) -> Error:
    return Error(String(LOWERING_SINK_UNSERVED) + ": " + what)


struct _Triple(Copyable, Movable):
    var key_dtype: UInt8
    var orientation: UInt8

    def __init__(out self, key_dtype: UInt8, orientation: UInt8):
        self.key_dtype = key_dtype
        self.orientation = orientation


def _is_dictionary_key(
    key: Expr, pipe: _Pipe, inputs: LoweringInputs
) -> Bool:
    """True when `key` is a column of the pipeline's Parquet scan that every
    row group of every pinned file stores dictionary encoded. A pipeline with
    a PROJECT in it, or one that reads a breaker's output, is never dictionary
    encoded: the name may no longer mean the scan's column."""
    if pipe.scan_index < 0 or pipe.has_project:
        return False
    if pipe.source_kind != SOURCE_PARQUET:
        return False
    if not key.is_col_ref():
        return False
    var name = key.col_ref_name()
    ref cols = inputs.scans[pipe.scan_index].dict_encoded_columns
    for i in range(len(cols)):
        if cols[i] == name:
            return True
    return False


def _agg_triple(
    ad: AggregateData,
    out_schema: Schema,
    pipe: _Pipe,
    inputs: LoweringInputs,
) raises -> _Triple:
    """The `(key_dtype, orientation)` of an aggregation's sink. The group key
    columns are the first columns of the node's output schema."""
    var n = len(ad.group_by)
    if n == 0:
        return _Triple(KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
    var all_dictionary_strings = True
    var first = -1
    for i in range(n):
        var t = out_schema.field_at_unchecked(i).arrow_type
        var d = _key_dtype_of(t)
        if d < 0:
            raise _unserved(
                "a group key column of type " + String(t) + " has no sink row"
            )
        if i == 0:
            first = d
        if d != Int(KEY_DTYPE_STRING) or not _is_dictionary_key(
            ad.group_by[i], pipe, inputs
        ):
            all_dictionary_strings = False
    if n > 1:
        if not all_dictionary_strings:
            raise _unserved(
                "a group key of "
                + String(n)
                + " columns is served only when every column is a dictionary"
                " encoded string"
            )
        return _Triple(KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED)
    if first == Int(KEY_DTYPE_STRING):
        if all_dictionary_strings:
            return _Triple(KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED)
        return _Triple(KEY_DTYPE_STRING, SINK_ORIENT_COLUMNAR)
    return _Triple(UInt8(first), SINK_ORIENT_COLUMNAR)


struct _Cutter(Movable):
    var segments: List[SegmentDescPod]
    var flow_schemas: List[Schema]
    var params: ParamTable
    var scans_seen: Int

    def __init__(out self):
        self.segments = List[SegmentDescPod]()
        self.flow_schemas = List[Schema]()
        self.params = ParamTable()
        self.scans_seen = 0

    def finish(deinit self, result_seg_id: Int) -> CutResult:
        return CutResult(
            self.segments^, self.flow_schemas^, self.params^, result_seg_id
        )

    def walk(
        mut self, node: LogicalPlan, inputs: LoweringInputs
    ) raises -> _Pipe:
        var tag = node.tag
        if tag == PLAN_SCAN:
            return self._scan(node, inputs)
        if tag == PLAN_FILTER:
            ref fd = node.filter_data_ref()
            if fd.has_udf():
                raise _uncuttable(node, "a filter with a UDF")
            var pipe = self.walk(fd.child[], inputs)
            pipe.append_op(MorselOp.filter(fd.predicate.copy()))
            return pipe^
        if tag == PLAN_PROJECT:
            ref pd = node.project_data_ref()
            if pd.has_udf():
                raise _uncuttable(node, "a projection with a UDF")
            var pipe = self.walk(pd.child[], inputs)
            var names = List[String]()
            for i in range(node.output_schema.num_columns()):
                names.append(node.output_schema.field_name(i))
            pipe.append_op(
                MorselOp.project(copy_expr_array(pd.exprs), names^)
            )
            pipe.has_project = True
            pipe.schema = node.output_schema.copy()
            return pipe^
        if tag == PLAN_LIMIT:
            ref ld = node.limit_data_ref()
            if ld.offset != 0:
                raise _uncuttable(node, "a limit with an offset")
            if ld.n < 0:
                raise _uncuttable(node, "a limit with a negative count")
            var pipe = self.walk(ld.child[], inputs)
            if pipe.sorted_input:
                raise _uncuttable(
                    node,
                    "a limit over a sorted stream; no order is recorded on"
                    " a segment",
                )
            pipe.append_op(MorselOp.limit(ld.n))
            return pipe^
        if tag == PLAN_AGGREGATE:
            return self._aggregate(node, inputs)
        if tag == PLAN_SORT:
            ref sd = node.sort_data_ref()
            var pipe = self.walk(sd.child[], inputs)
            var pid = len(self.params.sort)
            self.params.sort.append(
                SortSinkData(
                    sd.keys.copy(),
                    sd.descending.copy(),
                    0,
                    sd.nulls_first.copy(),
                )
            )
            var seg = self._close(
                pipe^, SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, pid, inputs
            )
            var reopened = self._reopen(seg, node.output_schema)
            reopened.sorted_input = True
            return reopened^
        raise _uncuttable(node, "no cutter arm for this node")

    def _aggregate(
        mut self, node: LogicalPlan, inputs: LoweringInputs
    ) raises -> _Pipe:
        ref ad = node.aggregate_data_ref()
        if ad.has_udf():
            raise _uncuttable(node, "an aggregation with a UDF")
        if ad.group_topk:
            raise _uncuttable(node, "an aggregation with a group top-k")
        if ad.mode != AGG_MODE_UNSET and ad.mode != AGG_MODE_SINGLE:
            raise _uncuttable(node, "a partial or final aggregation")
        var aggs = AggExprArray()
        for i in range(len(ad.agg_exprs)):
            if ad.agg_exprs[i].func == AGG_UDF:
                raise _uncuttable(node, "a UDF aggregate function")
            # SUM(CAST(<signed integer> AS DECIMAL(38, 0))), the SQL integer
            # sum, runs as the integer fold (`sum_fuse`); the declared output
            # type is the node's and stays DECIMAL(38, 0).
            aggs.append(
                lowered_agg_expr(ad.agg_exprs[i], ad.child[].output_schema)
            )
        var pipe = self.walk(ad.child[], inputs)
        var triple = _agg_triple(ad, node.output_schema, pipe, inputs)
        var pid = len(self.params.agg)
        self.params.agg.append(
            AggSinkData(
                copy_expr_array(ad.group_by), aggs^, node.output_schema.copy()
            )
        )
        var seg = self._close(
            pipe^, SINK_AGG, triple.key_dtype, triple.orientation, pid, inputs
        )
        return self._reopen(seg, node.output_schema)

    def _scan(
        mut self, node: LogicalPlan, inputs: LoweringInputs
    ) raises -> _Pipe:
        ref sd = node.scan_data_ref()
        var idx = self.scans_seen
        self.scans_seen += 1
        if idx >= len(inputs.scans):
            raise Error(
                String(LOWERING_INPUTS_SCAN_COUNT)
                + ": the plan has more than "
                + String(len(inputs.scans))
                + " scans"
            )
        var proj: Optional[List[String]] = None
        if sd.projection:
            proj = Optional(sd.projection.value().copy())
        var pushed: Optional[Expr] = None
        if sd.filter:
            pushed = Optional(sd.filter.value().copy())
        if sd.boundedness != SCAN_BOUNDED:
            raise Error(
                String(LOWERING_SCAN_NOT_TOTAL)
                + ": an unbounded scan; the segment's source arms read a"
                " bounded input"
            )
        if sd.source.tag == SOURCE_VARIANT_PARQUET:
            ref ps = sd.source._parquet.value()
            if len(ps.paths) != 1:
                raise Error(
                    String(LOWERING_SCAN_NOT_TOTAL)
                    + ": a Parquet scan of "
                    + String(len(ps.paths))
                    + " files; the segment's Parquet arm names one"
                )
            if (
                len(ps.partition_cols) > 0
                or len(ps.partition_values) > 0
                or ps.hive_dir_scan
                or Bool(ps.hive_predicate)
            ):
                raise Error(
                    String(LOWERING_SCAN_NOT_TOTAL)
                    + ": a Hive-partitioned Parquet scan; the segment's"
                    " Parquet arm carries no partition columns"
                )
            if not ps.fs_descriptor.is_local():
                raise Error(
                    String(LOWERING_SCAN_NOT_TOTAL)
                    + ": a Parquet scan on a file system other than the local"
                    " one; the segment's Parquet arm carries no descriptor"
                )
            return _Pipe(
                SOURCE_PARQUET,
                SourceSpecPod.parquet(
                    String(ps.paths[0]), proj^, pushed^, True
                ),
                node.output_schema.copy(),
                idx,
            )
        if sd.source.tag == SOURCE_VARIANT_IN_MEMORY:
            var handle = len(self.params.batches)
            self.params.batches.append(sd.source._in_memory.value().copy())
            # The batch arm has no pushed filter or projection: both become
            # operators, the filter first, over the batch's full schema.
            var full = sd.source._in_memory.value().schema()
            var pipe = _Pipe(
                SOURCE_BATCH,
                SourceSpecPod.batch(handle),
                full.copy(),
                idx,
            )
            if pushed:
                pipe.append_op(MorselOp.filter(pushed.take()))
            if proj:
                var exprs = Slab[Expr]()
                var names = List[String]()
                ref cols = proj.value()
                for i in range(len(cols)):
                    exprs.append(Expr.col_ref(cols[i]))
                    names.append(String(cols[i]))
                pipe.append_op(MorselOp.project(exprs^, names^))
                pipe.has_project = True
                pipe.schema = node.output_schema.copy()
            return pipe^
        raise _uncuttable(node, "a " + sd.source.kind_name() + " source")

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
    ) -> Int:
        """End `pipe` in a sink and record it as the next segment."""
        var seg_id = len(self.segments)
        var card = 0
        if pipe.scan_index >= 0:
            ref stats = inputs.scans[pipe.scan_index].stats
            if stats:
                card = stats.value().row_count
        self.flow_schemas.append(pipe.schema.copy())
        self.segments.append(
            pipe^.into_segment(
                seg_id, sink_kind, key_dtype, orientation, param_id, card
            )
        )
        return seg_id


def cut_plan(plan: LogicalPlan, inputs: LoweringInputs) raises -> CutResult:
    """Cut `plan` into segments. Raises a named refusal for a node it does not
    cut, a sink no row serves, a scan the Parquet arm cannot carry, or an
    `inputs` whose scan count is not the plan's."""
    var cutter = _Cutter()
    var pipe = cutter.walk(plan, inputs)
    if cutter.scans_seen != len(inputs.scans):
        raise Error(
            String(LOWERING_INPUTS_SCAN_COUNT)
            + ": the plan has "
            + String(cutter.scans_seen)
            + " scans and the inputs hold "
            + String(len(inputs.scans))
        )
    var result = pipe.broken_by
    if result < 0:
        result = cutter._close(
            pipe^, SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, inputs
        )
    return cutter^.finish(result)
