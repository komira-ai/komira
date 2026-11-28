-- The cases of test_run_sql_window: each COPY line below is one case, the
-- query DuckDB runs over win.parquet (data.sql) and the file its answer goes
-- to. The test reads THIS FILE for the query text and runs the same text
-- through run_sql with 'win.parquet' replaced by the file's path, so a query
-- has one source. A case's name is its output file without `.tsv`. Every
-- window column is aliased, and each case is deterministic in DuckDB: a
-- function that reads row positions (row_number, lag, lead, ntile, first_value,
-- last_value, nth_value) orders by id, which has no tie, and the others
-- (rank, dense_rank, percent_rank, cume_dist, sum, count, avg, min, max)
-- may order by o, whose ties are peers.
COPY (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('win.parquet')) TO 'row_number_g.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, s, row_number() OVER (PARTITION BY s ORDER BY id DESC) AS rn FROM read_parquet('win.parquet')) TO 'row_number_s_desc.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, rank() OVER (PARTITION BY g ORDER BY o) AS rk, dense_rank() OVER (PARTITION BY g ORDER BY o) AS dr FROM read_parquet('win.parquet')) TO 'rank_dense_rank.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, percent_rank() OVER (PARTITION BY g ORDER BY o) AS pr, cume_dist() OVER (PARTITION BY g ORDER BY o) AS cd FROM read_parquet('win.parquet')) TO 'percent_rank_cume_dist.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, ntile(4) OVER (PARTITION BY g ORDER BY id) AS q FROM read_parquet('win.parquet')) TO 'ntile4.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, lag(v) OVER (PARTITION BY g ORDER BY id) AS lv1, lead(v, 2) OVER (PARTITION BY g ORDER BY id) AS ld2 FROM read_parquet('win.parquet')) TO 'lag_lead_v.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, lag(v, 1, 0) OVER (PARTITION BY g ORDER BY id) AS lv0, lead(v, 3, -1) OVER (PARTITION BY g ORDER BY id) AS ld3 FROM read_parquet('win.parquet')) TO 'lag_lead_default.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, s, lag(t, 1, 'none') OVER (PARTITION BY s ORDER BY id) AS lt, lead(t) OVER (PARTITION BY s ORDER BY id) AS ldt FROM read_parquet('win.parquet')) TO 'lag_lead_t.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, lag(f, 1, 0) OVER (PARTITION BY g ORDER BY id) AS lf FROM read_parquet('win.parquet')) TO 'lag_f_default.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, sum(v) OVER (PARTITION BY g ORDER BY o) AS sv FROM read_parquet('win.parquet')) TO 'running_sum_v.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, min(v) OVER (PARTITION BY g ORDER BY o) AS mnv, max(f) OVER (PARTITION BY g ORDER BY o) AS mxf, avg(v) OVER (PARTITION BY g ORDER BY o) AS av, count(v) OVER (PARTITION BY g ORDER BY o) AS cnv FROM read_parquet('win.parquet')) TO 'running_aggs_peers.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, sum(f) OVER (PARTITION BY g ORDER BY id) AS sf FROM read_parquet('win.parquet')) TO 'running_sum_f.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, sum(v) OVER (PARTITION BY g) AS sv, count(v) OVER (PARTITION BY g) AS cnv, count(*) OVER (PARTITION BY g) AS cnt, avg(v) OVER (PARTITION BY g) AS av, min(v) OVER (PARTITION BY g) AS mnv, max(v) OVER (PARTITION BY g) AS mxv FROM read_parquet('win.parquet')) TO 'whole_partition_aggs.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, min(f) OVER (PARTITION BY g) AS mnf, max(f) OVER (PARTITION BY g) AS mxf, sum(f) OVER (PARTITION BY g) AS sf FROM read_parquet('win.parquet')) TO 'whole_partition_f.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, sum(i) OVER (PARTITION BY g ORDER BY o) AS si, min(i) OVER (PARTITION BY g ORDER BY o) AS mni, max(i) OVER (PARTITION BY g ORDER BY o) AS mxi, avg(i) OVER (PARTITION BY g ORDER BY o) AS ai FROM read_parquet('win.parquet')) TO 'running_aggs_integer.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, sum(i) OVER (PARTITION BY g) AS si, min(i) OVER (PARTITION BY g) AS mni, max(i) OVER (PARTITION BY g) AS mxi, avg(i) OVER (PARTITION BY g) AS ai FROM read_parquet('win.parquet')) TO 'whole_partition_integer.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, first_value(v) OVER (PARTITION BY g ORDER BY id) AS fv, last_value(v) OVER (PARTITION BY g ORDER BY id) AS lastv, nth_value(v, 2) OVER (PARTITION BY g ORDER BY id) AS nthv, first_value(t) OVER (PARTITION BY g ORDER BY id) AS ft FROM read_parquet('win.parquet')) TO 'value_functions.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, last_value(v) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS lastv FROM read_parquet('win.parquet')) TO 'last_value_whole_frame.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, row_number() OVER (ORDER BY id) AS rn, sum(v) OVER () AS sv FROM read_parquet('win.parquet')) TO 'no_partition.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, b, row_number() OVER (PARTITION BY g, b ORDER BY o DESC, id) AS rn, rank() OVER (PARTITION BY g, b ORDER BY o DESC) AS rk FROM read_parquet('win.parquet')) TO 'two_keys.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, row_number() OVER (PARTITION BY g ORDER BY id) AS rn, rank() OVER (PARTITION BY s ORDER BY o DESC) AS rk, sum(v) OVER (PARTITION BY g ORDER BY o) AS sv, count(*) OVER (PARTITION BY g ORDER BY o) AS cnt FROM read_parquet('win.parquet')) TO 'several_windows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn, sum(v) OVER (PARTITION BY g ORDER BY o) AS sv FROM read_parquet('win.parquet') WHERE v > 0 AND g IS NOT NULL) TO 'over_where.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT g, id, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('win.parquet') ORDER BY g, id) TO 'ordered_output.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn, sum(v) OVER (PARTITION BY g) AS sv FROM read_parquet('win.parquet') WHERE id < 0) TO 'no_row.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
-- A window and a CTE that holds a repeated subtree: a CTE with a window read
-- twice, whole and under two filters; a window over a CTE that is an
-- aggregation read twice (a window per read, and over a union of the reads);
-- a join whose left side is a window while a CTE is read twice.
COPY (WITH w AS (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('win.parquet')) SELECT id, g, rn FROM w UNION ALL SELECT id, g, rn FROM w) TO 'cte_window_twice.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH w AS (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('win.parquet')) SELECT id, g, rn FROM w WHERE id < 2500 UNION ALL SELECT id, g, rn FROM w WHERE id >= 2500) TO 'cte_window_split.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH c AS (SELECT g, max(v) AS mxv FROM read_parquet('win.parquet') GROUP BY g) SELECT g, mxv, rank() OVER (ORDER BY mxv) AS rk FROM c UNION ALL SELECT g, mxv, dense_rank() OVER (ORDER BY g) AS rk FROM c) TO 'cte_window_over_group.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH c AS (SELECT g, max(v) AS mxv FROM read_parquet('win.parquet') GROUP BY g) SELECT g, mxv, rank() OVER (ORDER BY mxv) AS rk FROM (SELECT g, mxv FROM c UNION ALL SELECT g, mxv FROM c) u) TO 'cte_window_over_union.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH c AS (SELECT g, max(v) AS mxv FROM read_parquet('win.parquet') GROUP BY g) SELECT w.id, w.rn, a.mxv FROM (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('win.parquet')) w JOIN c a ON w.g = a.g UNION ALL SELECT mxv AS id, mxv AS rn, mxv FROM c) TO 'cte_window_join_shared.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
-- A window inside an expression, and beside a star: the percent of the
-- partition total, two windows in one expression, a window in a CASE and in a
-- function's argument, `*` and `w.*` before a window column, and an outer
-- ORDER BY on a window.
COPY (SELECT id, g, f, f * 100.0 / sum(f) OVER (PARTITION BY g) AS pct FROM read_parquet('win.parquet')) TO 'expr_percent_of_total.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, max(v) OVER (PARTITION BY g ORDER BY o) - min(v) OVER (PARTITION BY g ORDER BY o) AS spread FROM read_parquet('win.parquet')) TO 'expr_two_windows.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, CASE WHEN row_number() OVER (PARTITION BY g ORDER BY id) = 1 THEN v ELSE 0 END AS first_v FROM read_parquet('win.parquet')) TO 'expr_window_in_case.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, abs(v - coalesce(lag(v) OVER (PARTITION BY g ORDER BY id), 0)) AS jump FROM read_parquet('win.parquet')) TO 'expr_window_in_function.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT *, sum(v) OVER (PARTITION BY g) AS tot FROM (SELECT id, g, v FROM read_parquet('win.parquet')) w) TO 'expr_star_and_window.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT w.*, count(*) OVER (PARTITION BY w.g) AS cnt FROM (SELECT id, g, s FROM read_parquet('win.parquet')) w) TO 'expr_qualified_star_and_window.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g FROM read_parquet('win.parquet') ORDER BY sum(v) OVER (PARTITION BY g) DESC, id LIMIT 40) TO 'expr_order_by_window.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
