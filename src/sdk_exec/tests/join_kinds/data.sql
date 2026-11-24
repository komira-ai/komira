-- The tables of test_run_sql_join_kinds, written by DuckDB in small row
-- groups, so every scan reads several row groups. Each column is a function of
-- the row number n, with NULLs, duplicate keys and keys with no partner on
-- either side.
--
-- l.parquet, 24 rows in row groups of 8:
--   lk BIGINT   n % 6 (0 to 5), NULL where n % 7 = 6
--   ls VARCHAR  's' || (n % 5), the empty string where n % 12 = 11, NULL where n % 9 = 8
--   li INTEGER  n % 4 (0 to 3), NULL where n % 10 = 9
--   lv BIGINT   n * 10, NULL where n % 8 = 7
--   ld DOUBLE   (n % 5) * 0.5, NULL where n % 11 = 10
COPY (
    SELECT
        CASE WHEN n % 7 = 6 THEN NULL ELSE CAST(n % 6 AS BIGINT) END AS lk,
        CASE WHEN n % 9 = 8 THEN NULL WHEN n % 12 = 11 THEN '' ELSE 's' || CAST(n % 5 AS VARCHAR) END AS ls,
        CASE WHEN n % 10 = 9 THEN NULL ELSE CAST(n % 4 AS INTEGER) END AS li,
        CASE WHEN n % 8 = 7 THEN NULL ELSE CAST(n * 10 AS BIGINT) END AS lv,
        CASE WHEN n % 11 = 10 THEN NULL ELSE CAST(n % 5 AS DOUBLE) * 0.5 END AS ld
    FROM range(24) t(n)
) TO 'l.parquet' (FORMAT parquet, ROW_GROUP_SIZE 8);

-- r.parquet, 16 rows in row groups of 4:
--   rk BIGINT   3 + n % 5 (3 to 7), NULL where n = 8
--   rs VARCHAR  's' || (n % 5) ('other' where n % 5 = 4), the empty string
--               where n % 8 = 3, NULL where n % 7 = 6
--   ri INTEGER  n % 3 + 1 (1 to 3), NULL where n % 8 = 7
--   rv BIGINT   n * 100, NULL where n % 6 = 5
--   rd DOUBLE   (n % 4) * 0.5 + 0.5, NULL where n % 9 = 8
COPY (
    SELECT
        CASE WHEN n = 8 THEN NULL ELSE CAST(3 + n % 5 AS BIGINT) END AS rk,
        CASE WHEN n % 7 = 6 THEN NULL WHEN n % 8 = 3 THEN '' WHEN n % 5 = 4 THEN 'other' ELSE 's' || CAST(n % 5 AS VARCHAR) END AS rs,
        CASE WHEN n % 8 = 7 THEN NULL ELSE CAST(n % 3 + 1 AS INTEGER) END AS ri,
        CASE WHEN n % 6 = 5 THEN NULL ELSE CAST(n * 100 AS BIGINT) END AS rv,
        CASE WHEN n % 9 = 8 THEN NULL ELSE CAST(n % 4 AS DOUBLE) * 0.5 + 0.5 END AS rd
    FROM range(16) t(n)
) TO 'r.parquet' (FORMAT parquet, ROW_GROUP_SIZE 4);

-- n.parquet, 5 rows holding 3 to 7 and no NULL, so a NOT IN over it is
-- proved free of NULL by the file's null counts.
COPY (
    SELECT CAST(3 + n AS BIGINT) AS nk FROM range(5) t(n)
) TO 'n.parquet' (FORMAT parquet, ROW_GROUP_SIZE 4);

-- e.parquet: the columns of r and no row.
COPY (
    SELECT
        CAST(n AS BIGINT) AS rk,
        CAST('x' AS VARCHAR) AS rs,
        CAST(n AS INTEGER) AS ri,
        CAST(n AS BIGINT) AS rv,
        CAST(n AS DOUBLE) AS rd
    FROM range(3) t(n)
    WHERE n < 0
) TO 'e.parquet' (FORMAT parquet, ROW_GROUP_SIZE 4);

-- big.parquet: 300 rows, 1 to 300, in row groups of 128, for a CROSS join
-- of 90000 rows (more than one chunk of the cross join's output).
COPY (
    SELECT CAST(n + 1 AS BIGINT) AS bk FROM range(300) t(n)
) TO 'big.parquet' (FORMAT parquet, ROW_GROUP_SIZE 128);
