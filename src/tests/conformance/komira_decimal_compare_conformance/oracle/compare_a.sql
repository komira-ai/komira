-- compare_a.tsv: for each literal, how many rows of t `a <op> <literal>` keeps, the
-- sum of their id, and how many rows DuckDB cannot decide (the comparison raises a
-- conversion error: TRY gives NULL for a row whose a is not NULL), for each of the six
-- comparison operators. The literal is the SQL text the test runs too (a folded bound is
-- written as the arithmetic), so the file holds DuckDB's reading of it. NULL rows are in
-- neither the kept rows nor their complement. Column a is DECIMAL(15, 2).
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'a' AS col, '0.06' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.06)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.06)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.06) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.06)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.06)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.06) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.06)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.06)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.06) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.06)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.06)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.06) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.06)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.06)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.06) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.06)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.06)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.06) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 1 AS n, 'a' AS col, '0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.05) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.05) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.05) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.05) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.05) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.05) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 2 AS n, 'a' AS col, '0.07' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.07)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.07)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.07) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.07)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.07)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.07) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.07)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.07)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.07) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.07)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.07)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.07) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.07)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.07)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.07) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.07)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.07)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.07) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 3 AS n, 'a' AS col, '0.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.065) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.065) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.065) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.065) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.065) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.065) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 4 AS n, 'a' AS col, '0.055' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.055)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.055)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.055) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.055)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.055)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.055) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.055)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.055)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.055) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.055)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.055)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.055) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.055)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.055)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.055) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.055)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.055)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.055) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 5 AS n, 'a' AS col, '0.075' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.075)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.075)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.075) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.075)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.075)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.075) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.075)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.075)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.075) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.075)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.075)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.075) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.075)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.075)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.075) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.075)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.075)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.075) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 6 AS n, 'a' AS col, '0.0649' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.0649)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.0649)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.0649) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.0649)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.0649)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.0649) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.0649)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.0649)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.0649) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.0649)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.0649)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.0649) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.0649)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.0649)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.0649) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.0649)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.0649)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.0649) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 7 AS n, 'a' AS col, '0.0651' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.0651)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.0651)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.0651) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.0651)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.0651)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.0651) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.0651)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.0651)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.0651) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.0651)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.0651)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.0651) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.0651)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.0651)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.0651) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.0651)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.0651)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.0651) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 8 AS n, 'a' AS col, '0.0000001' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.0000001)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.0000001)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.0000001) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.0000001)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.0000001)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.0000001) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.0000001)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.0000001)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.0000001) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.0000001)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.0000001)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.0000001) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.0000001)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.0000001)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.0000001) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.0000001)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.0000001)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.0000001) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 9 AS n, 'a' AS col, '-0.0000001' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -0.0000001)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -0.0000001)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -0.0000001) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -0.0000001)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -0.0000001)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -0.0000001) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -0.0000001)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -0.0000001)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -0.0000001) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -0.0000001)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -0.0000001)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -0.0000001) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -0.0000001)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -0.0000001)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -0.0000001) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -0.0000001)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -0.0000001)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -0.0000001) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 10 AS n, 'a' AS col, '0' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 11 AS n, 'a' AS col, '1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 12 AS n, 'a' AS col, '-1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 13 AS n, 'a' AS col, '24' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 24)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 24)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 24) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 24)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 24)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 24) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 24)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 24)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 24) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 24)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 24)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 24) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 24)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 24)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 24) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 24)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 24)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 24) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 14 AS n, 'a' AS col, '23.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 23.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 23.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 23.995) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 23.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 23.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 23.995) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 23.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 23.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 23.995) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 23.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 23.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 23.995) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 23.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 23.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 23.995) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 23.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 23.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 23.995) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 15 AS n, 'a' AS col, '24.005' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 24.005)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 24.005)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 24.005) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 24.005)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 24.005)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 24.005) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 24.005)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 24.005)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 24.005) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 24.005)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 24.005)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 24.005) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 24.005)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 24.005)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 24.005) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 24.005)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 24.005)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 24.005) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 16 AS n, 'a' AS col, '24.00' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 24.00)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 24.00)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 24.00) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 24.00)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 24.00)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 24.00) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 24.00)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 24.00)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 24.00) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 24.00)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 24.00)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 24.00) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 24.00)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 24.00)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 24.00) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 24.00)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 24.00)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 24.00) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 17 AS n, 'a' AS col, '-0.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -0.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -0.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -0.065) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -0.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -0.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -0.065) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -0.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -0.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -0.065) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -0.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -0.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -0.065) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -0.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -0.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -0.065) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -0.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -0.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -0.065) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 18 AS n, 'a' AS col, '-0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -0.05) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -0.05) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -0.05) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -0.05) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -0.05) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -0.05) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 19 AS n, 'a' AS col, '-24' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -24)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -24)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -24) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -24)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -24)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -24) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -24)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -24)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -24) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -24)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -24)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -24) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -24)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -24)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -24) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -24)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -24)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -24) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 20 AS n, 'a' AS col, '-23.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -23.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -23.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -23.995) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -23.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -23.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -23.995) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -23.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -23.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -23.995) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -23.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -23.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -23.995) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -23.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -23.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -23.995) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -23.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -23.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -23.995) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 21 AS n, 'a' AS col, '0.06 - 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.06 - 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.06 - 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.06 - 0.01) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.06 - 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.06 - 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.06 - 0.01) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.06 - 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.06 - 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.06 - 0.01) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.06 - 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.06 - 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.06 - 0.01) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.06 - 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.06 - 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.06 - 0.01) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.06 - 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.06 - 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.06 - 0.01) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 22 AS n, 'a' AS col, '0.06 + 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.06 + 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.06 + 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.06 + 0.01) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.06 + 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.06 + 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.06 + 0.01) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.06 + 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.06 + 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.06 + 0.01) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.06 + 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.06 + 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.06 + 0.01) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.06 + 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.06 + 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.06 + 0.01) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.06 + 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.06 + 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.06 + 0.01) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 23 AS n, 'a' AS col, '1 - 0.94' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1 - 0.94)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1 - 0.94)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1 - 0.94) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1 - 0.94)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1 - 0.94)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1 - 0.94) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1 - 0.94)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1 - 0.94)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1 - 0.94) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1 - 0.94)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1 - 0.94)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1 - 0.94) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1 - 0.94)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1 - 0.94)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1 - 0.94) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1 - 0.94)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1 - 0.94)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1 - 0.94) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 24 AS n, 'a' AS col, '0.1 * 0.1 * 0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.1 * 0.1 * 0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.1 * 0.1 * 0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.1 * 0.1 * 0.1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.1 * 0.1 * 0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.1 * 0.1 * 0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.1 * 0.1 * 0.1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.1 * 0.1 * 0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.1 * 0.1 * 0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.1 * 0.1 * 0.1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.1 * 0.1 * 0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.1 * 0.1 * 0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.1 * 0.1 * 0.1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.1 * 0.1 * 0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.1 * 0.1 * 0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.1 * 0.1 * 0.1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.1 * 0.1 * 0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.1 * 0.1 * 0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.1 * 0.1 * 0.1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 25 AS n, 'a' AS col, '-0.06 + 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -0.06 + 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -0.06 + 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -0.06 + 0.01) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -0.06 + 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -0.06 + 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -0.06 + 0.01) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -0.06 + 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -0.06 + 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -0.06 + 0.01) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -0.06 + 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -0.06 + 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -0.06 + 0.01) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -0.06 + 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -0.06 + 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -0.06 + 0.01) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -0.06 + 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -0.06 + 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -0.06 + 0.01) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 26 AS n, 'a' AS col, '100' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 100)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 100)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 100) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 100)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 100)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 100) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 100)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 100)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 100) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 100)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 100)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 100) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 100)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 100)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 100) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 100)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 100)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 100) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 27 AS n, 'a' AS col, '9999999999999.99' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 9999999999999.99)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 9999999999999.99)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 9999999999999.99) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 9999999999999.99)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 9999999999999.99)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 9999999999999.99) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 9999999999999.99)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 9999999999999.99)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 9999999999999.99) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 9999999999999.99)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 9999999999999.99)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 9999999999999.99) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 9999999999999.99)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 9999999999999.99)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 9999999999999.99) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 9999999999999.99)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 9999999999999.99)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 9999999999999.99) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 28 AS n, 'a' AS col, '9999999999999.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 9999999999999.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 9999999999999.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 9999999999999.995) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 9999999999999.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 9999999999999.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 9999999999999.995) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 9999999999999.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 9999999999999.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 9999999999999.995) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 9999999999999.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 9999999999999.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 9999999999999.995) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 9999999999999.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 9999999999999.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 9999999999999.995) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 9999999999999.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 9999999999999.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 9999999999999.995) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 29 AS n, 'a' AS col, '-9999999999999.995' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -9999999999999.995)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -9999999999999.995)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -9999999999999.995) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -9999999999999.995)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -9999999999999.995)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -9999999999999.995) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -9999999999999.995)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -9999999999999.995)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -9999999999999.995) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -9999999999999.995)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -9999999999999.995)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -9999999999999.995) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -9999999999999.995)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -9999999999999.995)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -9999999999999.995) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -9999999999999.995)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -9999999999999.995)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -9999999999999.995) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 30 AS n, 'a' AS col, '-9999999999999.99' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -9999999999999.99)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -9999999999999.99)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -9999999999999.99) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -9999999999999.99)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -9999999999999.99)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -9999999999999.99) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -9999999999999.99)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -9999999999999.99)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -9999999999999.99) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -9999999999999.99)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -9999999999999.99)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -9999999999999.99) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -9999999999999.99)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -9999999999999.99)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -9999999999999.99) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -9999999999999.99)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -9999999999999.99)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -9999999999999.99) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 31 AS n, 'a' AS col, '- -0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < - -0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < - -0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < - -0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= - -0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= - -0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= - -0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > - -0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > - -0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > - -0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= - -0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= - -0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= - -0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = - -0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = - -0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = - -0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> - -0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> - -0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> - -0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 32 AS n, 'a' AS col, '5.' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 5.)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 5.)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 5.) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 5.)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 5.)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 5.) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 5.)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 5.)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 5.) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 5.)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 5.)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 5.) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 5.)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 5.)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 5.) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 5.)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 5.)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 5.) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 33 AS n, 'a' AS col, '.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < .5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < .5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < .5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= .5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= .5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= .5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > .5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > .5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > .5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= .5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= .5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= .5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = .5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = .5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = .5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> .5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> .5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> .5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 34 AS n, 'a' AS col, '00.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 00.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 00.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 00.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 00.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 00.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 00.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 00.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 00.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 00.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 00.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 00.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 00.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 00.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 00.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 00.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 00.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 00.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 00.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 35 AS n, 'a' AS col, '-5.' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -5.)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -5.)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -5.) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -5.)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -5.)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -5.) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -5.)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -5.)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -5.) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -5.)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -5.)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -5.) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -5.)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -5.)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -5.) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -5.)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -5.)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -5.) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 36 AS n, 'a' AS col, '1e-2' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1e-2)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1e-2)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1e-2) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1e-2)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1e-2)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1e-2) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1e-2)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1e-2)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1e-2) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1e-2)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1e-2)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1e-2) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1e-2)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1e-2)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1e-2) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1e-2)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1e-2)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1e-2) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 37 AS n, 'a' AS col, '1e-1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1e-1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1e-1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1e-1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1e-1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1e-1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1e-1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1e-1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1e-1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1e-1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1e-1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1e-1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1e-1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1e-1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1e-1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1e-1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1e-1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1e-1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1e-1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 38 AS n, 'a' AS col, '2.5e1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 2.5e1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 2.5e1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 2.5e1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 2.5e1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 2.5e1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 2.5e1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 2.5e1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 2.5e1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 2.5e1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 2.5e1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 2.5e1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 2.5e1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 2.5e1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 2.5e1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 2.5e1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 2.5e1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 2.5e1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 2.5e1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 39 AS n, 'a' AS col, '10000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 10000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 10000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 10000000000000000) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 10000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 10000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 10000000000000000) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 10000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 10000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 10000000000000000) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 10000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 10000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 10000000000000000) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 10000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 10000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 10000000000000000) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 10000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 10000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 10000000000000000) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 40 AS n, 'a' AS col, '99999999999999999999' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 99999999999999999999)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 99999999999999999999)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 99999999999999999999) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 99999999999999999999)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 99999999999999999999)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 99999999999999999999) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 99999999999999999999)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 99999999999999999999)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 99999999999999999999) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 99999999999999999999)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 99999999999999999999)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 99999999999999999999) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 99999999999999999999)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 99999999999999999999)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 99999999999999999999) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 99999999999999999999)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 99999999999999999999)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 99999999999999999999) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 41 AS n, 'a' AS col, '100000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 100000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 100000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 100000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 100000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 100000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 100000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 100000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 100000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 100000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 100000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 100000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 100000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 100000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 100000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 100000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 100000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 100000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 100000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 42 AS n, 'a' AS col, '1000000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1000000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1000000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1000000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1000000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1000000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1000000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1000000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1000000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1000000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1000000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1000000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1000000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 43 AS n, 'a' AS col, '-1000000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -1000000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -1000000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -1000000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -1000000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -1000000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -1000000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -1000000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -1000000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -1000000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -1000000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -1000000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -1000000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -1000000000000000000000000000000000000) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 44 AS n, 'a' AS col, '(1+2)*0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < (1+2)*0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < (1+2)*0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < (1+2)*0.1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= (1+2)*0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= (1+2)*0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= (1+2)*0.1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > (1+2)*0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > (1+2)*0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > (1+2)*0.1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= (1+2)*0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= (1+2)*0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= (1+2)*0.1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = (1+2)*0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = (1+2)*0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = (1+2)*0.1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> (1+2)*0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> (1+2)*0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> (1+2)*0.1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 45 AS n, 'a' AS col, '2*3*0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 2*3*0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 2*3*0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 2*3*0.05) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 2*3*0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 2*3*0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 2*3*0.05) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 2*3*0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 2*3*0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 2*3*0.05) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 2*3*0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 2*3*0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 2*3*0.05) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 2*3*0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 2*3*0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 2*3*0.05) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 2*3*0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 2*3*0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 2*3*0.05) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 46 AS n, 'a' AS col, '0.1*(1+2)' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.1*(1+2))) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.1*(1+2))) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.1*(1+2)) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.1*(1+2))) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.1*(1+2))) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.1*(1+2)) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.1*(1+2))) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.1*(1+2))) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.1*(1+2)) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.1*(1+2))) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.1*(1+2))) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.1*(1+2)) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.1*(1+2))) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.1*(1+2))) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.1*(1+2)) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.1*(1+2))) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.1*(1+2))) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.1*(1+2)) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 47 AS n, 'a' AS col, '(5-3)+0.07' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < (5-3)+0.07)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < (5-3)+0.07)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < (5-3)+0.07) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= (5-3)+0.07)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= (5-3)+0.07)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= (5-3)+0.07) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > (5-3)+0.07)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > (5-3)+0.07)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > (5-3)+0.07) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= (5-3)+0.07)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= (5-3)+0.07)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= (5-3)+0.07) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = (5-3)+0.07)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = (5-3)+0.07)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = (5-3)+0.07) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> (5-3)+0.07)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> (5-3)+0.07)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> (5-3)+0.07) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 48 AS n, 'a' AS col, '2147483647 + 0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 2147483647 + 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 2147483647 + 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 2147483647 + 0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 2147483647 + 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 2147483647 + 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 2147483647 + 0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 2147483647 + 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 2147483647 + 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 2147483647 + 0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 2147483647 + 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 2147483647 + 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 2147483647 + 0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 2147483647 + 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 2147483647 + 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 2147483647 + 0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 2147483647 + 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 2147483647 + 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 2147483647 + 0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 49 AS n, 'a' AS col, '-2147483648 + 0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -2147483648 + 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -2147483648 + 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -2147483648 + 0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -2147483648 + 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -2147483648 + 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -2147483648 + 0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -2147483648 + 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -2147483648 + 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -2147483648 + 0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -2147483648 + 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -2147483648 + 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -2147483648 + 0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -2147483648 + 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -2147483648 + 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -2147483648 + 0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -2147483648 + 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -2147483648 + 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -2147483648 + 0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 50 AS n, 'a' AS col, '(2147483647+1)*0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < (2147483647+1)*0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < (2147483647+1)*0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < (2147483647+1)*0.1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= (2147483647+1)*0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= (2147483647+1)*0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= (2147483647+1)*0.1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > (2147483647+1)*0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > (2147483647+1)*0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > (2147483647+1)*0.1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= (2147483647+1)*0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= (2147483647+1)*0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= (2147483647+1)*0.1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = (2147483647+1)*0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = (2147483647+1)*0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = (2147483647+1)*0.1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> (2147483647+1)*0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> (2147483647+1)*0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> (2147483647+1)*0.1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 51 AS n, 'a' AS col, '(3000000000+1)*0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < (3000000000+1)*0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < (3000000000+1)*0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < (3000000000+1)*0.1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= (3000000000+1)*0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= (3000000000+1)*0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= (3000000000+1)*0.1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > (3000000000+1)*0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > (3000000000+1)*0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > (3000000000+1)*0.1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= (3000000000+1)*0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= (3000000000+1)*0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= (3000000000+1)*0.1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = (3000000000+1)*0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = (3000000000+1)*0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = (3000000000+1)*0.1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> (3000000000+1)*0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> (3000000000+1)*0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> (3000000000+1)*0.1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 52 AS n, 'a' AS col, '1-2-3+0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1-2-3+0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1-2-3+0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1-2-3+0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1-2-3+0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1-2-3+0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1-2-3+0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1-2-3+0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1-2-3+0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1-2-3+0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1-2-3+0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1-2-3+0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1-2-3+0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1-2-3+0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1-2-3+0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1-2-3+0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1-2-3+0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1-2-3+0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1-2-3+0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 53 AS n, 'a' AS col, '+0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < +0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < +0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < +0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= +0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= +0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= +0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > +0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > +0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > +0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= +0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= +0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= +0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = +0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = +0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = +0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> +0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> +0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> +0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 54 AS n, 'a' AS col, '- +0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < - +0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < - +0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < - +0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= - +0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= - +0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= - +0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > - +0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > - +0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > - +0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= - +0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= - +0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= - +0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = - +0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = - +0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = - +0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> - +0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> - +0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> - +0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 55 AS n, 'a' AS col, '+5.' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < +5.)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < +5.)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < +5.) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= +5.)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= +5.)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= +5.) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > +5.)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > +5.)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > +5.) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= +5.)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= +5.)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= +5.) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = +5.)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = +5.)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = +5.) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> +5.)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> +5.)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> +5.) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 56 AS n, 'a' AS col, '1.5e-2' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1.5e-2)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1.5e-2)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1.5e-2) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1.5e-2)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1.5e-2)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1.5e-2) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1.5e-2)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1.5e-2)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1.5e-2) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1.5e-2)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1.5e-2)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1.5e-2) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1.5e-2)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1.5e-2)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1.5e-2) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1.5e-2)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1.5e-2)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1.5e-2) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 57 AS n, 'a' AS col, '1e-3' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1e-3)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1e-3)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1e-3) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1e-3)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1e-3)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1e-3) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1e-3)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1e-3)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1e-3) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1e-3)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1e-3)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1e-3) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1e-3)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1e-3)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1e-3) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1e-3)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1e-3)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1e-3) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 58 AS n, 'a' AS col, '1e1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1e1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1e1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1e1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1e1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1e1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1e1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1e1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1e1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1e1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1e1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1e1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1e1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1e1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1e1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1e1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1e1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1e1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1e1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 59 AS n, 'a' AS col, '3e-1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 3e-1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 3e-1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 3e-1) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 3e-1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 3e-1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 3e-1) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 3e-1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 3e-1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 3e-1) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 3e-1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 3e-1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 3e-1) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 3e-1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 3e-1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 3e-1) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 3e-1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 3e-1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 3e-1) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 60 AS n, 'a' AS col, '(9223372036854775807*2)*0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < (9223372036854775807*2)*0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < (9223372036854775807*2)*0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < (9223372036854775807*2)*0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= (9223372036854775807*2)*0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= (9223372036854775807*2)*0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= (9223372036854775807*2)*0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > (9223372036854775807*2)*0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > (9223372036854775807*2)*0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > (9223372036854775807*2)*0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= (9223372036854775807*2)*0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= (9223372036854775807*2)*0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= (9223372036854775807*2)*0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = (9223372036854775807*2)*0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = (9223372036854775807*2)*0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = (9223372036854775807*2)*0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> (9223372036854775807*2)*0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> (9223372036854775807*2)*0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> (9223372036854775807*2)*0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 61 AS n, 'a' AS col, '1e100' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1e100)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1e100)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1e100) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1e100)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1e100)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1e100) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1e100)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1e100)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1e100) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1e100)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1e100)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1e100) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1e100)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1e100)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1e100) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1e100)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1e100)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1e100) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 62 AS n, 'a' AS col, '-1e100' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -1e100)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -1e100)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -1e100) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -1e100)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -1e100)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -1e100) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -1e100)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -1e100)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -1e100) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -1e100)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -1e100)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -1e100) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -1e100)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -1e100)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -1e100) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -1e100)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -1e100)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -1e100) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 63 AS n, 'a' AS col, '1e-30' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1e-30)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1e-30)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1e-30) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1e-30)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1e-30)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1e-30) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1e-30)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1e-30)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1e-30) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1e-30)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1e-30)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1e-30) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1e-30)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1e-30)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1e-30) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1e-30)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1e-30)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1e-30) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 64 AS n, 'a' AS col, '1.7976931348623157e308' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1.7976931348623157e308)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1.7976931348623157e308)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1.7976931348623157e308) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1.7976931348623157e308)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1.7976931348623157e308)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1.7976931348623157e308) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1.7976931348623157e308)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1.7976931348623157e308)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1.7976931348623157e308) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1.7976931348623157e308)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1.7976931348623157e308)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1.7976931348623157e308) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1.7976931348623157e308)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1.7976931348623157e308)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1.7976931348623157e308) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1.7976931348623157e308)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1.7976931348623157e308)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1.7976931348623157e308) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 65 AS n, 'a' AS col, '1234567890123456789012345678901234567890.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 1234567890123456789012345678901234567890.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 1234567890123456789012345678901234567890.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 1234567890123456789012345678901234567890.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 1234567890123456789012345678901234567890.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 1234567890123456789012345678901234567890.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 1234567890123456789012345678901234567890.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 1234567890123456789012345678901234567890.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 1234567890123456789012345678901234567890.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 1234567890123456789012345678901234567890.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 1234567890123456789012345678901234567890.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 1234567890123456789012345678901234567890.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 1234567890123456789012345678901234567890.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 1234567890123456789012345678901234567890.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 1234567890123456789012345678901234567890.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 1234567890123456789012345678901234567890.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 1234567890123456789012345678901234567890.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 1234567890123456789012345678901234567890.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 1234567890123456789012345678901234567890.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 66 AS n, 'a' AS col, '0.1234567890123456789012345678901234567890' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.1234567890123456789012345678901234567890)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.1234567890123456789012345678901234567890)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.1234567890123456789012345678901234567890) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.1234567890123456789012345678901234567890)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.1234567890123456789012345678901234567890)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.1234567890123456789012345678901234567890) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.1234567890123456789012345678901234567890)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.1234567890123456789012345678901234567890)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.1234567890123456789012345678901234567890) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.1234567890123456789012345678901234567890)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.1234567890123456789012345678901234567890)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.1234567890123456789012345678901234567890) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.1234567890123456789012345678901234567890)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.1234567890123456789012345678901234567890)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.1234567890123456789012345678901234567890) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.1234567890123456789012345678901234567890)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.1234567890123456789012345678901234567890)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.1234567890123456789012345678901234567890) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 67 AS n, 'a' AS col, '0.1 + 0.2 + 7 % 4' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 0.1 + 0.2 + 7 % 4)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 0.1 + 0.2 + 7 % 4)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 0.1 + 0.2 + 7 % 4) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 0.1 + 0.2 + 7 % 4)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 0.1 + 0.2 + 7 % 4)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 0.1 + 0.2 + 7 % 4) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 0.1 + 0.2 + 7 % 4)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 0.1 + 0.2 + 7 % 4)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 0.1 + 0.2 + 7 % 4) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 0.1 + 0.2 + 7 % 4)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 0.1 + 0.2 + 7 % 4)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 0.1 + 0.2 + 7 % 4) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 0.1 + 0.2 + 7 % 4)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 0.1 + 0.2 + 7 % 4)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 0.1 + 0.2 + 7 % 4) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 0.1 + 0.2 + 7 % 4)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 0.1 + 0.2 + 7 % 4)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 0.1 + 0.2 + 7 % 4) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 68 AS n, 'a' AS col, '7 // 2 * 0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < 7 // 2 * 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < 7 // 2 * 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < 7 // 2 * 0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= 7 // 2 * 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= 7 // 2 * 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= 7 // 2 * 0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > 7 // 2 * 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > 7 // 2 * 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > 7 // 2 * 0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= 7 // 2 * 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= 7 // 2 * 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= 7 // 2 * 0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = 7 // 2 * 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = 7 // 2 * 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = 7 // 2 * 0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> 7 // 2 * 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> 7 // 2 * 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> 7 // 2 * 0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 69 AS n, 'a' AS col, '-7 % 4 + 0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -7 % 4 + 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -7 % 4 + 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -7 % 4 + 0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -7 % 4 + 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -7 % 4 + 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -7 % 4 + 0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -7 % 4 + 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -7 % 4 + 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -7 % 4 + 0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -7 % 4 + 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -7 % 4 + 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -7 % 4 + 0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -7 % 4 + 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -7 % 4 + 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -7 % 4 + 0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -7 % 4 + 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -7 % 4 + 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -7 % 4 + 0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 70 AS n, 'a' AS col, '-(-2147483647 - 1) * 0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -(-2147483647 - 1) * 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -(-2147483647 - 1) * 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -(-2147483647 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -(-2147483647 - 1) * 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -(-2147483647 - 1) * 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -(-2147483647 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -(-2147483647 - 1) * 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -(-2147483647 - 1) * 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -(-2147483647 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -(-2147483647 - 1) * 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -(-2147483647 - 1) * 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -(-2147483647 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -(-2147483647 - 1) * 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -(-2147483647 - 1) * 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -(-2147483647 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -(-2147483647 - 1) * 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -(-2147483647 - 1) * 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -(-2147483647 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 71 AS n, 'a' AS col, '-(-9223372036854775807 - 1) * 0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(a < -(-9223372036854775807 - 1) * 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a < -(-9223372036854775807 - 1) * 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(a < -(-9223372036854775807 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(a <= -(-9223372036854775807 - 1) * 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <= -(-9223372036854775807 - 1) * 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(a <= -(-9223372036854775807 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(a > -(-9223372036854775807 - 1) * 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a > -(-9223372036854775807 - 1) * 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(a > -(-9223372036854775807 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(a >= -(-9223372036854775807 - 1) * 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a >= -(-9223372036854775807 - 1) * 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(a >= -(-9223372036854775807 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(a = -(-9223372036854775807 - 1) * 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a = -(-9223372036854775807 - 1) * 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(a = -(-9223372036854775807 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(a <> -(-9223372036854775807 - 1) * 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(a <> -(-9223372036854775807 - 1) * 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(a <> -(-9223372036854775807 - 1) * 0.5) IS NULL AND a IS NOT NULL) AS ne_e
) AS q ORDER BY n
) TO 'compare_a.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
