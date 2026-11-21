# =============================================================================
# lowering_facts -- LoweringInputs from the footer cache the binder read
# =============================================================================
#
# `lowering.lower` opens no file; the host hands it, per scan in
# pre-order, what the footers say. These functions build that from the
# `FooterCache` a `ParquetFooters` reads, so a footer the binder read is not
# read again: the statistics lowering sees are those of the footer the plan was
# bound against.
#
# What a scan's facts hold today: `stats`, the footers' statistics folded over
# every row group of every file (row count, per-column min, max and null count,
# where the footers record them). Over several files the row count and null
# counts are summed (a null count is unknown if any file's is), the minimum is
# the smallest and the maximum the largest (unknown if any file's is), and the
# distinct count is the largest of the files' lower bounds. `dict_encoded_columns` is left empty: the footer reader
# does not parse the page encoding statistics that tell a column stored
# entirely dictionary encoded from one that fell back to plain pages, and
# listing a column on the strength of its encodings alone could name a
# column with plain pages. An empty list lowers every column by value, which
# is always correct.
# =============================================================================

from arrow.schema import Schema
from lowering.lowered_plan import LoweringInputs
from parquet.table_stats import collect_table_stats
from plan_expr.scalar_value import ScalarValue
from plan_stats.table_stats import TableStats
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SOURCE_VARIANT_PARQUET
from sql.sql_catalog import SqlCatalog

from parquet_footers.footer_cache import FooterCache, footer_error
from parquet_footers.parquet_footers import (
    CHANGED_REASON,
    ParquetFooters,
    check_catalog_table,
    check_registered_schema,
)


def _file_stats(
    cache: FooterCache, path: String, schema: Schema
) raises -> TableStats:
    """The statistics of the footer held for `path`, read by `schema`'s column
    names. Refuses a file replaced after its footer was read."""
    var meta = cache.footer(path)
    if cache.changed_since_read(path):
        raise Error(footer_error(path, CHANGED_REASON))
    return collect_table_stats(meta[], schema)


def _scalar_lt(a: ScalarValue, b: ScalarValue) -> Bool:
    """a < b for two bounds of one column, so of one type: a float column's
    bounds compare as floats, any other's as integers."""
    if a.dtype == DType.float64 or a.dtype == DType.float32:
        return a.float_val < b.float_val
    return a.int_val < b.int_val


def _fold_into(mut total: TableStats, other: TableStats):
    """Fold the statistics of another file with the same columns into
    `total`."""
    total.row_count += other.row_count
    for c in range(len(total.column_stats)):
        ref o = other.column_stats[c]
        if Bool(total.column_stats[c].null_count) and Bool(o.null_count):
            total.column_stats[c].null_count = Optional[Int](
                total.column_stats[c].null_count.value() + o.null_count.value()
            )
        else:
            total.column_stats[c].null_count = None
        if Bool(total.column_stats[c].min_value) and Bool(o.min_value):
            if _scalar_lt(
                o.min_value.value(), total.column_stats[c].min_value.value()
            ):
                total.column_stats[c].min_value = Optional[ScalarValue](
                    o.min_value.value().copy()
                )
        else:
            total.column_stats[c].min_value = None
        if Bool(total.column_stats[c].max_value) and Bool(o.max_value):
            if _scalar_lt(
                total.column_stats[c].max_value.value(), o.max_value.value()
            ):
                total.column_stats[c].max_value = Optional[ScalarValue](
                    o.max_value.value().copy()
                )
        else:
            total.column_stats[c].max_value = None
        if Bool(o.distinct_count):
            if not Bool(total.column_stats[c].distinct_count) or (
                o.distinct_count.value()
                > total.column_stats[c].distinct_count.value()
            ):
                total.column_stats[c].distinct_count = Optional[Int](
                    o.distinct_count.value()
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
    var stats = _file_stats(footers.cache(), path, schema)
    inputs.add_scan(Optional(stats^))


def add_parquet_files_scan(
    mut inputs: LoweringInputs, footers: ParquetFooters, source: ParquetSource
) raises:
    """Append the facts of the next scan, a scan of every file of `source`:
    each file's statistics (read by the source's data schema) folded into one.
    A source of one file gives that file's facts.

    Raises:
        Error naming the file when a footer does not read or the file was
        replaced after its footer was read.
    """
    var cache = footers.cache()
    var schema = source.schema()
    var total = _file_stats(cache, String(source.paths[0]), schema)
    for i in range(1, len(source.paths)):
        _fold_into(total, _file_stats(cache, String(source.paths[i]), schema))
    inputs.add_scan(Optional(total^))


def add_read_parquet_scan(
    mut inputs: LoweringInputs, footers: ParquetFooters, path: String
) raises:
    """Append the facts of the next scan, a `read_parquet('path')` scan, whose
    schema is the footer's own."""
    var schema = footers.footer_schema(path)
    add_parquet_scan(inputs, footers, path, schema)


def add_catalog_table_scan(
    mut inputs: LoweringInputs,
    catalog: SqlCatalog,
    table: String,
    footers: ParquetFooters,
    source: ParquetSource,
) raises:
    """Append the facts of the next scan, a scan of the files of `source`,
    which are some of the files of the Parquet table `table` (the optimizer's
    partition pruning can leave a subset). Only those files are checked against
    the table's schema and folded, so a file the scan does not read cannot
    refuse it or widen its facts.

    Raises:
        Error naming the table and file when a schema disagrees, the table is
        not a Parquet table, or a footer does not read.
    """
    var t = catalog.table_of(table)
    if t.source.tag != SOURCE_VARIANT_PARQUET:
        raise Error("parquet table '" + table + "': the table is not a Parquet table")
    var expected = t.source._parquet.value().schema()
    for i in range(len(source.paths)):
        check_registered_schema(
            table, String(source.paths[i]), expected, footers
        )
    add_parquet_files_scan(inputs, footers, source)


def add_catalog_scan(
    mut inputs: LoweringInputs,
    catalog: SqlCatalog,
    table: String,
    footers: ParquetFooters,
) raises:
    """Append the facts of the next scan, a scan of the Parquet table `table`
    of `catalog`, folded over every file of the table. The files are checked
    against the table's schema first (`check_catalog_table`), so a scan is
    never lowered on facts of a file the plan was not bound to.

    Raises:
        Error naming the table and file when a schema disagrees, the table is
        not a Parquet table, or a footer does not read.
    """
    check_catalog_table(catalog, table, footers)
    var t = catalog.table_of(table)
    ref ps = t.source._parquet.value()
    add_parquet_files_scan(inputs, footers, ps)
