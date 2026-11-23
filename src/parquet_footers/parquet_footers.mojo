# =============================================================================
# parquet_footers -- ParquetFooters: the binder's footer reader over the cache
# =============================================================================
#
# `ParquetFooters` implements `sql.SqlParquetFooters` over a
# `FooterCache`:
#
#   * `footer_schema(path)`: the Arrow schema of the file's flat footer schema.
#     A glob path is refused by name (it reads one file; `parquet_relation`
#     reads a glob).
#   * `parquet_relation(path, hive_partitioning)`: the `ParquetSource` a
#     `read_parquet(path)` relation scans, over the files `path` names
#     (`parquet_files.resolve_parquet_source`).
#   * `iceberg_relation(path, allow_moved_paths, snapshot_id)`: the source an
#     `iceberg_scan(path, ...)` relation scans, resolved from the table's
#     metadata (`iceberg_scan.table_ref`): a binding that names the metadata
#     file, the snapshot it is pinned to and the table's columns. It reads the
#     metadata file only (no footer, so nothing is cached), and the manifests
#     are read when the scan is lowered.
#   * `column_null_count(path, column)`: the column's null count summed over
#     every row group, or None when the file has no such column or any row
#     group records no count. Never a partial sum: one row group without a
#     count makes the answer unknown, which keeps the binder's run-time NULL
#     checks.
#
# `register_parquet_table` takes a table's files and schema from the path at
# registration (a file, a glob or a directory), and `check_catalog_table`
# checks every file of the table with `check_registered_schema`, which
# refuses, by table, file and column, a registered schema that disagrees with a
# file. The comparison is
# exact: names and order, Arrow type, decimal precision and scale, time zone,
# and nullability in both directions (a nullable column registered not null is
# unsafe; a not-null column registered nullable is refused too, so a registered
# schema is the file's schema and nothing looser).
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from parquet_api.metadata import RowGroup
from iceberg_scan.table_ref import iceberg_scan_binding, resolve_iceberg_table
from scan_source.source_variant import SOURCE_VARIANT_PARQUET, SourceVariant
from scan_source.parquet_source import ParquetSource
from sql.sql_ast import HIVE_PARTITIONING_AUTO
from sql.sql_bind_parquet import SqlParquetFooters, path_has_glob
from sql.sql_catalog import SqlCatalog

from parquet_footers.footer_cache import FooterCache, footer_error
from parquet_footers.parquet_files import resolve_parquet_source


comptime CHANGED_REASON = (
    "the file was replaced after its footer was read; the footer held is not"
    " the file's now (invalidate the path to read it again)"
)


def _chunk_of(rg: RowGroup, name: String) -> Int:
    """The column chunk of the top-level leaf `name` in `rg`, or -1."""
    for c in range(len(rg.columns)):
        ref path = rg.columns[c].meta_data.path_in_schema
        if len(path) == 1 and path[0] == name:
            return c
    return -1


struct ParquetFooters(SqlParquetFooters, Copyable, Movable):
    """The footer reader `bind_statement` takes, over a shared `FooterCache`.
    A copy reads the same cache."""

    var _cache: FooterCache

    def __init__(out self):
        self._cache = FooterCache()

    def __init__(out self, var cache: FooterCache):
        self._cache = cache^

    def cache(self) -> FooterCache:
        """A handle on the cache this reader reads, to build lowering's inputs
        from (`lowering_facts`) or to hold in an engine context."""
        return self._cache.copy()

    def _refuse_if_changed(self, path: String) raises:
        """Refuse a file replaced since its footer was read: the footer held
        is a version the file no longer has."""
        if self._cache.changed_since_read(path):
            raise Error(footer_error(path, CHANGED_REASON))

    def footer_schema(self, path: String) raises -> Schema:
        if path_has_glob(path):
            raise Error(
                footer_error(
                    path,
                    "a glob path reads more than one file; name one file",
                )
            )
        _ = self._cache.footer(path)
        self._refuse_if_changed(path)
        var summary = self._cache.summary(path)
        return summary.take_schema()

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        return resolve_parquet_source(self, path, hive_partitioning, False)

    def iceberg_relation(
        self,
        path: String,
        allow_moved_paths: Bool,
        snapshot_id: Optional[Int64],
    ) raises -> SourceVariant:
        return SourceVariant.from_binding(
            iceberg_scan_binding(
                resolve_iceberg_table(path, allow_moved_paths, snapshot_id)
            )
        )

    def column_null_count(
        self, path: String, column: String
    ) raises -> Optional[Int]:
        var meta = self._cache.footer(path)
        self._refuse_if_changed(path)
        ref md = meta[]
        var total = 0
        for r in range(len(md.row_groups)):
            ref rg = md.row_groups[r]
            var c = _chunk_of(rg, column)
            if c < 0:
                return None
            ref stats = rg.columns[c].meta_data.statistics
            if not stats:
                return None
            ref nulls = stats.value().null_count
            if not nulls:
                return None
            total += nulls.value()
        return total


