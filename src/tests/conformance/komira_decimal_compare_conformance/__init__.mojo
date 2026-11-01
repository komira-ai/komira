"""`komira_decimal_compare_conformance`: DECIMAL column vs literal comparisons
run through `run_sql`, held to the answers of the pinned DuckDB.

Test-only; nothing depends on it. oracle/*.sql build the table and the expected
answers (BUCK runs them); tests/ holds the check. The module has no code of
its own.
"""
