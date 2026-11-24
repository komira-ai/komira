# =============================================================================
# iceberg_scan/scan_planner.mojo -- the files of one pinned snapshot
# =============================================================================
#
# WHAT THIS IS. `plan_iceberg_scan` turns a `komira.iceberg.table` binding and
# the scan's pushed filter into the `IcebergScanSpec` a segment reads: the data
# files worth reading, in a fixed order, and the delete files that apply to
# them. It is the scan planning the table spec describes
# (docs/design/iceberg_tables.md, "Pruning"), run in the session's own process.
#
# THE STAGES.
#   1. The binding's metadata file is read again and the snapshot and schema
#      are re-pinned (`iceberg_pinned_table_of`). A table with no snapshot has
#      no files: the spec carries the columns and no file.
#   2. The snapshot's manifest list (or, in a v1 table, its inline manifests) is
#      read. A data manifest whose partition summaries cannot match the filter
#      is skipped without being opened.
#   3. Each remaining manifest's entries are read; DELETED entries are dropped;
#      a data file whose partition tuple or column metrics cannot match is
#      skipped. A delete file is never skipped by the filter: the filter
#      describes data rows, not the rows a delete file names.
#   4. Delete files are matched to the remaining data files:
#        * a position delete applies when the data file's sequence number is at
#          or below the delete's, and either it names the data file
#          (`referenced_data_file`) or, when it names none, it has the data
#          file's spec and partition tuple;
#        * an equality delete applies when the data file's sequence number is
#          strictly below the delete's, and it was written under an
#          unpartitioned spec or has the data file's spec and partition tuple.
#      A delete file that applies to no remaining data file is not listed.
#   5. Equality ids become bound column names.
#
# ORDER. Data files are listed in manifest-list order, then entry order, so two
# plans of one snapshot list the same files in the same order; delete files in
# the order of their entries.
#
# REFUSALS. A data file that is not Parquet, or a delete file that is neither
# Parquet nor Avro (Puffin deletion vectors), is
# `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED` naming the format and the file; so is
# an equality delete over a field id the scanned schema does not hold. The
# check is made on the files a scan would read, after the skipping above.
# =============================================================================

from plan_expr.expr import Expr
from physical_plan.iceberg_scan_spec import (
    IcebergScanSpec,
    IcebergDataFileSpec,
    IcebergDeleteSpec,
)
from scan_source.scan_binding import ScanBinding

from .avro_datum import ICEBERG_MANIFEST_INVALID
from .local_file import read_local_file
from .manifests import (
    CONTENT_DATA,
    CONTENT_EQUALITY_DELETES,
    CONTENT_POSITION_DELETES,
    ENTRY_DELETED,
    IcebergFileEntry,
    IcebergManifestFile,
    read_manifest,
    read_manifest_list,
)
from .prune import entry_may_match, manifest_may_match, prune_predicates_of
from .table_metadata import (
    IcebergSnapshotDef,
    IcebergTableMetadata,
    OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED,
)
from .table_ref import IcebergTableRef, iceberg_pinned_table_of, local_path_of


struct IcebergPlanCounts(Copyable, Movable):
    """What a plan did, for tests and EXPLAIN."""

    var manifests_read: Int
    """Manifests opened (data and delete)."""
    var manifests_skipped: Int
    """Data manifests skipped by their partition summaries."""
    var data_files: Int
    """Data files listed."""
    var data_files_skipped: Int
    """Live data files skipped by their partition tuple or metrics."""
    var delete_files: Int
    """Delete files listed."""

    def __init__(out self):
        self.manifests_read = 0
        self.manifests_skipped = 0
        self.data_files = 0
        self.data_files_skipped = 0
        self.delete_files = 0


struct IcebergPlannedScan(Movable):
    var spec: IcebergScanSpec
    var counts: IcebergPlanCounts

    def __init__(
        out self, var spec: IcebergScanSpec, var counts: IcebergPlanCounts
    ):
        self.spec = spec^
        self.counts = counts^


