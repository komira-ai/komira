-- The tables of test_run_sql_window_frames, written by DuckDB.
--
-- frames.parquet: 3000 rows in row groups of 512, each column a function of
-- the row number n, with NULLs at a period of its own.
--
-- id  BIGINT   n (unique, the tie-free order key of every ROWS frame)
-- p   INTEGER  n % 4, the partition key (NULL where n % 17 = 0)
-- k   BIGINT   n % 60, an order key with ties (NULL where n % 13 = 0)
-- i   INTEGER  (n * 7) % 90 - 45, an INTEGER order key with ties and
--              negative values (NULL where n % 11 = 0)
-- f   DOUBLE   an order key: NULL, NaN, +inf, -inf and -0.0 where n % 23 is
--              0 to 4, else (n % 40) * 0.25 - 3 (so 0.0 is there too)
-- v   BIGINT   (n % 101) * 10 - 500 (NULL where n % 7 = 3)
-- x   DOUBLE   (n % 33) * 0.5 - 4, exact in binary, so sums are exact
--              (NULL where n % 19 = 0)
-- t   VARCHAR  't_0' .. 't_8' (NULL where n % 29 = 0)
--
-- edge.parquet: six rows whose keys reach the ends of BIGINT and INTEGER.
COPY (
    SELECT
        CAST(n AS BIGINT) AS id,
        CASE WHEN n % 17 = 0 THEN NULL ELSE CAST(n % 4 AS INTEGER) END AS p,
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 60 AS BIGINT) END AS k,
        CASE WHEN n % 11 = 0 THEN NULL ELSE CAST((n * 7) % 90 - 45 AS INTEGER) END AS i,
        CASE n % 23
            WHEN 0 THEN NULL
            WHEN 1 THEN CAST('nan' AS DOUBLE)
            WHEN 2 THEN CAST('inf' AS DOUBLE)
            WHEN 3 THEN CAST('-inf' AS DOUBLE)
            WHEN 4 THEN CAST('-0.0' AS DOUBLE)
            ELSE CAST(n % 40 AS DOUBLE) * 0.25 - 3
        END AS f,
        CASE WHEN n % 7 = 3 THEN NULL ELSE CAST((n % 101) * 10 - 500 AS BIGINT) END AS v,
        CASE WHEN n % 19 = 0 THEN NULL ELSE CAST(n % 33 AS DOUBLE) * 0.5 - 4 END AS x,
        CASE WHEN n % 29 = 0 THEN NULL ELSE 't_' || CAST(n % 9 AS VARCHAR) END AS t
    FROM range(3000) r(n)
) TO 'frames.parquet' (FORMAT parquet, ROW_GROUP_SIZE 512);
COPY (
    SELECT * FROM (VALUES
        (CAST(0 AS BIGINT), CAST(-9223372036854775807 - 1 AS BIGINT), CAST(-2147483647 - 1 AS INTEGER), CAST(10 AS BIGINT)),
        (1, -5, -1, 20),
        (2, 0, 0, 30),
        (3, 7, 5, 40),
        (4, 9223372036854775806, 2147483646, 50),
        (5, 9223372036854775807, 2147483647, 60)
    ) e(id, k, i, x)
) TO 'edge.parquet' (FORMAT parquet);
