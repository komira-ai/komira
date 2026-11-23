-- The tables of test_run_sql_subquery, written by DuckDB in small row groups,
-- so every scan reads several row groups. Each column is a function of the row
-- number n, with NULLs, duplicate keys and keys with no partner on either side.
--
-- t.parquet, 30 rows in row groups of 8:
--   id BIGINT         n (0 to 29), no NULL
--   k  BIGINT         n % 6 (0 to 5), NULL where n % 7 = 6
--   g  INTEGER        n % 4 (0 to 3), NULL where n % 10 = 9
--   v  BIGINT         n * 10, NULL where n % 8 = 7
--   d  DECIMAL(12,2)  (n % 7) * 1.25, NULL where n % 9 = 8
--   dt DATE           2026-10-01 plus n % 5 days, NULL where n % 13 = 12
--   s  VARCHAR        's' || (n % 5), the empty string where n % 12 = 11, NULL where n % 11 = 10
COPY (
    SELECT
        CAST(n AS BIGINT) AS id,
        CASE WHEN n % 7 = 6 THEN NULL ELSE CAST(n % 6 AS BIGINT) END AS k,
        CASE WHEN n % 10 = 9 THEN NULL ELSE CAST(n % 4 AS INTEGER) END AS g,
        CASE WHEN n % 8 = 7 THEN NULL ELSE CAST(n * 10 AS BIGINT) END AS v,
        CASE WHEN n % 9 = 8 THEN NULL ELSE CAST((n % 7) * 1.25 AS DECIMAL(12, 2)) END AS d,
        CASE WHEN n % 13 = 12 THEN NULL ELSE DATE '2026-10-01' + CAST(n % 5 AS INTEGER) END AS dt,
        CASE WHEN n % 11 = 10 THEN NULL WHEN n % 12 = 11 THEN '' ELSE 's' || CAST(n % 5 AS VARCHAR) END AS s
    FROM range(30) t(n)
) TO 't.parquet' (FORMAT parquet, ROW_GROUP_SIZE 8);

-- u.parquet, 16 rows in row groups of 4:
--   id BIGINT         n (0 to 15), no NULL
--   k  BIGINT         3 + n % 5 (3 to 7), NULL where n = 8
--   g  INTEGER        n % 3 + 1 (1 to 3), NULL where n % 8 = 7
--   v  BIGINT         n * 25, NULL where n % 6 = 5
--   d  DECIMAL(12,2)  (n % 4) * 2.5, NULL where n % 9 = 8
--   dt DATE           2026-10-03 plus n % 4 days, no NULL
--   s  VARCHAR        's' || (n % 5) ('other' where n % 5 = 4), the empty
--                     string where n % 8 = 3, NULL where n % 7 = 6
COPY (
    SELECT
        CAST(n AS BIGINT) AS id,
        CASE WHEN n = 8 THEN NULL ELSE CAST(3 + n % 5 AS BIGINT) END AS k,
        CASE WHEN n % 8 = 7 THEN NULL ELSE CAST(n % 3 + 1 AS INTEGER) END AS g,
        CASE WHEN n % 6 = 5 THEN NULL ELSE CAST(n * 25 AS BIGINT) END AS v,
        CASE WHEN n % 9 = 8 THEN NULL ELSE CAST((n % 4) * 2.5 AS DECIMAL(12, 2)) END AS d,
        DATE '2026-10-03' + CAST(n % 4 AS INTEGER) AS dt,
        CASE WHEN n % 7 = 6 THEN NULL WHEN n % 8 = 3 THEN '' WHEN n % 5 = 4 THEN 'other' ELSE 's' || CAST(n % 5 AS VARCHAR) END AS s
    FROM range(16) t(n)
) TO 'u.parquet' (FORMAT parquet, ROW_GROUP_SIZE 4);

-- nn.parquet, 5 rows holding 3 to 7 and no NULL in any column, so a NOT IN
-- over a column of it is proved free of NULL by the file's null counts.
COPY (
    SELECT CAST(3 + n AS BIGINT) AS k, CAST(n % 2 AS INTEGER) AS g FROM range(5) t(n)
) TO 'nn.parquet' (FORMAT parquet, ROW_GROUP_SIZE 4);

-- e.parquet: the columns of u and no row.
COPY (
    SELECT
        CAST(n AS BIGINT) AS id,
        CAST(n AS BIGINT) AS k,
        CAST(n AS INTEGER) AS g,
        CAST(n AS BIGINT) AS v,
        CAST(n AS DECIMAL(12, 2)) AS d,
        DATE '2026-10-03' + CAST(n AS INTEGER) AS dt,
        CAST('x' AS VARCHAR) AS s
    FROM range(3) t(n)
    WHERE n < 0
) TO 'e.parquet' (FORMAT parquet, ROW_GROUP_SIZE 4);