def _unsupported(what: String) -> Error:
    return Error(OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED + String(": ") + what)


def _read_file(uri: String, table: IcebergTableRef, what: String) raises -> List[UInt8]:
    var path = local_path_of(uri, table)
    try:
        return read_local_file(path)
    except:
        raise Error(
            ICEBERG_MANIFEST_INVALID
            + String(": cannot read the ")
            + what
            + String(" '")
            + uri
            + String("'")
        )


def _manifests_of(
    snap: IcebergSnapshotDef, table: IcebergTableRef, md: IcebergTableMetadata
) raises -> List[IcebergManifestFile]:
    if snap.manifest_list.byte_length() > 0:
        var raw = _read_file(snap.manifest_list, table, String("manifest list"))
        return read_manifest_list(Span(raw), md.format_version)
    # A v1 snapshot may list its manifests inline: no summaries, no sequence
    # numbers, the table's one spec.
    var out = List[IcebergManifestFile]()
    for i in range(len(snap.manifests)):
        var m = IcebergManifestFile()
        m.path = snap.manifests[i]
        m.spec_id = md.default_spec_id
        out.append(m^)
    return out^


def _same_partition(a: IcebergFileEntry, b: IcebergFileEntry) -> Bool:
    if a.spec_id != b.spec_id or len(a.partition) != len(b.partition):
        return False
    for k in range(len(a.partition)):
        var av = a.partition[k].copy()
        var bv = b.partition[k].copy()
        if Bool(av) != Bool(bv):
            return False
        if av and av.value() != bv.value():
            return False
    return True


def _same_file(a: String, b: String, table: IcebergTableRef) -> Bool:
    """Whether two stored paths name one file, as the table resolves them."""
    try:
        return local_path_of(a, table) == local_path_of(b, table)
    except:
        return a == b


def _delete_applies(
    d: IcebergFileEntry,
    f: IcebergFileEntry,
    d_unpartitioned: Bool,
    table: IcebergTableRef,
) -> Bool:
    if d.content == CONTENT_POSITION_DELETES:
        if f.data_sequence_number > d.data_sequence_number:
            return False
        if d.referenced_data_file:
            return _same_file(d.referenced_data_file.value(), f.file_path, table)
        return _same_partition(d, f)
    # Equality deletes see only the data written before them.
    if f.data_sequence_number >= d.data_sequence_number:
        return False
    return d_unpartitioned or _same_partition(d, f)


def _equality_columns(
    d: IcebergFileEntry, table: IcebergTableRef
) raises -> List[String]:
    if len(d.equality_ids) == 0:
        raise Error(
            ICEBERG_MANIFEST_INVALID
            + String(": the equality delete file ")
            + d.file_path
            + String(" lists no equality_ids")
        )
    var names = List[String]()
    for k in range(len(d.equality_ids)):
        var found = False
        for c in range(len(table.columns)):
            if table.columns[c].id == d.equality_ids[k]:
                names.append(table.columns[c].name)
                found = True
                break
        if not found:
            raise _unsupported(
                String("the equality delete file ")
                + d.file_path
                + String(" compares field id ")
                + String(d.equality_ids[k])
                + String(", which the scanned schema does not hold")
            )
    return names^


