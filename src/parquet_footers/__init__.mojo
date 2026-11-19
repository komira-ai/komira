# =============================================================================
# parquet_footers: the one Parquet footer cache, and the footer reader
# the SQL binder and lowering both read from.
# =============================================================================
#
# `FooterCache` reads a file's footer once and shares it. `ParquetFooters`
# implements `sql`'s `SqlParquetFooters` over a `FooterCache`, so
# `bind_statement(stmt, catalog, footers)` binds off real footers. `lowering_facts`
# builds `lowering`'s `LoweringInputs` from the same cache, so the
# footer the binder saw is the footer lowering reads.
#
# Import the modules by name (`from parquet_footers.footer_cache import
# FooterCache`). This file exports nothing.
# =============================================================================
