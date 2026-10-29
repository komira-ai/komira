# =============================================================================
# parquet_footers -- ParquetFooters: the binder's footer reader over the cache
# =============================================================================
#
# `ParquetFooters` implements `komira_sql.SqlParquetFooters` over a
# `FooterCache`:
#
#   * `footer_schema(path)`: the Arrow schema of the file's flat footer schema.
#     A glob path is refused by name (a glob's footers are not unioned yet).
#   * `column_null_count(path, column)`: the column's null count summed over
#     every row group, or None when the file has no such column or any row
#     group records no count. Never a partial sum: one row group without a
#     count makes the answer unknown, which keeps the binder's run-time NULL
#     checks.
#
# `register_parquet_table` takes a table's schema from the footer at
# registration, and `check_registered_schema` refuses, by table and column, a
# registered schema that disagrees with the file it names.
# =============================================================================

from komira_arrow.schema import Schema
from komira_parquet_api.metadata import RowGroup
from komira_scan_source.source_variant import SOURCE_VARIANT_PARQUET
from komira_sql.sql_bind_parquet import SqlParquetFooters, path_has_glob
from komira_sql.sql_catalog import SqlCatalog

from komira_parquet_footers.footer_cache import FooterCache, footer_error


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

    def footer_schema(self, path: String) raises -> Schema:
        if path_has_glob(path):
            raise Error(
                footer_error(
                    path,
                    "a glob path is not read yet; name one file",
                )
            )
        var summary = self._cache.summary(path)
        return summary.take_schema()

    def column_null_count(
        self, path: String, column: String
    ) raises -> Optional[Int]:
        var meta = self._cache.footer(path)
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
    """Register the Parquet file `path` as table `name`, with the schema its
    own footer gives. Nothing is registered when the footer does not read."""
    var schema = footers.footer_schema(path)
    catalog.add_parquet(name, path, schema^)


def check_catalog_table(
    catalog: SqlCatalog, name: String, footers: ParquetFooters
) raises:
    """Refuse the catalog table `name` when its registered schema is not the
    schema of the Parquet file it names.

    Raises:
        Error when `name` is unknown, is not a Parquet table, names more than
        one file (not checked yet), or its schema disagrees with the file.
    """
    var table = catalog.table_of(name)
    if table.source.tag != SOURCE_VARIANT_PARQUET:
        raise Error("parquet table '" + name + "': the table is not a Parquet table")
    ref ps = table.source._parquet.value()
    if len(ps.paths) != 1:
        raise Error(
            "parquet table '" + name + "': names " + String(len(ps.paths))
            + " files; only a one-file table is checked"
        )
    check_registered_schema(name, String(ps.paths[0]), table.schema, footers)
