# =============================================================================
# engine_catalog -- register tables on an EngineContext
# =============================================================================

from .engine_context import EngineContext, RegisteredTable
from komira_parquet_footers.parquet_footers import register_parquet_table


def register_parquet(
    mut ctx: EngineContext, name: String, path: String
) raises:
    """Register the Parquet file `path` as table `name`, with the schema its
    own footer gives. Nothing is registered when the footer does not read.

    Raises:
        Error naming `path` when it is not a readable flat Parquet file.
    """
    register_parquet_table(ctx.catalog, name, path, ctx.footers)
    ctx.tables.append(RegisteredTable(name.lower(), path))
