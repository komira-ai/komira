-- The table of test_run_sql_window, written by DuckDB: 5000 rows in row
-- groups of 1024 (five row groups), each column a function of the row number
-- n, with NULLs in every column but id at a period of its own.
--
-- id  BIGINT         n (unique, the tie-free order key)
-- g   INTEGER        n % 7, the partition key (NULL where n % 13 = 0)
-- s   VARCHAR        'p_0' .. 'p_4', the empty string where n % 11 = 1
-- b   BOOLEAN        n % 3 = 0
-- o   BIGINT         n % 40, the order key with many ties
-- v   BIGINT         (n % 97) * 1000 - 20000 (sums stay far inside INT64)
-- f   DOUBLE         (n % 40) * 0.5 - 7 (exactly representable, so sums are exact)
-- t   VARCHAR        't_0' .. 't_8'
-- i   INTEGER        n % 50
-- d   DATE           2027-01-01 plus 0 to 29 days
-- m   DECIMAL(12,2)  (n % 9 - 4) * 1.25
COPY (
    SELECT
        CAST(n AS BIGINT) AS id,
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST(n % 7 AS INTEGER) END AS g,
        CASE WHEN n % 11 = 0 THEN NULL WHEN n % 11 = 1 THEN '' ELSE 'p_' || CAST(n % 5 AS VARCHAR) END AS s,
        CASE WHEN n % 17 = 0 THEN NULL ELSE n % 3 = 0 END AS b,
        CASE WHEN n % 19 = 0 THEN NULL ELSE CAST(n % 40 AS BIGINT) END AS o,
        CASE WHEN n % 23 = 0 THEN NULL ELSE CAST((n % 97) * 1000 - 20000 AS BIGINT) END AS v,
        CASE WHEN n % 29 = 0 THEN NULL ELSE CAST(n % 40 AS DOUBLE) * 0.5 - 7 END AS f,
        CASE WHEN n % 31 = 0 THEN NULL ELSE 't_' || CAST(n % 9 AS VARCHAR) END AS t,
        CASE WHEN n % 37 = 0 THEN NULL ELSE CAST(n % 50 AS INTEGER) END AS i,
        CASE WHEN n % 41 = 0 THEN NULL ELSE DATE '2027-01-01' + CAST(n % 30 AS INTEGER) END AS d,
        CASE WHEN n % 43 = 0 THEN NULL ELSE CAST((n % 9 - 4) * 1.25 AS DECIMAL(12, 2)) END AS m
    FROM range(5000) t(n)
) TO 'win.parquet' (FORMAT parquet, ROW_GROUP_SIZE 1024);
