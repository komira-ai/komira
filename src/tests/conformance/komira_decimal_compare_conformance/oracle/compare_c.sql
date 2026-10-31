-- compare_c.tsv: for each literal, how many rows of t `c <op> <literal>` keeps, the
-- sum of their id, and how many rows DuckDB cannot decide (the comparison raises a
-- conversion error: TRY gives NULL for a row whose c is not NULL), for each of the six
-- comparison operators. The literal is the SQL text the test runs too (a folded bound is
-- written as the arithmetic), so the file holds DuckDB's reading of it. NULL rows are in
-- neither the kept rows nor their complement. Column c is DECIMAL(19, 2).
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'c' AS col, '0.06' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.06)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.06)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.06) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.06)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.06)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.06) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.06)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.06)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.06) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.06)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.06)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.06) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.06)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.06)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.06) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.06)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.06)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.06) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 1 AS n, 'c' AS col, '0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.05) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.05) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.05) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.05) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.05) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.05) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 2 AS n, 'c' AS col, '0.07' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.07)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.07)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.07) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.07)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.07)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.07) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.07)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.07)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.07) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.07)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.07)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.07) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.07)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.07)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.07) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.07)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.07)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.07) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 3 AS n, 'c' AS col, '0.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.065) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.065) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.065) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.065) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.065) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.065) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 4 AS n, 'c' AS col, '0.055' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.055)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.055)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.055) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.055)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.055)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.055) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.055)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.055)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.055) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.055)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.055)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.055) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.055)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.055)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.055) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.055)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.055)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.055) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 5 AS n, 'c' AS col, '0.075' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.075)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.075)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.075) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.075)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.075)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.075) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.075)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.075)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.075) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.075)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.075)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.075) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.075)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.075)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.075) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.075)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.075)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.075) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 6 AS n, 'c' AS col, '0.0649' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.0649)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.0649)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.0649) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.0649)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.0649)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.0649) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.0649)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.0649)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.0649) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.0649)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.0649)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.0649) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.0649)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.0649)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.0649) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.0649)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.0649)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.0649) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 7 AS n, 'c' AS col, '0.0651' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.0651)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.0651)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.0651) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.0651)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.0651)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.0651) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.0651)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.0651)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.0651) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.0651)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.0651)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.0651) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.0651)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.0651)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.0651) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.0651)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.0651)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.0651) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 8 AS n, 'c' AS col, '0.0000001' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.0000001)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.0000001)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.0000001) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.0000001)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.0000001)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.0000001) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.0000001)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.0000001)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.0000001) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.0000001)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.0000001)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.0000001) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.0000001)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.0000001)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.0000001) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.0000001)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.0000001)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.0000001) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 9 AS n, 'c' AS col, '-0.0000001' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -0.0000001)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -0.0000001)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -0.0000001) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -0.0000001)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -0.0000001)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -0.0000001) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -0.0000001)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -0.0000001)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -0.0000001) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -0.0000001)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -0.0000001)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -0.0000001) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -0.0000001)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -0.0000001)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -0.0000001) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -0.0000001)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -0.0000001)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -0.0000001) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 10 AS n, 'c' AS col, '0' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 11 AS n, 'c' AS col, '1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 1) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 1) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 1) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 1) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 1) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 1) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 12 AS n, 'c' AS col, '-1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -1) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -1) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -1) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -1) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -1) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -1) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 13 AS n, 'c' AS col, '24' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 24)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 24)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 24) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 24)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 24)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 24) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 24)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 24)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 24) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 24)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 24)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 24) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 24)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 24)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 24) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 24)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 24)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 24) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 14 AS n, 'c' AS col, '23.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 23.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 23.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 23.995) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 23.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 23.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 23.995) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 23.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 23.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 23.995) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 23.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 23.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 23.995) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 23.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 23.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 23.995) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 23.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 23.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 23.995) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 15 AS n, 'c' AS col, '24.005' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 24.005)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 24.005)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 24.005) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 24.005)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 24.005)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 24.005) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 24.005)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 24.005)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 24.005) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 24.005)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 24.005)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 24.005) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 24.005)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 24.005)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 24.005) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 24.005)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 24.005)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 24.005) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 16 AS n, 'c' AS col, '24.00' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 24.00)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 24.00)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 24.00) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 24.00)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 24.00)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 24.00) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 24.00)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 24.00)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 24.00) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 24.00)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 24.00)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 24.00) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 24.00)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 24.00)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 24.00) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 24.00)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 24.00)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 24.00) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 17 AS n, 'c' AS col, '-0.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -0.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -0.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -0.065) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -0.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -0.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -0.065) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -0.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -0.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -0.065) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -0.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -0.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -0.065) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -0.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -0.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -0.065) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -0.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -0.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -0.065) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 18 AS n, 'c' AS col, '-0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -0.05) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -0.05) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -0.05) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -0.05) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -0.05) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -0.05) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 19 AS n, 'c' AS col, '-24' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -24)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -24)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -24) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -24)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -24)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -24) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -24)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -24)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -24) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -24)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -24)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -24) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -24)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -24)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -24) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -24)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -24)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -24) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 20 AS n, 'c' AS col, '-23.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -23.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -23.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -23.995) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -23.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -23.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -23.995) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -23.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -23.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -23.995) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -23.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -23.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -23.995) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -23.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -23.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -23.995) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -23.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -23.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -23.995) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 21 AS n, 'c' AS col, '0.06 - 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.06 - 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.06 - 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.06 - 0.01) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.06 - 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.06 - 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.06 - 0.01) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.06 - 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.06 - 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.06 - 0.01) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.06 - 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.06 - 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.06 - 0.01) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.06 - 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.06 - 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.06 - 0.01) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.06 - 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.06 - 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.06 - 0.01) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 22 AS n, 'c' AS col, '0.06 + 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.06 + 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.06 + 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.06 + 0.01) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.06 + 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.06 + 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.06 + 0.01) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.06 + 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.06 + 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.06 + 0.01) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.06 + 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.06 + 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.06 + 0.01) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.06 + 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.06 + 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.06 + 0.01) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.06 + 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.06 + 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.06 + 0.01) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 23 AS n, 'c' AS col, '1 - 0.94' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 1 - 0.94)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 1 - 0.94)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 1 - 0.94) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 1 - 0.94)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 1 - 0.94)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 1 - 0.94) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 1 - 0.94)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 1 - 0.94)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 1 - 0.94) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 1 - 0.94)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 1 - 0.94)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 1 - 0.94) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 1 - 0.94)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 1 - 0.94)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 1 - 0.94) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 1 - 0.94)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 1 - 0.94)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 1 - 0.94) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 24 AS n, 'c' AS col, '0.1 * 0.1 * 0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 0.1 * 0.1 * 0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 0.1 * 0.1 * 0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 0.1 * 0.1 * 0.1) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 0.1 * 0.1 * 0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 0.1 * 0.1 * 0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 0.1 * 0.1 * 0.1) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 0.1 * 0.1 * 0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 0.1 * 0.1 * 0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 0.1 * 0.1 * 0.1) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 0.1 * 0.1 * 0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 0.1 * 0.1 * 0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 0.1 * 0.1 * 0.1) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 0.1 * 0.1 * 0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 0.1 * 0.1 * 0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 0.1 * 0.1 * 0.1) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 0.1 * 0.1 * 0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 0.1 * 0.1 * 0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 0.1 * 0.1 * 0.1) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 25 AS n, 'c' AS col, '-0.06 + 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -0.06 + 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -0.06 + 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -0.06 + 0.01) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -0.06 + 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -0.06 + 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -0.06 + 0.01) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -0.06 + 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -0.06 + 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -0.06 + 0.01) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -0.06 + 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -0.06 + 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -0.06 + 0.01) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -0.06 + 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -0.06 + 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -0.06 + 0.01) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -0.06 + 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -0.06 + 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -0.06 + 0.01) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 26 AS n, 'c' AS col, '100' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 100)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 100)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 100) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 100)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 100)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 100) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 100)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 100)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 100) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 100)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 100)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 100) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 100)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 100)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 100) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 100)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 100)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 100) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 27 AS n, 'c' AS col, '99999999999999999.99' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 99999999999999999.99)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 99999999999999999.99)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 99999999999999999.99) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 99999999999999999.99)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 99999999999999999.99)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 99999999999999999.99) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 99999999999999999.99)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 99999999999999999.99)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 99999999999999999.99) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 99999999999999999.99)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 99999999999999999.99)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 99999999999999999.99) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 99999999999999999.99)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 99999999999999999.99)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 99999999999999999.99) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 99999999999999999.99)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 99999999999999999.99)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 99999999999999999.99) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 28 AS n, 'c' AS col, '99999999999999999.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 99999999999999999.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 99999999999999999.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 99999999999999999.995) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 99999999999999999.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 99999999999999999.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 99999999999999999.995) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 99999999999999999.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 99999999999999999.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 99999999999999999.995) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 99999999999999999.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 99999999999999999.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 99999999999999999.995) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 99999999999999999.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 99999999999999999.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 99999999999999999.995) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 99999999999999999.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 99999999999999999.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 99999999999999999.995) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 29 AS n, 'c' AS col, '-99999999999999999.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -99999999999999999.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -99999999999999999.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -99999999999999999.995) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -99999999999999999.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -99999999999999999.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -99999999999999999.995) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -99999999999999999.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -99999999999999999.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -99999999999999999.995) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -99999999999999999.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -99999999999999999.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -99999999999999999.995) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -99999999999999999.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -99999999999999999.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -99999999999999999.995) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -99999999999999999.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -99999999999999999.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -99999999999999999.995) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 30 AS n, 'c' AS col, '92233720368547758.07' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 92233720368547758.07)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 92233720368547758.07)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 92233720368547758.07) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 92233720368547758.07)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 92233720368547758.07)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 92233720368547758.07) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 92233720368547758.07)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 92233720368547758.07)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 92233720368547758.07) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 92233720368547758.07)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 92233720368547758.07)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 92233720368547758.07) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 92233720368547758.07)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 92233720368547758.07)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 92233720368547758.07) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 92233720368547758.07)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 92233720368547758.07)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 92233720368547758.07) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 31 AS n, 'c' AS col, '92233720368547758.075' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 92233720368547758.075)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 92233720368547758.075)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 92233720368547758.075) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 92233720368547758.075)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 92233720368547758.075)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 92233720368547758.075) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 92233720368547758.075)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 92233720368547758.075)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 92233720368547758.075) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 92233720368547758.075)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 92233720368547758.075)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 92233720368547758.075) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 92233720368547758.075)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 92233720368547758.075)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 92233720368547758.075) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 92233720368547758.075)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 92233720368547758.075)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 92233720368547758.075) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 32 AS n, 'c' AS col, '92233720368547758.08' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 92233720368547758.08)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 92233720368547758.08)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 92233720368547758.08) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 92233720368547758.08)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 92233720368547758.08)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 92233720368547758.08) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 92233720368547758.08)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 92233720368547758.08)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 92233720368547758.08) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 92233720368547758.08)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 92233720368547758.08)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 92233720368547758.08) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 92233720368547758.08)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 92233720368547758.08)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 92233720368547758.08) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 92233720368547758.08)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 92233720368547758.08)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 92233720368547758.08) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 33 AS n, 'c' AS col, '-92233720368547758.085' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -92233720368547758.085)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -92233720368547758.085)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -92233720368547758.085) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -92233720368547758.085)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -92233720368547758.085)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -92233720368547758.085) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -92233720368547758.085)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -92233720368547758.085)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -92233720368547758.085) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -92233720368547758.085)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -92233720368547758.085)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -92233720368547758.085) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -92233720368547758.085)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -92233720368547758.085)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -92233720368547758.085) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -92233720368547758.085)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -92233720368547758.085)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -92233720368547758.085) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 34 AS n, 'c' AS col, '- -0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < - -0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < - -0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < - -0.5) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= - -0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= - -0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= - -0.5) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > - -0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > - -0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > - -0.5) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= - -0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= - -0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= - -0.5) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = - -0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = - -0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = - -0.5) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> - -0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> - -0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> - -0.5) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 35 AS n, 'c' AS col, '9223372036854775807' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 9223372036854775807)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 9223372036854775807)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 9223372036854775807) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 9223372036854775807)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 9223372036854775807)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 9223372036854775807) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 9223372036854775807)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 9223372036854775807)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 9223372036854775807) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 9223372036854775807)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 9223372036854775807)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 9223372036854775807) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 9223372036854775807)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 9223372036854775807)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 9223372036854775807) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 9223372036854775807)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 9223372036854775807)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 9223372036854775807) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 36 AS n, 'c' AS col, '9223372036854775808' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 9223372036854775808)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 9223372036854775808)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 9223372036854775808) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 9223372036854775808)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 9223372036854775808)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 9223372036854775808) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 9223372036854775808)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 9223372036854775808)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 9223372036854775808) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 9223372036854775808)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 9223372036854775808)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 9223372036854775808) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 9223372036854775808)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 9223372036854775808)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 9223372036854775808) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 9223372036854775808)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 9223372036854775808)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 9223372036854775808) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 37 AS n, 'c' AS col, '-9223372036854775809' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < -9223372036854775809)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < -9223372036854775809)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < -9223372036854775809) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= -9223372036854775809)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= -9223372036854775809)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= -9223372036854775809) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > -9223372036854775809)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > -9223372036854775809)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > -9223372036854775809) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= -9223372036854775809)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= -9223372036854775809)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= -9223372036854775809) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = -9223372036854775809)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = -9223372036854775809)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = -9223372036854775809) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> -9223372036854775809)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> -9223372036854775809)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> -9223372036854775809) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 38 AS n, 'c' AS col, '18446744073709551615' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 18446744073709551615)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 18446744073709551615)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 18446744073709551615) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 18446744073709551615)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 18446744073709551615)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 18446744073709551615) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 18446744073709551615)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 18446744073709551615)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 18446744073709551615) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 18446744073709551615)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 18446744073709551615)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 18446744073709551615) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 18446744073709551615)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 18446744073709551615)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 18446744073709551615) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 18446744073709551615)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 18446744073709551615)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 18446744073709551615) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 39 AS n, 'c' AS col, '18446744073709551616' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 18446744073709551616)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 18446744073709551616)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 18446744073709551616) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 18446744073709551616)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 18446744073709551616)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 18446744073709551616) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 18446744073709551616)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 18446744073709551616)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 18446744073709551616) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 18446744073709551616)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 18446744073709551616)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 18446744073709551616) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 18446744073709551616)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 18446744073709551616)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 18446744073709551616) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 18446744073709551616)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 18446744073709551616)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 18446744073709551616) IS NULL AND c IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 40 AS n, 'c' AS col, '99999999999999999999' AS lit,
    (SELECT count(*) FROM t WHERE TRY(c < 99999999999999999999)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c < 99999999999999999999)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(c < 99999999999999999999) IS NULL AND c IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(c <= 99999999999999999999)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <= 99999999999999999999)) AS le_s, (SELECT count(*) FROM t WHERE TRY(c <= 99999999999999999999) IS NULL AND c IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(c > 99999999999999999999)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c > 99999999999999999999)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(c > 99999999999999999999) IS NULL AND c IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(c >= 99999999999999999999)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c >= 99999999999999999999)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(c >= 99999999999999999999) IS NULL AND c IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(c = 99999999999999999999)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c = 99999999999999999999)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(c = 99999999999999999999) IS NULL AND c IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(c <> 99999999999999999999)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(c <> 99999999999999999999)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(c <> 99999999999999999999) IS NULL AND c IS NOT NULL) AS ne_e
) AS q ORDER BY n
) TO 'compare_c.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
