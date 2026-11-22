"""`komira_multifile_scan_conformance`: Parquet tables of several files (a
directory, a glob, a Hive tree) run through `run_sql`, held to the answers of
the pinned DuckDB.

Test-only; nothing depends on it. oracle/*.sql build the files and the expected
answers (BUCK runs them); tests/ holds the checks. The module has no code of
its own beyond checks.mojo.
"""
