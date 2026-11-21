# =============================================================================
# cut_scan -- the cutter's source arm: PLAN_SCAN opens a pipeline
# =============================================================================
#
# A bounded Parquet scan of one local file opens a SOURCE_PARQUET pipeline
# whose spec carries the scan's projection and pushed filter. An in-memory scan
# opens a SOURCE_BATCH pipeline over a ParamTable batch handle. A CSV scan
# (`read_csv`) opens a SOURCE_CSV pipeline whose spec carries the file's path,
# its dialect (delimiter, header, quote style) and every column of the file
# with the type the plan bound it at, so the reader decodes at the bound
# schema and never infers a second one. Neither the batch arm nor the CSV arm
# has a pushed filter or projection, so both become operators, the filter
# first, over the source's full schema.
#
# Refused: an unbounded scan, a Parquet scan of several files, a
# Hive-partitioned one or one on a file system other than the local one
# (LOWERING_SCAN_NOT_TOTAL); a scan beyond the inputs' count
# (LOWERING_INPUTS_SCAN_COUNT); a CSV scan with header=false, whose columns
# the reader would not name as DuckDB does, and any other source
# (LOWERING_UNCUTTABLE_NODE).
# =============================================================================

from containers.slab import Slab
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_INPUTS_SCAN_COUNT,
)
from plan_expr.expr import Expr
from plan_ir.logical_plan import LogicalPlan
from scan_source.source_variant import SourceVariant
from plan_ir.plan_decisions import SCAN_BOUNDED
from physical_plan.csv_source_spec import CsvSourceSpec
from physical_plan.physical_plan import (
    SourceSpecPod,
    MorselOp,
    SOURCE_PARQUET,
    SOURCE_BATCH,
    SOURCE_CSV,
)
from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from scan_source.csv_source import CSV_DEFAULT_DELIMITER, CSV_DEFAULT_HAS_HEADER
from scan_source.source_variant import (
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_CSV,
)


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
            SourceSpecPod.parquet(String(ps.paths[0]), proj^, pushed^, True),
            node.output_schema.copy(),
            idx,
        )
    if sd.source.tag == SOURCE_VARIANT_IN_MEMORY:
        var handle = len(cutter.params.batches)
        cutter.params.batches.append(sd.source._in_memory.value().copy())
        var pipe = _Pipe(
            SOURCE_BATCH,
            SourceSpecPod.batch(handle),
            sd.source._in_memory.value().schema(),
            idx,
        )
        _scan_ops(pipe, node, pushed^, proj^)
        return pipe^
    if sd.source.tag == SOURCE_VARIANT_CSV:
        var full = sd.source.schema()
        var spec = _csv_spec(sd.source, full)
        if not spec.csv_spec.has_header:
            # The reader names such a file's columns col_0, col_1, ...;
            # DuckDB names them column0, column1, ..., so the answer would
            # not be DuckDB's. Refused until the names agree.
            raise _uncuttable(
                node,
                "a CSV scan with header=false (its columns would be named"
                " col_0, col_1, ..., not DuckDB's column0, column1, ...)",
            )
        var pipe = _Pipe(SOURCE_CSV, spec^, full.copy(), idx)
        _scan_ops(pipe, node, pushed^, proj^)
        return pipe^
    raise _uncuttable(node, "a " + sd.source.kind_name() + " source")


def _scan_ops(
    mut pipe: _Pipe,
    node: LogicalPlan,
    var pushed: Optional[Expr],
    var proj: Optional[List[String]],
) raises:
    """The scan's pushed filter and projection as operators of `pipe`, the
    filter first, over the source's full schema: the batch and CSV arms carry
    neither."""
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


def _csv_spec(source: SourceVariant, full: Schema) -> SourceSpecPod:
    """The SOURCE_CSV spec of a `komira.csv` scan: the file, the dialect its
    binding records and every column of `full` (the schema the plan bound the
    file at, in file order).

    A missing dialect parameter means the CSV default (a comma, a header row,
    RFC 4180), as the row reader's options walker reads it, never the
    parameter table's own default of 0, which would be a NUL delimiter and no
    header."""
    ref params = source.binding_ref().params
    var names = List[String]()
    var types = List[ArrowType]()
    for i in range(full.num_columns()):
        names.append(full.field_name(i))
        types.append(full.field_arrow_type(i))
    return SourceSpecPod.csv(CsvSourceSpec(
        params.get_str(String("path")),
        UInt8(
            Int(
                params.get_i64(
                    String("delimiter"), Int64(Int(CSV_DEFAULT_DELIMITER))
                )
            )
        ),
        params.get_i64(
            String("has_header"),
            Int64(Int(CSV_DEFAULT_HAS_HEADER)),
        )
        != Int64(0),
        Int(params.get_i64(String("quote_style_tag"), Int64(0))),
        names^,
        types^,
    ))
