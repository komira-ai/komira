-- The WITH cases of test_run_sql_cte: each line below is one case, the query
-- DuckDB runs and the file its answer goes to. The test reads THIS FILE for
-- the query text and runs the same text through run_sql (with 'sales.csv'
-- replaced by the file's path), so a query has one source. A case's name is
-- its output file without `.tsv`.
--
-- sales.csv  id, region, qty, price: nine rows over four regions; row 9 has
--            no qty (NULL).
--
-- One reference to a CTE; a CTE that reads an earlier one; a CTE never read.
COPY (WITH s AS (SELECT region, qty FROM read_csv('sales.csv') WHERE qty > 2) SELECT region, sum(qty) AS total, count(*) AS n FROM s GROUP BY region) TO 'one_filtered_group.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH a AS (SELECT region, qty FROM read_csv('sales.csv')), b AS (SELECT region, sum(qty) AS total FROM a GROUP BY region) SELECT region, total FROM b WHERE total > 8) TO 'one_chain.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH unused AS (SELECT price FROM read_csv('sales.csv')), r AS (SELECT region, id FROM read_csv('sales.csv') WHERE id <= 4) SELECT region, id FROM r) TO 'one_unused.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH t AS (SELECT region, count(qty) AS q, count(*) AS n FROM read_csv('sales.csv') GROUP BY region) SELECT region, q, n FROM t WHERE q < n) TO 'one_null_counts.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH o AS (SELECT region, qty FROM read_csv('sales.csv') ORDER BY qty) SELECT region, max(qty) AS hi FROM o GROUP BY region) TO 'one_sorted_body.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH t AS (SELECT region, qty FROM read_csv('sales.csv')) SELECT region, n FROM (SELECT region, count(*) AS n FROM t GROUP BY region) d WHERE n = 2) TO 'one_in_derived.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
-- A CTE read more than once: an aggregation, the same under two filters, a
-- distinct read three times, a filtered scan, a limit, a subquery that reads
-- a CTE twice read twice, a union of a filtered scan read twice read twice,
-- a CTE joined with itself, an ungrouped aggregation. (A CTE body holds no derived table and no UNION
-- ALL: the binder and parser refuse both, so a repeat inside a repeat is
-- written with derived tables.)
COPY (WITH t AS (SELECT region, sum(qty) AS total FROM read_csv('sales.csv') GROUP BY region) SELECT region, total FROM t UNION ALL SELECT region, total FROM t) TO 'twice_group.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH t AS (SELECT region, count(*) AS n FROM read_csv('sales.csv') GROUP BY region) SELECT region, n FROM t WHERE n >= 3 UNION ALL SELECT region, n FROM t WHERE n < 3) TO 'twice_split.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH d AS (SELECT DISTINCT region FROM read_csv('sales.csv')) SELECT count(*) AS n FROM (SELECT region FROM d UNION ALL SELECT region FROM d UNION ALL SELECT region FROM d) u) TO 'twice_distinct_thrice.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH f AS (SELECT id, qty FROM read_csv('sales.csv') WHERE qty IS NOT NULL) SELECT count(*) AS n, sum(qty) AS total FROM (SELECT id, qty FROM f UNION ALL SELECT id, qty FROM f) u) TO 'twice_scan.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH l AS (SELECT id FROM read_csv('sales.csv') LIMIT 3) SELECT count(*) AS n FROM (SELECT id FROM l UNION ALL SELECT id FROM l) u) TO 'twice_limit.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH d AS (SELECT region FROM read_csv('sales.csv') WHERE qty > 2) SELECT n FROM (SELECT count(*) AS n FROM (SELECT region FROM d UNION ALL SELECT region FROM d) u) a UNION ALL SELECT n FROM (SELECT count(*) AS n FROM (SELECT region FROM d UNION ALL SELECT region FROM d) u) a) TO 'twice_nested.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH f AS (SELECT region FROM read_csv('sales.csv') WHERE qty > 2) SELECT region, count(*) AS n FROM (SELECT region FROM (SELECT region FROM f UNION ALL SELECT region FROM f) a UNION ALL SELECT region FROM (SELECT region FROM f UNION ALL SELECT region FROM f) b) w GROUP BY region) TO 'twice_nested_scan.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH t AS (SELECT id FROM read_csv('sales.csv') WHERE qty > 2) SELECT count(*) AS n FROM t a JOIN t b ON a.id = b.id) TO 'twice_self_join.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (WITH t AS (SELECT max(price) AS hi, min(price) AS lo, count(*) AS n FROM read_csv('sales.csv')) SELECT hi, lo, n FROM t UNION ALL SELECT hi, lo, n FROM t) TO 'twice_ungrouped.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
