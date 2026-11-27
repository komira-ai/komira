-- The cases of test_run_sql_star_exclude: each COPY line below is one case, a
-- SELECT whose list is a star with an EXCLUDE list or a table-qualified star,
-- the query DuckDB runs over orders.parquet and customers.parquet (data.sql)
-- and the file its answer goes to. The test reads THIS FILE for the query text
-- and runs the same text through run_sql with each file name replaced by the
-- file's path, so a query has one source. A case's name is its output file
-- without `.tsv`.
COPY (SELECT * EXCLUDE (note) FROM read_parquet('orders.parquet')) TO 'exclude_one.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * EXCLUDE (Region, NOTE) FROM read_parquet('orders.parquet')) TO 'exclude_two_any_case.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * EXCLUDE note FROM read_parquet('orders.parquet')) TO 'exclude_bare_name.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * EXCLUDE (note) FROM read_parquet('orders.parquet') WHERE amount > 250) TO 'exclude_under_where.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * EXCLUDE (amount) FROM read_parquet('orders.parquet') ORDER BY amount DESC NULLS LAST, order_id LIMIT 7) TO 'exclude_order_by_dropped.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT DISTINCT * EXCLUDE (order_id, amount, note) FROM read_parquet('orders.parquet')) TO 'exclude_distinct.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH d AS (SELECT * EXCLUDE (note) FROM read_parquet('orders.parquet')) SELECT * EXCLUDE (region) FROM d) TO 'exclude_in_cte.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * EXCLUDE (customer) FROM read_parquet('orders.parquet') AS o JOIN read_parquet('customers.parquet') AS c ON o.customer = c.customer) TO 'exclude_join_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT o.* EXCLUDE (note, amount) FROM read_parquet('orders.parquet') AS o JOIN read_parquet('customers.parquet') AS c ON o.customer = c.customer) TO 'qualified_left_exclude.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT c.* FROM read_parquet('orders.parquet') AS o JOIN read_parquet('customers.parquet') AS c ON o.customer = c.customer) TO 'qualified_right.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT c.* EXCLUDE (tier) FROM read_parquet('orders.parquet') AS o LEFT JOIN read_parquet('customers.parquet') AS c ON o.customer = c.customer) TO 'qualified_right_of_left_join.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
