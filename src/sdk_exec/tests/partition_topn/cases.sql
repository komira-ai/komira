-- The cases of test_run_sql_partition_topn: each COPY line below is one case,
-- the query DuckDB runs over top.parquet (data.sql) and the file its answer
-- goes to. The test reads THIS FILE for the query text and runs the same text
-- through run_sql with the table name replaced by the file's path, so a query
-- has one source. A case's name is its output file without `.tsv`. Each case
-- is deterministic in DuckDB: a ROW_NUMBER orders by a key list that ends in
-- id, which has no tie, or by a key with no tie in its partition, and a RANK
-- keeps every peer, so which peer comes first does not change its rows.
COPY (SELECT id, g, o FROM (SELECT id, g, o, row_number() OVER (PARTITION BY g ORDER BY o DESC, id) AS rn FROM read_parquet('top.parquet')) ranked WHERE rn <= 2) TO 'rn_le_2.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, rn FROM (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY o DESC, id) AS rn FROM read_parquet('top.parquet')) ranked WHERE rn < 3) TO 'rn_lt_3_kept.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, q, rn FROM (SELECT id, q, row_number() OVER (PARTITION BY q ORDER BY id DESC) AS rn FROM read_parquet('top.parquet')) ranked WHERE rn <= 3) TO 'rn_one_int_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, o FROM (SELECT id, o, row_number() OVER (ORDER BY o DESC, id) AS rn FROM read_parquet('top.parquet')) ranked WHERE rn <= 5) TO 'rn_no_partition.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g FROM (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('top.parquet')) ranked WHERE rn <= 1000) TO 'rn_k_past_every_group.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g, o, rk FROM (SELECT id, g, o, rank() OVER (PARTITION BY g ORDER BY o DESC) AS rk FROM read_parquet('top.parquet')) ranked WHERE rk <= 2) TO 'rank_le_2_ties.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, q, k FROM (SELECT id, q, k, rank() OVER (PARTITION BY q ORDER BY k) AS rk FROM read_parquet('top.parquet')) ranked WHERE rk <= 2) TO 'rank_ties_one_int_key.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, p, x, rk FROM (SELECT id, p, x, rank() OVER (PARTITION BY p ORDER BY x) AS rk FROM read_parquet('top.parquet')) ranked WHERE rk < 3) TO 'rank_lt_3_null_partition.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, p, o, rk FROM (SELECT id, p, o, rank() OVER (PARTITION BY p ORDER BY o DESC) AS rk FROM read_parquet('top.parquet')) ranked WHERE rk <= 1000) TO 'rank_null_order_keys_last.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g FROM (SELECT id, g, row_number() OVER (PARTITION BY g ORDER BY id) AS rn FROM read_parquet('top.parquet')) ranked WHERE rn <= 0) TO 'rn_le_0.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT id, g FROM (SELECT id, g, rank() OVER (PARTITION BY g ORDER BY o) AS rk FROM read_parquet('top.parquet')) ranked WHERE rk < 1) TO 'rank_lt_1.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
COPY (SELECT g, id, rn FROM (SELECT g, id, row_number() OVER (PARTITION BY g ORDER BY id DESC) AS rn FROM read_parquet('top.parquet') WHERE id % 3 = 0) ranked WHERE rn <= 2 ORDER BY g, rn) TO 'rn_over_where_ordered.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
