-- The read_csv cases of test_run_sql_csv: each line below is one case, the
-- query DuckDB runs and the file its answer goes to. The test reads THIS
-- FILE for the query text and runs the same text through run_sql (with each
-- quoted file name replaced by the file's path, plain and gzip compressed), so
-- a query has one source. A case's name is its output file without `.tsv`.
-- A case of the form `SELECT column_name, column_type FROM (DESCRIBE <query>)`
-- records the type DuckDB gives each column of <query>; the test runs
-- <query> and compares its schema's types under DuckDB's names.
--
-- typed.csv   BIGINT, BIGINT, DOUBLE, DATE and VARCHAR columns, no NULL
-- quoted.csv  quoted cells: a comma, doubled quotes, a line break, padding,
--             a multi-byte character, quotes at both ends of the value
-- nulls.csv   an empty cell (NULL) in every column but id, a row of NULLs
-- pipe.csv    `|` between cells, a comma inside a cell
-- header_only.csv  a header and no row
-- no_header.csv    no header line: an integer, a text and a double column,
--                  a quoted comma and doubled quotes
-- no_header_wide.csv  no header line, eleven columns, so DuckDB pads the
--                  names to two digits (column00 .. column10)
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('typed.csv'))) TO 'typed_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, qty, price, name FROM read_csv('typed.csv')) TO 'typed_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT name, qty FROM read_csv('typed.csv') WHERE day >= DATE '2026-11-01' AND price > 2) TO 'typed_filter.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT name, count(*) AS n, sum(qty) AS total FROM read_csv('typed.csv') GROUP BY name) TO 'typed_group.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n, count(day) AS days, sum(qty) AS total, min(id) AS lo, max(qty) AS hi FROM read_csv('typed.csv')) TO 'typed_agg.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('typed.csv', all_varchar = true)) TO 'typed_varchar.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('quoted.csv'))) TO 'quoted_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('quoted.csv')) TO 'quoted_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('nulls.csv'))) TO 'nulls_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, qty, price, name FROM read_csv('nulls.csv')) TO 'nulls_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n, count(qty) AS qty, count(price) AS price, count(day) AS day, count(name) AS name FROM read_csv('nulls.csv')) TO 'nulls_counts.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id FROM read_csv('nulls.csv') WHERE qty IS NULL) TO 'nulls_filter.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT name, count(*) AS n FROM read_csv('nulls.csv') GROUP BY name) TO 'nulls_group.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('pipe.csv', delim = '|'))) TO 'pipe_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('pipe.csv', delim = '|')) TO 'pipe_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('header_only.csv', header = true))) TO 'header_only_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT count(*) AS n FROM read_csv('header_only.csv', header = true)) TO 'header_only_count.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('no_header.csv', header = false))) TO 'no_header_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('no_header.csv', header = false)) TO 'no_header_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column1, column2 FROM read_csv('no_header.csv', header = false) WHERE column0 >= 2) TO 'no_header_filter.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('no_header.csv', header = false, all_varchar = true)) TO 'no_header_varchar.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('pipe.csv', delim = '|', header = false))) TO 'no_header_pipe_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('pipe.csv', delim = '|', header = false)) TO 'no_header_pipe_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_csv('no_header_wide.csv', header = false))) TO 'no_header_wide_types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT * FROM read_csv('no_header_wide.csv', header = false)) TO 'no_header_wide_rows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
