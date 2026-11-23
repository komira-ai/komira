"""`komira_iceberg_scan_conformance`: `iceberg_scan` through `run_sql`, held
to the answers of the pinned DuckDB's Iceberg extension.

Test-only; nothing depends on it. The table `orders` is written by a program
of komira_iceberg_test_tables (BUCK: `:orders_table`), oracle/cases.sql runs
each case in the pinned DuckDB with its `avro` and `iceberg` extensions
loaded, and tests/ runs the same queries through `run_sql` over the same
table. The module has no code of its own.
"""
