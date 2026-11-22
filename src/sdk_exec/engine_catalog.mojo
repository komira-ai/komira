# =============================================================================
# engine_catalog -- register tables on an EngineContext
# =============================================================================

from .engine_context import EngineContext, RegisteredTable
from parquet_footers.parquet_footers import register_parquet_table


def register_parquet(
    mut ctx: EngineContext, name: String, path: String
) raises:
    """Register Parquet files `path` as table `name`, with the schema their own
    footers give. `path` is a file, a glob (`*`, `?`, `[...]`, `{a,b}`, one
    `**`) or a directory (every `.parquet` file under it at any depth). The
    files are listed once, here, and sorted; Hive `key=value` directories are
    detected and become columns after the data columns. Nothing is registered
    when a footer does not read.

    Raises:
        Error naming `path` when it is not readable flat Parquet, when no file
        matches (`PARQUET_GLOB_NO_MATCH`), when the files' schemas differ
        (`PARQUET_FILES_SCHEMA_MISMATCH`) or when a Hive layout is refused.
    """
    register_parquet_table(ctx.catalog, name, path, ctx.footers)
    ctx.tables.append(RegisteredTable(name.lower(), path))
