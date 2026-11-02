-- compare_m.tsv: for each literal, how many rows of t `m <op> <literal>` keeps, the
-- sum of their id, and how many rows DuckDB cannot decide (the comparison raises a
-- conversion error: TRY gives NULL for a row whose m is not NULL), for each of the six
-- comparison operators. The literal is the SQL text the test runs too (a folded bound is
-- written as the arithmetic), so the file holds DuckDB's reading of it. NULL rows are in
-- neither the kept rows nor their complement. Column m is DECIMAL(30, 2).
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'm' AS col, '0.06' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.06)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.06)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.06) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.06)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.06)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.06) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.06)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.06)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.06) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.06)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.06)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.06) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.06)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.06)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.06) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.06)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.06)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.06) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 1 AS n, 'm' AS col, '0.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.065) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.065) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.065) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.065) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.065) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.065) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 2 AS n, 'm' AS col, '0.055' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.055)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.055)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.055) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.055)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.055)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.055) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.055)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.055)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.055) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.055)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.055)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.055) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.055)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.055)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.055) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.055)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.055)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.055) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 3 AS n, 'm' AS col, '12345.065' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 12345.065)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 12345.065)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 12345.065) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 12345.065)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 12345.065)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 12345.065) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 12345.065)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 12345.065)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 12345.065) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 12345.065)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 12345.065)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 12345.065) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 12345.065)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 12345.065)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 12345.065) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 12345.065)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 12345.065)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 12345.065) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 4 AS n, 'm' AS col, '0.0000000001' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.0000000001)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.0000000001)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.0000000001) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.0000000001)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.0000000001)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.0000000001) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.0000000001)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.0000000001)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.0000000001) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.0000000001)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.0000000001)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.0000000001) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.0000000001)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.0000000001)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.0000000001) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.0000000001)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.0000000001)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.0000000001) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 5 AS n, 'm' AS col, '0.00000000005' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.00000000005)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.00000000005)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.00000000005) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.00000000005)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.00000000005)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.00000000005) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.00000000005)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.00000000005)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.00000000005) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.00000000005)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.00000000005)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.00000000005) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.00000000005)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.00000000005)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.00000000005) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.00000000005)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.00000000005)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.00000000005) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 6 AS n, 'm' AS col, '0.000000000049' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.000000000049)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.000000000049)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.000000000049) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.000000000049)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.000000000049)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.000000000049) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.000000000049)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.000000000049)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.000000000049) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.000000000049)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.000000000049)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.000000000049) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.000000000049)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.000000000049)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.000000000049) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.000000000049)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.000000000049)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.000000000049) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 7 AS n, 'm' AS col, '-0.00000000005' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < -0.00000000005)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < -0.00000000005)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < -0.00000000005) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= -0.00000000005)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= -0.00000000005)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= -0.00000000005) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > -0.00000000005)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > -0.00000000005)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > -0.00000000005) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= -0.00000000005)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= -0.00000000005)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= -0.00000000005) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = -0.00000000005)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = -0.00000000005)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = -0.00000000005) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> -0.00000000005)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> -0.00000000005)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> -0.00000000005) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 8 AS n, 'm' AS col, '0.0000000000051' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.0000000000051)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.0000000000051)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.0000000000051) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.0000000000051)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.0000000000051)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.0000000000051) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.0000000000051)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.0000000000051)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.0000000000051) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.0000000000051)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.0000000000051)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.0000000000051) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.0000000000051)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.0000000000051)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.0000000000051) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.0000000000051)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.0000000000051)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.0000000000051) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 9 AS n, 'm' AS col, '0.015' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.015)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.015)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.015) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.015)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.015)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.015) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.015)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.015)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.015) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.015)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.015)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.015) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.015)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.015)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.015) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.015)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.015)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.015) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 10 AS n, 'm' AS col, '0.025' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0.025)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0.025)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0.025) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0.025)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0.025)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0.025) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0.025)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0.025)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0.025) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0.025)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0.025)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0.025) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0.025)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0.025)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0.025) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0.025)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0.025)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0.025) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 11 AS n, 'm' AS col, '0' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 0)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 0) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 0)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 0) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 0)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 0) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 0)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 0) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 0)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 0) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 0)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 0) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 12 AS n, 'm' AS col, '1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 1) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 1) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 1) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 1) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 1) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 1) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 13 AS n, 'm' AS col, '-1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < -1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < -1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < -1) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= -1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= -1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= -1) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > -1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > -1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > -1) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= -1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= -1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= -1) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = -1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = -1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = -1) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> -1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> -1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> -1) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 14 AS n, 'm' AS col, '100000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 100000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 100000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 100000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 100000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 100000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 100000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 100000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 100000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 100000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 100000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 100000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 100000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 100000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 100000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 100000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 100000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 100000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 100000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 15 AS n, 'm' AS col, '1000000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(m < 1000000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m < 1000000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(m < 1000000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(m <= 1000000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <= 1000000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(m <= 1000000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(m > 1000000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m > 1000000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(m > 1000000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(m >= 1000000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m >= 1000000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(m >= 1000000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(m = 1000000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m = 1000000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(m = 1000000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(m <> 1000000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(m <> 1000000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(m <> 1000000000000000000000000000000000000) IS NULL AND m IS NOT NULL) AS ne_e
) AS q ORDER BY n
) TO 'compare_m.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
