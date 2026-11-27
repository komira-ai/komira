-- The table of test_run_sql_expr_beside_agg, written by DuckDB: 3000 rows in
-- row groups of 1000 (three row groups), each column a function of the row
-- number n, with NULLs in every column at its own period.
--
-- k    INTEGER   n % 5 - 2 (negative, zero, positive)
-- s    VARCHAR   'a', 'b' or 'c', the empty string where n % 11 = 1
-- v    BIGINT    n * 3 - 4000
COPY (
    SELECT
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 5 - 2 AS INTEGER) END AS k,
        CASE WHEN n % 7 = 0 THEN NULL WHEN n % 11 = 1 THEN '' ELSE chr(97 + CAST(n % 3 AS INTEGER)) END AS s,
        CASE WHEN n % 17 = 0 THEN NULL ELSE CAST(n * 3 - 4000 AS BIGINT) END AS v
    FROM range(3000) t(n)
) TO 'expr.parquet' (FORMAT parquet, ROW_GROUP_SIZE 1000);
