-- The cases of test_run_sql_date_shift: each COPY line below is one case, a DATE
-- column shifted by an INTERVAL (a TIMESTAMP answer, column `shifted`) or by an
-- integer (a DATE answer, column `moved`), or compared with such a shift. The
-- test reads THIS FILE for the query text and runs the same text through run_sql
-- with 'orders.parquet' replaced by the file's path, so a query has one source.
-- A case's name is its output file without `.tsv`.
COPY (SELECT id, order_date + INTERVAL '7' DAY AS shifted FROM read_parquet('orders.parquet')) TO 'plus_days_interval.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date + INTERVAL '1' MONTH AS shifted FROM read_parquet('orders.parquet')) TO 'plus_month_clamps.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date - INTERVAL '1' YEAR AS shifted FROM read_parquet('orders.parquet')) TO 'minus_year_clamps.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date - INTERVAL '1' MONTH AS shifted FROM read_parquet('orders.parquet')) TO 'minus_month_interval.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, INTERVAL '2' WEEK + order_date AS shifted FROM read_parquet('orders.parquet')) TO 'interval_on_left.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, date_add(order_date, INTERVAL '1' MONTH) AS shifted FROM read_parquet('orders.parquet')) TO 'date_add_form.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date + INTERVAL '-3' MONTH AS shifted FROM read_parquet('orders.parquet')) TO 'negative_count_interval.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date + INTERVAL '1' MONTH + INTERVAL '1' DAY AS shifted FROM read_parquet('orders.parquet')) TO 'interval_chain.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date + 7 AS moved FROM read_parquet('orders.parquet')) TO 'plus_integer.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date - 30 AS moved FROM read_parquet('orders.parquet')) TO 'minus_integer.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, 3 + order_date AS moved FROM read_parquet('orders.parquet')) TO 'integer_on_left.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, order_date + -5 AS moved FROM read_parquet('orders.parquet')) TO 'negative_integer.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id FROM read_parquet('orders.parquet') WHERE ship_date > order_date + INTERVAL '7' DAY) TO 'probe_ship_after_a_week.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id FROM read_parquet('orders.parquet') WHERE ship_date > order_date + 7) TO 'filter_on_integer_shift.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
