# =============================================================================
# lowering_facts -- LoweringInputs from the footer cache the binder read
# =============================================================================
#
# `komira_lowering.lower` opens no file; the host hands it, per scan in
# pre-order, what the footers say. These functions build that from the
# `FooterCache` a `ParquetFooters` reads, so a footer the binder read is not
# read again: the statistics lowering sees are those of the footer the plan was
# bound against.
#
# What a scan's facts hold today: `stats`, the footer's statistics folded over
# every row group (row count, per-column min, max and null count, where the
# footer records them). `dict_encoded_columns` is left empty: the footer reader
# does not parse the page encoding statistics that tell a column stored
# entirely dictionary encoded from one that fell back to plain pages, and
# listing a column on the strength of its encodings alone could name a
# column with plain pages. An empty list lowers every column by value, which
# is always correct.
# =============================================================================

from komira_arrow.schema import Schema
from komira_lowering.lowered_plan import LoweringInputs
from komira_parquet.table_stats import collect_table_stats
from komira_sql.sql_catalog import SqlCatalog

from komira_parquet_footers.footer_cache import footer_error
from komira_parquet_footers.parquet_footers import (
    CHANGED_REASON,
    ParquetFooters,
    check_catalog_table,
)


def add_parquet_scan(
    mut inputs: LoweringInputs,
    footers: ParquetFooters,
    path: String,
    schema: Schema,
) raises:
    """Append the facts of the next scan, a scan of the Parquet file `path`
    whose plan schema is `schema`: the footer's statistics, folded over its
    row groups and read by the schema's column names.

    Raises:
        Error naming `path` when its footer does not read, or when the file
        was replaced after the footer was read (the facts would be those of a
        version the file no longer has).
    """
    var cache = footers.cache()
    var meta = cache.footer(path)
    if cache.changed_since_read(path):
        raise Error(footer_error(path, CHANGED_REASON))
    var stats = collect_table_stats(meta[], schema)
    inputs.add_scan(Optional(stats^))


def add_read_parquet_scan(
    mut inputs: LoweringInputs, footers: ParquetFooters, path: String
) raises:
    """Append the facts of the next scan, a `read_parquet('path')` scan, whose
    schema is the footer's own."""
    var schema = footers.footer_schema(path)
    add_parquet_scan(inputs, footers, path, schema)


def add_catalog_scan(
    mut inputs: LoweringInputs,
    catalog: SqlCatalog,
    table: String,
    footers: ParquetFooters,
) raises:
    """Append the facts of the next scan, a scan of the one-file Parquet table
    `table` of `catalog`. The registered schema is checked against the file
    first (`check_catalog_table`), so a scan is never lowered on facts of a
    file the plan was not bound to.

    Raises:
        Error naming the table and file when the schema disagrees, the table is
        not a one-file Parquet table, or the footer does not read.
    """
    check_catalog_table(catalog, table, footers)
    var t = catalog.table_of(table)
    ref ps = t.source._parquet.value()
    add_parquet_scan(inputs, footers, String(ps.paths[0]), t.schema)
