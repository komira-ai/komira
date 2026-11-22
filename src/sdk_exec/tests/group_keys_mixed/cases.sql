-- The cases of test_run_sql_group_keys_mixed: each COPY line below is one
-- case, the query DuckDB runs over mixed.parquet (data.sql) and the file its
-- answer goes to. The test reads THIS FILE for the query text and runs the
-- same text through run_sql with 'mixed.parquet' replaced by the file's path,
-- so a query has one source. A case's name is its output file without `.tsv`.
COPY (SELECT i, s, d, count(*) AS n, count(v) AS nv, sum(v) AS total, min(v) AS lo, max(v) AS hi FROM read_parquet('mixed.parquet') GROUP BY i, s, d) TO 'int_string_date.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT d, s, i, count(*) AS n FROM read_parquet('mixed.parquet') GROUP BY d, s, i) TO 'date_string_int.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT big, i, count(*) AS n, sum(v) AS total FROM read_parquet('mixed.parquet') GROUP BY big, i) TO 'bigint_int.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT b, m, s, count(*) AS n, sum(m) AS sm FROM read_parquet('mixed.parquet') GROUP BY b, m, s) TO 'bool_decimal_string.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT s, d, count(*) AS n, sum(v) AS total FROM read_parquet('mixed.parquet') WHERE v > 0 GROUP BY s, d) TO 'filtered.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT i, s, count(*) AS n FROM read_parquet('mixed.parquet') GROUP BY i, s HAVING count(*) > 260) TO 'having.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT i, d, count(DISTINCT s) AS ns FROM read_parquet('mixed.parquet') GROUP BY i, d) TO 'count_distinct.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT DISTINCT s, i, d FROM read_parquet('mixed.parquet')) TO 'distinct.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT i, s, count(*) AS n FROM read_parquet('mixed.parquet') WHERE i IS NULL AND s IS NULL GROUP BY i, s) TO 'all_null.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT i, s, d, count(*) AS n FROM read_parquet('mixed.parquet') WHERE v > 1000000 GROUP BY i, s, d) TO 'no_row.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
