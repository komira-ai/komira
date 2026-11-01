-- compare_e.tsv: for each literal, how many rows of t `e <op> <literal>` keeps, the
-- sum of their id, and how many rows DuckDB cannot decide (the comparison raises a
-- conversion error: TRY gives NULL for a row whose e is not NULL), for each of the six
-- comparison operators. The literal is the SQL text the test runs too (a folded bound is
-- written as the arithmetic), so the file holds DuckDB's reading of it. NULL rows are in
-- neither the kept rows nor their complement. Column e is DECIMAL(38, 0).
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'e' AS col, '0.4' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.4)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.4)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.4) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.4)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.4)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.4) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.4)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.4)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.4) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.4)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.4)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.4) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.4)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.4)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.4) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.4)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.4)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.4) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 1 AS n, 'e' AS col, '0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.5) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.5) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.5) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.5) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.5) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.5) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 2 AS n, 'e' AS col, '0.6' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.6)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.6)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.6) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.6)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.6)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.6) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.6)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.6)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.6) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.6)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.6)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.6) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.6)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.6)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.6) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.6)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.6)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.6) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 3 AS n, 'e' AS col, '-0.4' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -0.4)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -0.4)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -0.4) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -0.4)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -0.4)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -0.4) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -0.4)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -0.4)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -0.4) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -0.4)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -0.4)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -0.4) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -0.4)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -0.4)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -0.4) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -0.4)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -0.4)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -0.4) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 4 AS n, 'e' AS col, '-0.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -0.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -0.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -0.5) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -0.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -0.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -0.5) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -0.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -0.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -0.5) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -0.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -0.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -0.5) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -0.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -0.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -0.5) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -0.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -0.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -0.5) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 5 AS n, 'e' AS col, '-0.6' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -0.6)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -0.6)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -0.6) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -0.6)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -0.6)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -0.6) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -0.6)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -0.6)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -0.6) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -0.6)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -0.6)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -0.6) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -0.6)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -0.6)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -0.6) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -0.6)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -0.6)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -0.6) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 6 AS n, 'e' AS col, '1.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 1.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 1.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 1.5) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 1.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 1.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 1.5) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 1.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 1.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 1.5) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 1.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 1.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 1.5) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 1.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 1.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 1.5) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 1.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 1.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 1.5) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 7 AS n, 'e' AS col, '2.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 2.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 2.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 2.5) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 2.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 2.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 2.5) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 2.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 2.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 2.5) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 2.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 2.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 2.5) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 2.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 2.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 2.5) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 2.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 2.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 2.5) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 8 AS n, 'e' AS col, '-1.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -1.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -1.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -1.5) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -1.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -1.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -1.5) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -1.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -1.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -1.5) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -1.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -1.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -1.5) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -1.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -1.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -1.5) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -1.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -1.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -1.5) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 9 AS n, 'e' AS col, '-2.5' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -2.5)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -2.5)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -2.5) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -2.5)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -2.5)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -2.5) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -2.5)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -2.5)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -2.5) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -2.5)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -2.5)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -2.5) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -2.5)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -2.5)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -2.5) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -2.5)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -2.5)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -2.5) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 10 AS n, 'e' AS col, '0.05' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.05)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.05)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.05) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.05)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.05)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.05) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.05)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.05)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.05) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.05)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.05)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.05) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.05)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.05)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.05) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.05)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.05)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.05) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 11 AS n, 'e' AS col, '3.4999' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 3.4999)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 3.4999)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 3.4999) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 3.4999)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 3.4999)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 3.4999) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 3.4999)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 3.4999)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 3.4999) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 3.4999)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 3.4999)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 3.4999) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 3.4999)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 3.4999)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 3.4999) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 3.4999)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 3.4999)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 3.4999) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 12 AS n, 'e' AS col, '0.0' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.0)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.0) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.0)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.0) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.0)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.0) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.0)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.0) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.0)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.0) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.0)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.0) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 13 AS n, 'e' AS col, '0' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 14 AS n, 'e' AS col, '1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 1) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 1) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 1) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 1) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 1) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 1) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 15 AS n, 'e' AS col, '-1' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -1)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -1) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -1)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -1) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -1)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -1) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -1)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -1) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -1)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -1) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -1)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -1) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 16 AS n, 'e' AS col, '2' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 2)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 2)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 2) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 2)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 2)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 2) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 2)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 2)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 2) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 2)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 2)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 2) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 2)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 2)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 2) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 2)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 2)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 2) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 17 AS n, 'e' AS col, '100' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 100)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 100)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 100) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 100)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 100)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 100) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 100)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 100)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 100) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 100)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 100)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 100) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 100)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 100)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 100) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 100)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 100)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 100) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 18 AS n, 'e' AS col, '0.5 + 0.25' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.5 + 0.25)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.5 + 0.25)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.5 + 0.25) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.5 + 0.25)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.5 + 0.25)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.5 + 0.25) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.5 + 0.25)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.5 + 0.25)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.5 + 0.25) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.5 + 0.25)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.5 + 0.25)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.5 + 0.25) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.5 + 0.25)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.5 + 0.25)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.5 + 0.25) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.5 + 0.25)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.5 + 0.25)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.5 + 0.25) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 19 AS n, 'e' AS col, '0.25 * 2' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 0.25 * 2)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 0.25 * 2)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 0.25 * 2) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 0.25 * 2)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 0.25 * 2)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 0.25 * 2) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 0.25 * 2)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 0.25 * 2)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 0.25 * 2) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 0.25 * 2)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 0.25 * 2)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 0.25 * 2) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 0.25 * 2)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 0.25 * 2)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 0.25 * 2) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 0.25 * 2)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 0.25 * 2)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 0.25 * 2) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 20 AS n, 'e' AS col, '5.' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 5.)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 5.)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 5.) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 5.)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 5.)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 5.) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 5.)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 5.)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 5.) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 5.)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 5.)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 5.) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 5.)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 5.)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 5.) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 5.)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 5.)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 5.) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 21 AS n, 'e' AS col, '9223372036854775808' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 9223372036854775808)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 9223372036854775808)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 9223372036854775808) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 9223372036854775808)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 9223372036854775808)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 9223372036854775808) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 9223372036854775808)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 9223372036854775808)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 9223372036854775808) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 9223372036854775808)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 9223372036854775808)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 9223372036854775808) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 9223372036854775808)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 9223372036854775808)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 9223372036854775808) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 9223372036854775808)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 9223372036854775808)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 9223372036854775808) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 22 AS n, 'e' AS col, '100000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 100000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 100000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 100000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 100000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 100000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 100000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 100000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 100000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 100000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 100000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 100000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 100000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 100000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 100000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 100000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 100000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 100000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 100000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 23 AS n, 'e' AS col, '10000000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 10000000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 10000000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 10000000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 10000000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 10000000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 10000000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 10000000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 10000000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 10000000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 10000000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 10000000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 10000000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 24 AS n, 'e' AS col, '-10000000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < -10000000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < -10000000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < -10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= -10000000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= -10000000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= -10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > -10000000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > -10000000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > -10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= -10000000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= -10000000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= -10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = -10000000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = -10000000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = -10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> -10000000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> -10000000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> -10000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 25 AS n, 'e' AS col, '100000000000000000000000000000000000000' AS lit,
    (SELECT count(*) FROM t WHERE TRY(e < 100000000000000000000000000000000000000)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e < 100000000000000000000000000000000000000)) AS lt_s, (SELECT count(*) FROM t WHERE TRY(e < 100000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM t WHERE TRY(e <= 100000000000000000000000000000000000000)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <= 100000000000000000000000000000000000000)) AS le_s, (SELECT count(*) FROM t WHERE TRY(e <= 100000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS le_e,
    (SELECT count(*) FROM t WHERE TRY(e > 100000000000000000000000000000000000000)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e > 100000000000000000000000000000000000000)) AS gt_s, (SELECT count(*) FROM t WHERE TRY(e > 100000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM t WHERE TRY(e >= 100000000000000000000000000000000000000)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e >= 100000000000000000000000000000000000000)) AS ge_s, (SELECT count(*) FROM t WHERE TRY(e >= 100000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM t WHERE TRY(e = 100000000000000000000000000000000000000)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e = 100000000000000000000000000000000000000)) AS eq_s, (SELECT count(*) FROM t WHERE TRY(e = 100000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM t WHERE TRY(e <> 100000000000000000000000000000000000000)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM t WHERE TRY(e <> 100000000000000000000000000000000000000)) AS ne_s, (SELECT count(*) FROM t WHERE TRY(e <> 100000000000000000000000000000000000000) IS NULL AND e IS NOT NULL) AS ne_e
) AS q ORDER BY n
) TO 'compare_e.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
