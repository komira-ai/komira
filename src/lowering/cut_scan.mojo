# =============================================================================
# cut_scan -- the cutter's source arm: PLAN_SCAN opens a pipeline
# =============================================================================
#
# A bounded Parquet scan of one local file, or of several, opens a
# SOURCE_PARQUET pipeline whose spec carries the scan's projection and pushed
# filter; several files are listed in the spec. A scan of objects in an S3
# or GCS bucket or an Azure container is cut the same way, and the spec
# carries the scan's descriptor (`parquet_fs`): its paths are then object keys
# in that bucket, which the engine reads through the file system it is handed
# for the bucket. A scan with Hive partition
# columns lists its files and their partition values too, but pushes no
# projection or filter: both become operators, the filter first, over the full
# schema (the files' columns, then the partition columns). An in-memory scan
# opens a SOURCE_BATCH pipeline over a ParamTable batch handle. A CSV scan
# (`read_csv`) opens a SOURCE_CSV pipeline whose spec carries the file's path,
# its dialect (delimiter, header, quote style, lines skipped) and every column of the file
# with the type the plan bound it at, so the reader decodes at the bound
# schema and never infers a second one. A scan of an Iceberg table (a binding
# of kind `komira.iceberg.table`) opens a SOURCE_ICEBERG pipeline whose spec is
# the one the host planned before lowering (`ScanFacts.iceberg`: the data files
# that survive pruning, the delete files that apply, the bound columns); this
# module reads no table metadata and does not depend on the package that does.
# None of the batch, CSV and Iceberg arms has a pushed filter or projection, so
# each becomes operators, the filter first, over the source's full schema. The
# filter an Iceberg scan pushed is kept as an operator because the planner uses
# it only to skip files.
# A scan of one newline-delimited JSON file opens a SOURCE_JSONL pipeline
# (`cut_scan_jsonl`).
#
# Refused: an unbounded scan, a Hive-partitioned scan that lists its files
# lazily (a directory scan or a partition predicate) or a Parquet scan on a
# store other than the local file system, S3, GCS and Azure (a scheme code
# that names none of them), or with an explicit local binding
# (LOWERING_SCAN_NOT_TOTAL); a scan
# beyond the inputs' count (LOWERING_INPUTS_SCAN_COUNT); a CSV scan with
# header=false, whose columns the reader would not name as DuckDB does, and
# any other source
# (LOWERING_UNCUTTABLE_NODE); an Iceberg scan whose files the inputs do not
# carry (LOWERING_SCAN_NOT_TOTAL).
# =============================================================================

from arrow.schema import Field
from containers.slab import Slab
from lowering.cut_scan_jsonl import _open_jsonl_scan
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_INPUTS_SCAN_COUNT,
)
from plan_expr.expr import Expr
from plan_expr.fs_descriptor_pod import (
    FS_SCHEME_AZURE,
    FS_SCHEME_GCS,
    FS_SCHEME_S3,
    FsDescriptorPod,
)
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
    SOURCE_ICEBERG,
)
from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from scan_source.csv_source import (
    CSV_DEFAULT_DELIMITER,
    CSV_DEFAULT_HAS_HEADER,
    CSV_DEFAULT_SKIP,
)
from scan_source.source_variant import (
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_BINDING,
    SOURCE_VARIANT_JSON,
)

comptime ICEBERG_TABLE_KIND_NAME: StaticString = "komira.iceberg.table"
"""The kind name of the binding an Iceberg table scan carries. Spelled here
rather than imported: lowering does not depend on the package that reads
Iceberg tables."""


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
        var fs = _carried_fs(ps.fs_descriptor)
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
                    fs^,
                ),
                node.output_schema.copy(),
                idx,
            )
            _scan_ops(pipe, node, pushed^, proj^)
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
                    fs^,
                ),
                node.output_schema.copy(),
                idx,
            )
        return _Pipe(
            SOURCE_PARQUET,
            SourceSpecPod.parquet(
                String(ps.paths[0]), proj^, pushed^, True, fs^
            ),
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
    if (
        sd.source.tag == SOURCE_VARIANT_BINDING
        and sd.source.binding_ref().kind_name == String(ICEBERG_TABLE_KIND_NAME)
    ):
        if not inputs.scans[idx].iceberg:
            raise Error(
                String(LOWERING_SCAN_NOT_TOTAL)
                + ": an Iceberg scan whose files were not planned"
            )
        var pipe = _Pipe(
            SOURCE_ICEBERG,
            SourceSpecPod.iceberg(inputs.scans[idx].iceberg.value().copy()),
            sd.source.schema(),
            idx,
        )
        _scan_ops(pipe, node, pushed^, proj^)
        return pipe^
    if sd.source.tag == SOURCE_VARIANT_JSON:
        return _open_jsonl_scan(node, idx, proj^, pushed^)
    raise _uncuttable(node, "a " + sd.source.kind_name() + " source")


def _carried_fs(desc: FsDescriptorPod) raises -> FsDescriptorPod:
    """The store a Parquet segment's spec names for a scan with `desc`: the
    local file system, an S3 or GCS bucket, or an Azure container.

    Raises:
        `LOWERING_SCAN_NOT_TOTAL`, naming the store, for any other store (the
        engine has no file system for it) and for a local scan with an
        explicit binding (its node id names a resolver the segment does not
        carry).
    """
    if desc.is_local():
        return FsDescriptorPod.local()
    if (
        desc.scheme == FS_SCHEME_S3
        or desc.scheme == FS_SCHEME_GCS
        or desc.scheme == FS_SCHEME_AZURE
    ):
        return desc.copy()
    raise Error(
        String(LOWERING_SCAN_NOT_TOTAL)
        + ": a Parquet scan on "
        + desc.url_prefix()
        + "; the segment's Parquet arm reads the local file system, S3, GCS"
        " and Azure"
    )


def _scan_ops(
    mut pipe: _Pipe,
    node: LogicalPlan,
    var pushed: Optional[Expr],
    var proj: Optional[List[String]],
) raises:
    """The scan's pushed filter and projection as operators of `pipe`, the
    filter first, over the source's full schema: the batch, CSV and Iceberg arms
    carry neither."""
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
    header, and no line skipped."""
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
        Int(params.get_i64(String("skip"), Int64(CSV_DEFAULT_SKIP))),
    ))
