# =============================================================================
# engine_iceberg -- register an Iceberg table, resolved through a catalog
# =============================================================================
#
# `register_iceberg_table` asks an `IcebergCatalog` (a REST catalog, or a
# `StorageBasedCatalog` that holds a known location) where the table's current
# `metadata.json` is, reads that file's table metadata, and registers the table
# on the context's catalog under `name`. SQL then says `SELECT ... FROM <name>`,
# and the scan is the one `iceberg_scan('<metadata path>')` builds: a binding of
# kind `komira.iceberg.table`, pinned to the snapshot that was current when the
# table was registered. A later commit to the table is not seen by this name;
# register the table again to read it.
#
# The metadata location must name the local file system: a bare path or a
# `file:` URI. `resolve_iceberg_table` refuses any other scheme (`s3://`,
# `https://`), and a `file://` URI with a host, with `ICEBERG_PATH_UNSUPPORTED`.
# The table is not added to `ctx.tables`, which lists the Parquet tables whose
# registered schema is checked against their files at every query.

from iceberg_catalog import IcebergCatalog
from iceberg_scan.table_ref import iceberg_scan_binding, resolve_iceberg_table
from scan_source.source_variant import SourceVariant

from .engine_context import EngineContext


def register_iceberg_table[
    C: IcebergCatalog
](
    mut ctx: EngineContext,
    name: String,
    mut catalog: C,
    namespace: String,
    table: String,
    allow_moved_paths: Bool = False,
) raises:
    """Register the Iceberg table `namespace.table` of `catalog` as `name`.

    The catalog says where the table's current metadata file is; the table's
    columns and current snapshot are read from it now. With `allow_moved_paths`
    a stored file URI that starts with the table's recorded location is read
    from the table's root instead (DuckDB's option of the same name).

    Raises:
        Error from the catalog when it does not know the table;
        `ICEBERG_PATH_UNSUPPORTED` when the metadata location is not local; an
        `iceberg_scan` error (`ICEBERG_METADATA_INVALID`,
        `ICEBERG_TYPE_UNSUPPORTED`, `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED`)
        naming what in the metadata cannot be read. Nothing is registered then.
    """
    var resolved = catalog.load_table(namespace, table)
    var pinned = resolve_iceberg_table(
        resolved.metadata_location, allow_moved_paths, None
    )
    ctx.catalog.add_source(
        name, SourceVariant.from_binding(iceberg_scan_binding(pinned))
    )
