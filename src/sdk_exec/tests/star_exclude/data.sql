-- The tables of test_run_sql_star_exclude, written by DuckDB.
--
-- orders.parquet: 600 rows in row groups of 200 (three row groups), each
-- column a function of the row number n, with NULLs at a period of its own.
--   order_id  BIGINT   n + 1
--   customer  VARCHAR  'ana', 'bo', 'cy', 'dee' or 'eve' (n % 5), NULL where n % 23 = 0
--   region    VARCHAR  'east', 'west' or 'north' (n % 3), NULL where n % 11 = 0
--   amount    BIGINT   (n * 37) % 500, NULL where n % 13 = 0
--   note      VARCHAR  'gift' or 'rush' (n % 2), NULL where n % 7 = 0
-- customers.parquet: one row per customer but 'eve', and 'fay', who has no
-- order, so a join matches some rows of each side and not others.
--   customer  VARCHAR
--   tier      VARCHAR  'gold' or 'basic', NULL for 'cy'
COPY (
    SELECT
        CAST(n + 1 AS BIGINT) AS order_id,
        CASE WHEN n % 23 = 0 THEN NULL ELSE ['ana', 'bo', 'cy', 'dee', 'eve'][n % 5 + 1] END AS customer,
        CASE WHEN n % 11 = 0 THEN NULL ELSE ['east', 'west', 'north'][n % 3 + 1] END AS region,
        CASE WHEN n % 13 = 0 THEN NULL ELSE CAST((n * 37) % 500 AS BIGINT) END AS amount,
        CASE WHEN n % 7 = 0 THEN NULL ELSE ['gift', 'rush'][n % 2 + 1] END AS note
    FROM range(600) t(n)
) TO 'orders.parquet' (FORMAT parquet, ROW_GROUP_SIZE 200);
COPY (
    SELECT * FROM (VALUES ('ana', 'gold'), ('bo', 'basic'), ('cy', NULL), ('dee', 'gold'), ('fay', 'basic')) AS c(customer, tier)
) TO 'customers.parquet' (FORMAT parquet);
