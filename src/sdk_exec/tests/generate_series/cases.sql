-- The cases of test_run_sql_generate_series: each line below is one case, the
-- query DuckDB runs and the file its answer goes to. The test reads THIS FILE
-- for the query text and runs the same text through run_sql (with
-- 'events.csv' replaced by the file's path), so a query has one source. A
-- case's name is its output file without `.tsv`; a `DESCRIBE` case compares
-- the name and type of each column.
--
-- events.csv  day, amount: four rows on three of the days 2024-01-01 to
--             2024-01-07 (two on 2024-01-02), none on the other four.
--
-- Integers: generate_series stops at the bound, range before it; a step; a
-- negative step; the one-argument forms; a step away from the bound, an empty
-- range and a NULL argument give no rows; an alias names the column; a
-- series that ends on the largest BIGINT; a filter, an aggregation, a limit
-- over a series too long to build, and a join of two series.
COPY (SELECT * FROM generate_series(1, 5)) TO 'int_inclusive.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(1, 5)) TO 'int_exclusive.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(0, 20, 7)) TO 'int_step.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(5, 1, -2)) TO 'int_negative_step.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(5, 1, -2)) TO 'int_range_negative_step.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(3)) TO 'int_one_argument.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(3)) TO 'int_range_one_argument.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(5, 1)) TO 'int_wrong_direction.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(4, 4)) TO 'int_one_value.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(4, 4)) TO 'int_range_empty.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(1, NULL)) TO 'int_null_bound.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(1, 10, NULL)) TO 'int_null_step.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT t.x FROM generate_series(1, 3) AS t(x)) TO 'int_alias.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(9223372036854775805, 9223372036854775807)) TO 'int_largest.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT x FROM range(0, 100) AS t(x) WHERE x % 10 = 3) TO 'int_filter.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n, sum(x) AS total, min(x) AS lo, max(x) AS hi FROM range(0, 1000000) AS t(x)) TO 'int_aggregate.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n FROM (SELECT * FROM range(0, 4611686018427387904) LIMIT 5)) TO 'int_limit.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT a.x FROM range(0, 10) AS a(x) JOIN range(5, 15) AS b(y) ON a.x = b.y) TO 'int_join.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM range(3))) TO 'int_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
-- Dates and timestamps: a date series by day, by week and by month (the day
-- held at the last day of a shorter month), a range by year from a leap day,
-- a timestamp series by hour across midnight, by month downwards and a range
-- by seconds; a DATE series is a TIMESTAMP column.
COPY (SELECT * FROM generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY)) TO 'date_by_day.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(DATE '2024-01-01', DATE '2024-02-01', INTERVAL '1' WEEK)) TO 'date_by_week.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(DATE '2024-01-31', DATE '2024-06-30', INTERVAL '1' MONTH)) TO 'date_by_month.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(DATE '2020-02-29', DATE '2024-03-01', INTERVAL '1' YEAR)) TO 'date_range_by_year.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(TIMESTAMP '2024-01-01 22:00:00', TIMESTAMP '2024-01-02 03:00:00', INTERVAL '1' HOUR)) TO 'date_timestamp_by_hour.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM generate_series(TIMESTAMP '2024-05-31 12:00:00', TIMESTAMP '2024-01-01 00:00:00', INTERVAL '-1' MONTH)) TO 'date_timestamp_down_by_month.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM range(TIMESTAMP '2024-01-01 00:00:00', TIMESTAMP '2024-01-01 00:05:00', INTERVAL '90' SECOND)) TO 'date_range_by_seconds.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY) AS t(d))) TO 'date_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
-- Filling gaps: every day of the week LEFT JOINed with the count of events on
-- it, so a day with none counts 0; the DATE key of the events meets the
-- TIMESTAMP of the series at midnight.
COPY (SELECT t.d, COALESCE(c.n, 0) AS n FROM generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY) AS t(d) LEFT JOIN (SELECT day, count(*) AS n FROM read_csv('events.csv') GROUP BY day) AS c ON c.day = t.d ORDER BY t.d) TO 'fill_gaps_by_day.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT t.d, COALESCE(c.total, 0) AS total FROM generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY) AS t(d) LEFT JOIN (SELECT day, sum(amount) AS total FROM read_csv('events.csv') GROUP BY day) AS c ON t.d = c.day ORDER BY t.d) TO 'fill_gaps_sum.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