def check_registered_schema(
    table: String, path: String, registered: Schema, footers: ParquetFooters
) raises:
    """Refuse `registered` when it is not the schema of the file `path`: a
    different number of columns, or a column whose name, type or nullability
    differs. The error names the table, the file and the first difference.

    Raises:
        Error naming the file when its footer cannot be read, or the
        difference when the schemas disagree.
    """
    var actual = footers.footer_schema(path)
    var head = (
        "parquet table '" + table + "': the registered schema does not match '"
        + path + "': "
    )
    if registered.num_columns() != actual.num_columns():
        raise Error(
            head
            + "registered "
            + String(registered.num_columns())
            + " columns, the file has "
            + String(actual.num_columns())
        )
    for i in range(registered.num_columns()):
        var rn = registered.field_name(i)
        var an = actual.field_name(i)
        if rn != an:
            raise Error(
                head + "column " + String(i) + " is registered as '" + rn
                + "', the file has '" + an + "'"
            )
        if registered.field_arrow_type(i) != actual.field_arrow_type(i):
            raise Error(
                head + "column '" + rn + "' is registered as "
                + String(registered.field_arrow_type(i)) + ", the file has "
                + String(actual.field_arrow_type(i))
            )
        if (
            registered.field_arrow_type(i) == ArrowType.DECIMAL128
            and (
                registered.field_decimal_precision(i)
                != actual.field_decimal_precision(i)
                or registered.field_decimal_scale(i)
                != actual.field_decimal_scale(i)
            )
        ):
            raise Error(
                head + "column '" + rn + "' is registered as decimal("
                + String(registered.field_decimal_precision(i)) + ", "
                + String(registered.field_decimal_scale(i))
                + "), the file has decimal("
                + String(actual.field_decimal_precision(i)) + ", "
                + String(actual.field_decimal_scale(i)) + ")"
            )
        if registered.field_tz(i) != actual.field_tz(i):
            raise Error(
                head + "column '" + rn + "' is registered with time zone '"
                + registered.field_tz(i) + "', the file has '"
                + actual.field_tz(i) + "'"
            )
        if registered.field_nullable(i) != actual.field_nullable(i):
            raise Error(
                head + "column '" + rn + "' is registered "
                + ("nullable" if registered.field_nullable(i) else "not null")
                + ", the file has it "
                + ("nullable" if actual.field_nullable(i) else "not null")
            )


def register_parquet_table(
    mut catalog: SqlCatalog, name: String, path: String, footers: ParquetFooters
) raises:
    """Register `path` as table `name`: a file, a glob or a directory (every
    `.parquet` file under it). The files are listed now, checked against the
    first file's schema, and Hive partition columns are detected. Nothing is
    registered when a footer does not read or the files disagree."""
    var source = resolve_parquet_source(
        footers, path, HIVE_PARTITIONING_AUTO, True
    )
    catalog.add_parquet_source(name, source^)


def check_catalog_table(
    catalog: SqlCatalog, name: String, footers: ParquetFooters
) raises:
    """Refuse the catalog table `name` when the schema of any Parquet file it
    names is not the schema its source holds.

    Raises:
        Error when `name` is unknown, is not a Parquet table, or a file's
        footer does not read or disagrees; the error names the file.
    """
    var table = catalog.table_of(name)
    if table.source.tag != SOURCE_VARIANT_PARQUET:
        raise Error("parquet table '" + name + "': the table is not a Parquet table")
    ref ps = table.source._parquet.value()
    var expected = ps.schema()
    for i in range(len(ps.paths)):
        check_registered_schema(name, String(ps.paths[i]), expected, footers)
