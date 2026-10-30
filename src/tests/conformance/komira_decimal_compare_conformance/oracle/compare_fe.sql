-- compare_fe.tsv: for each literal, how many rows of tf `fe <op> <literal>` keeps, the
-- sum of their id, and how many rows DuckDB cannot decide (the comparison raises a
-- conversion error: TRY gives NULL for a row whose fe is not NULL), for each of the six
-- comparison operators. The literal is the SQL text the test runs too (a folded bound is
-- written as the arithmetic), so the file holds DuckDB's reading of it. NULL rows are in
-- neither the kept rows nor their complement. Column fe of tf holds values near 2^53 unscaled and wide ones; the literals are DOUBLE.
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'fe' AS col, '90071992547409.9375 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 90071992547409.9375 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 90071992547409.9375 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 90071992547409.9375 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 90071992547409.9375 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 90071992547409.9375 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 90071992547409.9375 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 90071992547409.9375 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 90071992547409.9375 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 90071992547409.9375 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 90071992547409.9375 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 90071992547409.9375 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 90071992547409.9375 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 90071992547409.9375 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 90071992547409.9375 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 90071992547409.9375 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 90071992547409.9375 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 90071992547409.9375 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 90071992547409.9375 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 1 AS n, 'fe' AS col, '90071992547409.93 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 90071992547409.93 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 90071992547409.93 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 90071992547409.93 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 90071992547409.93 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 90071992547409.93 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 90071992547409.93 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 90071992547409.93 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 90071992547409.93 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 90071992547409.93 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 90071992547409.93 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 90071992547409.93 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 90071992547409.93 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 90071992547409.93 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 90071992547409.93 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 90071992547409.93 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 90071992547409.93 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 90071992547409.93 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 90071992547409.93 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 2 AS n, 'fe' AS col, '90071992547409.92 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 90071992547409.92 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 90071992547409.92 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 90071992547409.92 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 90071992547409.92 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 90071992547409.92 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 90071992547409.92 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 90071992547409.92 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 90071992547409.92 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 90071992547409.92 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 90071992547409.92 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 90071992547409.92 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 90071992547409.92 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 90071992547409.92 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 90071992547409.92 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 90071992547409.92 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 90071992547409.92 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 90071992547409.92 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 90071992547409.92 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 3 AS n, 'fe' AS col, '9007199254740993 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 9007199254740993 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 9007199254740993 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 9007199254740993 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 9007199254740993 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 9007199254740993 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 9007199254740993 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 9007199254740993 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 9007199254740993 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 9007199254740993 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 9007199254740993 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 9007199254740993 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 9007199254740993 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 9007199254740993 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 9007199254740993 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 9007199254740993 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 9007199254740993 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 9007199254740993 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 9007199254740993 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 4 AS n, 'fe' AS col, '9007199254740992 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 9007199254740992 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 9007199254740992 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 9007199254740992 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 9007199254740992 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 9007199254740992 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 9007199254740992 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 9007199254740992 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 9007199254740992 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 9007199254740992 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 9007199254740992 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 9007199254740992 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 9007199254740992 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 9007199254740992 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 9007199254740992 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 9007199254740992 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 9007199254740992 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 9007199254740992 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 9007199254740992 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 5 AS n, 'fe' AS col, '0.3 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 0.3 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 0.3 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 0.3 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 0.3 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 0.3 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 0.3 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 0.3 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 0.3 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 0.3 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 0.3 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 0.3 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 0.3 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 0.3 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 0.3 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 0.3 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 0.3 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 0.3 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 0.3 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 6 AS n, 'fe' AS col, '3e-1' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 3e-1)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 3e-1)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 3e-1) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 3e-1)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 3e-1)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 3e-1) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 3e-1)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 3e-1)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 3e-1) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 3e-1)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 3e-1)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 3e-1) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 3e-1)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 3e-1)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 3e-1) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 3e-1)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 3e-1)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 3e-1) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 7 AS n, 'fe' AS col, '1.5e-2' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 1.5e-2)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 1.5e-2)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 1.5e-2) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 1.5e-2)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 1.5e-2)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 1.5e-2) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 1.5e-2)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 1.5e-2)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 1.5e-2) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 1.5e-2)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 1.5e-2)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 1.5e-2) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 1.5e-2)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 1.5e-2)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 1.5e-2) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 1.5e-2)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 1.5e-2)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 1.5e-2) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 8 AS n, 'fe' AS col, '1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 9 AS n, 'fe' AS col, '0.30000000000000004 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 0.30000000000000004 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 0.30000000000000004 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 0.30000000000000004 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 0.30000000000000004 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 0.30000000000000004 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 0.30000000000000004 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 0.30000000000000004 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 0.30000000000000004 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 0.30000000000000004 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 0.30000000000000004 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 0.30000000000000004 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 0.30000000000000004 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 0.30000000000000004 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 0.30000000000000004 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 0.30000000000000004 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 0.30000000000000004 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 0.30000000000000004 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 0.30000000000000004 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 10 AS n, 'fe' AS col, '12345678901234567890.5 * 1e0' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 12345678901234567890.5 * 1e0)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 12345678901234567890.5 * 1e0)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 12345678901234567890.5 * 1e0) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 12345678901234567890.5 * 1e0)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 12345678901234567890.5 * 1e0)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 12345678901234567890.5 * 1e0) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 12345678901234567890.5 * 1e0)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 12345678901234567890.5 * 1e0)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 12345678901234567890.5 * 1e0) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 12345678901234567890.5 * 1e0)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 12345678901234567890.5 * 1e0)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 12345678901234567890.5 * 1e0) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 12345678901234567890.5 * 1e0)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 12345678901234567890.5 * 1e0)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 12345678901234567890.5 * 1e0) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 12345678901234567890.5 * 1e0)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 12345678901234567890.5 * 1e0)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 12345678901234567890.5 * 1e0) IS NULL AND fe IS NOT NULL) AS ne_e
  UNION ALL
  SELECT 11 AS n, 'fe' AS col, '1e30' AS lit,
    (SELECT count(*) FROM tf WHERE TRY(fe < 1e30)) AS lt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe < 1e30)) AS lt_s, (SELECT count(*) FROM tf WHERE TRY(fe < 1e30) IS NULL AND fe IS NOT NULL) AS lt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <= 1e30)) AS le_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <= 1e30)) AS le_s, (SELECT count(*) FROM tf WHERE TRY(fe <= 1e30) IS NULL AND fe IS NOT NULL) AS le_e,
    (SELECT count(*) FROM tf WHERE TRY(fe > 1e30)) AS gt_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe > 1e30)) AS gt_s, (SELECT count(*) FROM tf WHERE TRY(fe > 1e30) IS NULL AND fe IS NOT NULL) AS gt_e,
    (SELECT count(*) FROM tf WHERE TRY(fe >= 1e30)) AS ge_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe >= 1e30)) AS ge_s, (SELECT count(*) FROM tf WHERE TRY(fe >= 1e30) IS NULL AND fe IS NOT NULL) AS ge_e,
    (SELECT count(*) FROM tf WHERE TRY(fe = 1e30)) AS eq_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe = 1e30)) AS eq_s, (SELECT count(*) FROM tf WHERE TRY(fe = 1e30) IS NULL AND fe IS NOT NULL) AS eq_e,
    (SELECT count(*) FROM tf WHERE TRY(fe <> 1e30)) AS ne_n, (SELECT CAST(coalesce(sum(id), 0) AS BIGINT) FROM tf WHERE TRY(fe <> 1e30)) AS ne_s, (SELECT count(*) FROM tf WHERE TRY(fe <> 1e30) IS NULL AND fe IS NOT NULL) AS ne_e
) AS q ORDER BY n
) TO 'compare_fe.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
