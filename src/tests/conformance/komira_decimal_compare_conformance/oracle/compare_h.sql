-- compare_h.tsv: for each literal, how many rows of t `h <op> <literal>` keeps, the
-- sum of their id, and how many rows DuckDB cannot decide (the comparison raises a
-- conversion error: TRY gives NULL for a row whose h is not NULL), for each of the six
-- comparison operators. The literal is the SQL text the test runs too (a folded bound is
-- written as the arithmetic), so the file holds DuckDB's reading of it. NULL rows are in
-- neither the kept rows nor their complement. Column h is DECIMAL(15, 5).
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'h' AS col, '0.06' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.06)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.06)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.06) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.06)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.06)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.06) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.06)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.06)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.06) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.06)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.06)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.06) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.06)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.06)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.06) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.06)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.06)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.06) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 1 AS n, 'h' AS col, '0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.05) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.05) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.05) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.05) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.05) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.05) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 2 AS n, 'h' AS col, '0.07' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.07)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.07)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.07) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.07)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.07)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.07) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.07)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.07)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.07) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.07)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.07)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.07) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.07)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.07)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.07) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.07)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.07)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.07) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 3 AS n, 'h' AS col, '0.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.065) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.065) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.065) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.065) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.065) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.065) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 4 AS n, 'h' AS col, '0.0600001' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.0600001)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.0600001)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.0600001) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.0600001)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.0600001)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.0600001) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.0600001)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.0600001)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.0600001) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.0600001)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.0600001)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.0600001) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.0600001)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.0600001)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.0600001) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.0600001)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.0600001)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.0600001) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 5 AS n, 'h' AS col, '0.0599999' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.0599999)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.0599999)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.0599999) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.0599999)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.0599999)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.0599999) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.0599999)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.0599999)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.0599999) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.0599999)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.0599999)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.0599999) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.0599999)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.0599999)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.0599999) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.0599999)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.0599999)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.0599999) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 6 AS n, 'h' AS col, '0.000005' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.000005)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.000005)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.000005) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.000005)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.000005)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.000005) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.000005)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.000005)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.000005) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.000005)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.000005)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.000005) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.000005)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.000005)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.000005) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.000005)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.000005)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.000005) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 7 AS n, 'h' AS col, '-0.000005' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < -0.000005)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < -0.000005)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < -0.000005) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= -0.000005)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= -0.000005)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= -0.000005) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > -0.000005)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > -0.000005)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > -0.000005) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= -0.000005)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= -0.000005)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= -0.000005) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = -0.000005)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = -0.000005)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = -0.000005) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> -0.000005)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> -0.000005)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> -0.000005) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 8 AS n, 'h' AS col, '0.000015' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.000015)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.000015)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.000015) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.000015)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.000015)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.000015) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.000015)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.000015)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.000015) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.000015)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.000015)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.000015) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.000015)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.000015)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.000015) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.000015)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.000015)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.000015) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 9 AS n, 'h' AS col, '0.123455' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.123455)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.123455)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.123455) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.123455)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.123455)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.123455) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.123455)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.123455)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.123455) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.123455)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.123455)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.123455) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.123455)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.123455)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.123455) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.123455)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.123455)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.123455) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 10 AS n, 'h' AS col, '24' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 24)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 24)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 24) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 24)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 24)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 24) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 24)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 24)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 24) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 24)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 24)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 24) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 24)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 24)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 24) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 24)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 24)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 24) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 11 AS n, 'h' AS col, '24.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 24.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 24.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 24.5) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 24.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 24.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 24.5) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 24.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 24.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 24.5) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 24.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 24.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 24.5) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 24.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 24.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 24.5) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 24.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 24.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 24.5) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 12 AS n, 'h' AS col, '-24' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < -24)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < -24)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < -24) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= -24)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= -24)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= -24) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > -24)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > -24)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > -24) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= -24)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= -24)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= -24) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = -24)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = -24)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = -24) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> -24)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> -24)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> -24) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 13 AS n, 'h' AS col, '0' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 14 AS n, 'h' AS col, '1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 1) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 1) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 1) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 1) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 1) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 1) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 15 AS n, 'h' AS col, '0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.5) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.5) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.5) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.5) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.5) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.5) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 16 AS n, 'h' AS col, '0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.1) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.1) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.1) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.1) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.1) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.1) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 17 AS n, 'h' AS col, '- -0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < - -0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < - -0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < - -0.5) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= - -0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= - -0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= - -0.5) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > - -0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > - -0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > - -0.5) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= - -0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= - -0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= - -0.5) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = - -0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = - -0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = - -0.5) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> - -0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> - -0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> - -0.5) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 18 AS n, 'h' AS col, '0.06 - 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.06 - 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.06 - 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.06 - 0.01) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.06 - 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.06 - 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.06 - 0.01) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.06 - 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.06 - 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.06 - 0.01) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.06 - 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.06 - 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.06 - 0.01) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.06 - 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.06 - 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.06 - 0.01) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.06 - 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.06 - 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.06 - 0.01) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 19 AS n, 'h' AS col, '0.06 + 0.01' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.06 + 0.01)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.06 + 0.01)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.06 + 0.01) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.06 + 0.01)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.06 + 0.01)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.06 + 0.01) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.06 + 0.01)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.06 + 0.01)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.06 + 0.01) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.06 + 0.01)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.06 + 0.01)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.06 + 0.01) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.06 + 0.01)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.06 + 0.01)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.06 + 0.01) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.06 + 0.01)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.06 + 0.01)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.06 + 0.01) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 20 AS n, 'h' AS col, '0.1 * 0.1 * 0.1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 0.1 * 0.1 * 0.1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 0.1 * 0.1 * 0.1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 0.1 * 0.1 * 0.1) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 0.1 * 0.1 * 0.1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 0.1 * 0.1 * 0.1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 0.1 * 0.1 * 0.1) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 0.1 * 0.1 * 0.1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 0.1 * 0.1 * 0.1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 0.1 * 0.1 * 0.1) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 0.1 * 0.1 * 0.1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 0.1 * 0.1 * 0.1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 0.1 * 0.1 * 0.1) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 0.1 * 0.1 * 0.1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 0.1 * 0.1 * 0.1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 0.1 * 0.1 * 0.1) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 0.1 * 0.1 * 0.1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 0.1 * 0.1 * 0.1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 0.1 * 0.1 * 0.1) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 21 AS n, 'h' AS col, '9223372036854775808' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 9223372036854775808)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 9223372036854775808)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 9223372036854775808) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 9223372036854775808)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 9223372036854775808)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 9223372036854775808) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 9223372036854775808)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 9223372036854775808)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 9223372036854775808) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 9223372036854775808)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 9223372036854775808)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 9223372036854775808) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 9223372036854775808)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 9223372036854775808)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 9223372036854775808) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 9223372036854775808)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 9223372036854775808)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 9223372036854775808) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 22 AS n, 'h' AS col, '10000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 10000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 10000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 10000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 10000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 10000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 10000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 10000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 10000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 10000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 10000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 10000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 10000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 10000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 10000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 10000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 10000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 10000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 10000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 23 AS n, 'h' AS col, '100000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 100000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 100000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 100000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 100000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 100000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 100000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 100000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 100000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 100000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 100000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 100000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 100000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 100000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 100000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 100000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 100000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 100000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 100000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 24 AS n, 'h' AS col, '1000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(h < 1000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h < 1000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(h < 1000000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(h <= 1000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <= 1000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(h <= 1000000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(h > 1000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h > 1000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(h > 1000000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(h >= 1000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h >= 1000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(h >= 1000000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(h = 1000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h = 1000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(h = 1000000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(h <> 1000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(h <> 1000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(h <> 1000000000000000000000000000000000) IS NULL AND h IS NOT NULL) AS ne_e
) AS q ORDER BY n
) TO 'compare_h.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
