-- The table of test_run_sql_partition_topn, written by DuckDB.
--
-- top.parquet: 900 rows in row groups of 128, each column a function of the
-- row number n.
--
-- id  BIGINT   n (unique, the tie-free order key)
-- g   VARCHAR  'g0' .. 'g3', a partition key; NULL where n % 11 = 0 (one
--              group of its own) and 'solo' for n = 5 alone (a group of one
--              row)
-- q   BIGINT   n % 6, a partition key with no NULL
-- p   INTEGER  n % 5, a partition key; NULL where n % 13 = 0
-- o   BIGINT   n % 7, an order key with ties; NULL where n % 17 = 0
-- k   BIGINT   n % 5, an order key with 30 rows on each value in each group
--              of q, and no NULL
-- x   DOUBLE   ((n * 37) % 101) * 0.5 - 20, an order key with ties and no
--              NULL
COPY (
    SELECT
        CAST(n AS BIGINT) AS id,
        CASE
            WHEN n % 11 = 0 THEN NULL
            WHEN n = 5 THEN 'solo'
            ELSE 'g' || CAST(n % 4 AS VARCHAR)
        END AS g,
        CAST(n % 6 AS BIGINT) AS q,
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 5 AS INTEGER) END AS p,
        CASE WHEN n % 17 = 0 THEN NULL ELSE CAST(n % 7 AS BIGINT) END AS o,
        CAST(n % 5 AS BIGINT) AS k,
        CAST((n * 37) % 101 AS DOUBLE) * 0.5 - 20 AS x
    FROM range(900) r(n)
) TO 'top.parquet' (FORMAT parquet, ROW_GROUP_SIZE 128);