def plan_iceberg_scan(
    binding: ScanBinding, filter: Optional[Expr]
) raises -> IcebergPlannedScan:
    """Plan the files of the pinned snapshot of a `komira.iceberg.table`
    binding under the scan's pushed `filter` (module header)."""
    var pinned = iceberg_pinned_table_of(binding)
    ref table = pinned.table
    ref md = pinned.metadata
    var counts = IcebergPlanCounts()
    var spec = IcebergScanSpec()
    for i in range(len(table.columns)):
        spec.column_names.append(table.columns[i].name)
        spec.column_types.append(table.arrow_schema.field_arrow_type(i))
        spec.column_field_ids.append(table.columns[i].id)
        spec.column_type_names.append(table.columns[i].type_name)
    if table.snapshot_id < 0:
        return IcebergPlannedScan(spec^, counts^)

    var snap = md.snapshot_by_id(table.snapshot_id)
    var manifests = _manifests_of(snap, table, md)
    var preds = prune_predicates_of(filter, table.columns)
    var schema = md.schema_by_id(table.schema_id)

    var data = List[IcebergFileEntry]()
    var deletes = List[IcebergFileEntry]()
    for mi in range(len(manifests)):
        ref m = manifests[mi]
        var pspec = md.spec_by_id(m.spec_id)
        var delete_manifest = m.content != CONTENT_DATA
        if not delete_manifest and not manifest_may_match(m, pspec, preds):
            counts.manifests_skipped += 1
            continue
        counts.manifests_read += 1
        var raw = _read_file(m.path, table, String("manifest"))
        var entries = read_manifest(Span(raw), m, pspec, schema)
        for ei in range(len(entries)):
            ref e = entries[ei]
            if e.status == ENTRY_DELETED:
                continue
            if (e.content != CONTENT_DATA) != delete_manifest:
                raise Error(
                    ICEBERG_MANIFEST_INVALID
                    + String(": the manifest ")
                    + m.path
                    + String(" holds the file ")
                    + e.file_path
                    + String(" of the other content kind")
                )
            if delete_manifest:
                deletes.append(e.copy())
            elif entry_may_match(e, pspec, preds):
                data.append(e.copy())
            else:
                counts.data_files_skipped += 1

    # Which deletes apply to which remaining data file.
    var pos_of = List[List[Int]]()
    var eq_of = List[List[Int]]()
    var used = List[Bool](length=len(deletes), fill=False)
    var unpartitioned = List[Bool]()
    for j in range(len(deletes)):
        unpartitioned.append(len(md.spec_by_id(deletes[j].spec_id).fields) == 0)
    for i in range(len(data)):
        if data[i].file_format != "PARQUET":
            raise _unsupported(
                String("the data file format ")
                + data[i].file_format
                + String(" of ")
                + data[i].file_path
                + String(" is not read; only PARQUET is")
            )
        var pos = List[Int]()
        var eq = List[Int]()
        for j in range(len(deletes)):
            if _delete_applies(deletes[j], data[i], unpartitioned[j], table):
                used[j] = True
                if deletes[j].content == CONTENT_POSITION_DELETES:
                    pos.append(j)
                else:
                    eq.append(j)
        pos_of.append(pos^)
        eq_of.append(eq^)

    # The listed deletes, in entry order.
    var index_of = List[Int](length=len(deletes), fill=-1)
    for j in range(len(deletes)):
        if not used[j]:
            continue
        ref d = deletes[j]
        if d.file_format != "PARQUET" and d.file_format != "AVRO":
            raise _unsupported(
                String("the delete file format ")
                + d.file_format
                + String(" of ")
                + d.file_path
                + String(" is not read; only PARQUET and AVRO are")
            )
        var columns = List[String]()
        if d.content == CONTENT_EQUALITY_DELETES:
            columns = _equality_columns(d, table)
        index_of[j] = len(spec.deletes)
        spec.deletes.append(
            IcebergDeleteSpec(
                local_path_of(d.file_path, table),
                d.content,
                d.file_format,
                columns^,
            )
        )
    for i in range(len(data)):
        var pos = List[Int]()
        var eq = List[Int]()
        for k in range(len(pos_of[i])):
            pos.append(index_of[pos_of[i][k]])
        for k in range(len(eq_of[i])):
            eq.append(index_of[eq_of[i][k]])
        spec.data_files.append(
            IcebergDataFileSpec(
                local_path_of(data[i].file_path, table),
                data[i].file_path,
                pos^,
                eq^,
            )
        )
    counts.data_files = len(spec.data_files)
    counts.delete_files = len(spec.deletes)
    return IcebergPlannedScan(spec^, counts^)
