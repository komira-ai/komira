"""`komira_sql_conformance`, the Mojo half: runs the `scalar_fn` corpus through
`run_sql` and writes down which scalar functions of `sql.sql_fn_table` run.

Test-only; nothing depends on it. `function_coverage` measures, the test holds
the result to the committed `function_coverage.tsv`."""
