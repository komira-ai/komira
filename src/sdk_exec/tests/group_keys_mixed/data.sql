-- The table of test_run_sql_group_keys_mixed, written by DuckDB: 10000 rows
-- in row groups of 2048 (five row groups), each column a function of the row
-- number n, with NULLs in every column at its own period.
--
-- i    INTEGER        n % 7 - 3 (negative, zero, positive)
-- big  BIGINT         (n % 5) * 3000000000 (past the INTEGER range)
-- s    VARCHAR        'key_0' .. 'key_3', the empty string where n % 11 = 1
-- d    DATE           1969-12-20 plus 0 to 5 times 45 days (days before
--                     the epoch and after it)
-- m    DECIMAL(12,2)  (n % 9 - 4) * 1.25
-- b    BOOLEAN        n % 3 = 0
-- v    BIGINT         n * 7 - 20000
COPY (
    SELECT
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 7 - 3 AS INTEGER) END AS i,
        CASE WHEN n % 17 = 0 THEN NULL ELSE CAST(n % 5 AS BIGINT) * 3000000000 END AS big,
        CASE WHEN n % 11 = 0 THEN NULL WHEN n % 11 = 1 THEN '' ELSE 'key_' || CAST(n % 4 AS VARCHAR) END AS s,
        CASE WHEN n % 19 = 0 THEN NULL ELSE DATE '1969-12-20' + CAST(n % 6 AS INTEGER) * 45 END AS d,
        CASE WHEN n % 23 = 0 THEN NULL ELSE CAST((n % 9 - 4) * 1.25 AS DECIMAL(12, 2)) END AS m,
        CASE WHEN n % 29 = 0 THEN NULL ELSE n % 3 = 0 END AS b,
        CASE WHEN n % 31 = 0 THEN NULL ELSE CAST(n * 7 - 20000 AS BIGINT) END AS v
    FROM range(10000) t(n)
) TO 'mixed.parquet' (FORMAT parquet, ROW_GROUP_SIZE 2048);
