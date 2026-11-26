-- The cases of test_run_sql_expr_beside_agg: each COPY line below is one case,
-- a SELECT item that is neither an aggregate nor a GROUP BY key beside an
-- aggregate, the query DuckDB runs over expr.parquet (data.sql) and the file
-- its answer goes to. The test reads THIS FILE for the query text and runs the
-- same text through run_sql with 'expr.parquet' replaced by the file's path,
-- so a query has one source. A case's name is its output file without `.tsv`.
COPY (SELECT 'o' AS src, count(*) AS n, sum(v) AS total FROM read_parquet('expr.parquet')) TO 'literal_ungrouped.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT 'o' AS src, count(*) AS n FROM read_parquet('expr.parquet') WHERE v > 100000000) TO 'literal_ungrouped_no_row.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT 'o' AS src, count(*) AS n FROM read_parquet('expr.parquet') WHERE v > 100000000 GROUP BY k) TO 'literal_grouped_no_row.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT 'pos' AS src, count(*) AS n FROM read_parquet('expr.parquet') WHERE k > 0 UNION ALL SELECT 'neg', count(*) FROM read_parquet('expr.parquet') WHERE k < 0 UNION ALL SELECT 'none', count(*) FROM read_parquet('expr.parquet') WHERE k IS NULL) TO 'literal_union_labels.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT k, 1 AS one, count(*) AS n FROM read_parquet('expr.parquet') GROUP BY k) TO 'int_literal_grouped.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT coalesce(s, 'none') AS st, count(*) AS n FROM read_parquet('expr.parquet') GROUP BY s) TO 'coalesce_of_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT upper(s) AS us, count(*) AS n FROM read_parquet('expr.parquet') GROUP BY s) TO 'upper_of_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT k + 1 AS k1, k * 2, count(*) AS n, sum(v) AS total FROM read_parquet('expr.parquet') GROUP BY k) TO 'arith_of_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT k, s, CASE WHEN s IS NULL THEN k ELSE k + 10 END AS ks, count(*) AS n FROM read_parquet('expr.parquet') GROUP BY k, s) TO 'expr_of_two_keys.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT (k + 1) * 2 AS kk, count(*) AS n FROM read_parquet('expr.parquet') GROUP BY k + 1) TO 'expr_of_computed_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT coalesce(s, 'none') AS st, count(*) AS n FROM read_parquet('expr.parquet') WHERE v > 0 GROUP BY s HAVING count(*) > 300) TO 'item_under_where_having.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
