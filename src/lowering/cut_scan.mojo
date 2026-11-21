# =============================================================================
# cut_scan -- the cutter's source arm: PLAN_SCAN opens a pipeline
# =============================================================================
#
# A bounded Parquet scan of one local file, or of several, opens a
# SOURCE_PARQUET pipeline whose spec carries the scan's projection and pushed
# filter; several files are listed in the spec. A scan with Hive partition
# columns lists its files and their partition values too, but pushes no
# projection or filter: both become operators, the filter first, over the full
# schema (the files' columns, then the partition columns). An in-memory scan
# opens a SOURCE_BATCH pipeline over a ParamTable batch handle; the batch arm
# has no pushed filter or projection, so both become operators, the filter
# first, over the batch's full schema.
#
# Refused: an unbounded scan, a Hive-partitioned scan that lists its files
# lazily (a directory scan or a partition predicate) or a Parquet scan on a
# file system other than the local one (LOWERING_SCAN_NOT_TOTAL); a scan
# beyond the inputs' count (LOWERING_INPUTS_SCAN_COUNT); any other source
# (LOWERING_UNCUTTABLE_NODE).
# =============================================================================

from arrow.schema import Field
from containers.slab import Slab
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_INPUTS_SCAN_COUNT,
)
from plan_expr.expr import Expr
from plan_ir.logical_plan import LogicalPlan
from plan_ir.plan_decisions import SCAN_BOUNDED
from physical_plan.physical_plan import (
    SourceSpecPod,
    MorselOp,
    SOURCE_PARQUET,
    SOURCE_BATCH,
)
from scan_source.source_variant import (
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
)


def _project_op(cols: List[String]) -> MorselOp:
    """The PROJECT operator that keeps `cols`, in that order."""
    var exprs = Slab[Expr]()
    var names = List[String]()
    for i in range(len(cols)):
        exprs.append(Expr.col_ref(cols[i]))
        names.append(String(cols[i]))
    return MorselOp.project(exprs^, names^)


def _open_scan(
    mut cutter: _Cutter, node: LogicalPlan, inputs: LoweringInputs
) raises -> _Pipe:
    """The pipeline a PLAN_SCAN node opens."""
    ref sd = node.scan_data_ref()
    var idx = cutter.scans_seen
    cutter.scans_seen += 1
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
        if ps.hive_dir_scan or Bool(ps.hive_predicate):
            raise Error(
                String(LOWERING_SCAN_NOT_TOTAL)
                + ": a Hive-partitioned Parquet scan that lists its files"
                " lazily (a directory scan or a partition predicate); the"
                " segment's Parquet arm carries the file list"
            )
        if not ps.fs_descriptor.is_local():
            raise Error(
                String(LOWERING_SCAN_NOT_TOTAL)
                + ": a Parquet scan on a file system other than the local"
                " one; the segment's Parquet arm carries no descriptor"
            )
        if len(ps.partition_cols) > 0:
            # The source appends partition columns only when it decodes a
            # plain batch and resolves a projection against the first file's
            # footer, so neither a projection nor a filter is pushed: both
            # become operators, the filter first, over the full schema (the
            # files' columns, then the partition columns).
            var pipe = _Pipe(
                SOURCE_PARQUET,
                SourceSpecPod.parquet_files(
                    ps.paths.copy(),
                    ps.partition_cols.copy(),
                    ps.partition_values.copy(),
                    None,
                    None,
                ),
                node.output_schema.copy(),
                idx,
            )
            if pushed:
                pipe.append_op(MorselOp.filter(pushed.take()))
            if proj:
                pipe.append_op(_project_op(proj.value()))
                pipe.has_project = True
            return pipe^
        if len(ps.paths) != 1:
            return _Pipe(
                SOURCE_PARQUET,
                SourceSpecPod.parquet_files(
                    ps.paths.copy(),
                    List[Field](),
                    List[List[String]](),
                    proj^,
                    pushed^,
                ),
                node.output_schema.copy(),
                idx,
            )
        return _Pipe(
            SOURCE_PARQUET,
            SourceSpecPod.parquet(String(ps.paths[0]), proj^, pushed^, True),
            node.output_schema.copy(),
            idx,
        )
    if sd.source.tag == SOURCE_VARIANT_IN_MEMORY:
        var handle = len(cutter.params.batches)
        cutter.params.batches.append(sd.source._in_memory.value().copy())
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
            pipe.append_op(_project_op(proj.value()))
            pipe.has_project = True
            pipe.schema = node.output_schema.copy()
        return pipe^
    raise _uncuttable(node, "a " + sd.source.kind_name() + " source")
