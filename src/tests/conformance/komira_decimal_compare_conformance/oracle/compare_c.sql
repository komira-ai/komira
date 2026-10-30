-- compare_c.tsv: for each literal, how many rows of t `c <op> <literal>` keeps, and the
-- sum of their id, for each of the six comparison operators. The literal is the SQL text
-- the test runs too (a folded bound is written as the arithmetic), so the file holds
-- DuckDB's reading of it. NULL rows are in neither the kept rows nor their complement.
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'c' AS col, '0.06' AS lit,
    count(*) FILTER (WHERE c < 0.06) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.06), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.06) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.06), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.06) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.06), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.06) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.06), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.06) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.06), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.06) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.06), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 1 AS n, 'c' AS col, '0.05' AS lit,
    count(*) FILTER (WHERE c < 0.05) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.05), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.05) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.05), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.05) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.05), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.05) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.05), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.05) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.05), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.05) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.05), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 2 AS n, 'c' AS col, '0.07' AS lit,
    count(*) FILTER (WHERE c < 0.07) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.07), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.07) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.07), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.07) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.07), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.07) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.07), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.07) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.07), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.07) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.07), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 3 AS n, 'c' AS col, '0.065' AS lit,
    count(*) FILTER (WHERE c < 0.065) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.065), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.065) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.065), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.065) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.065), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.065) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.065), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.065) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.065), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.065) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.065), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 4 AS n, 'c' AS col, '0.055' AS lit,
    count(*) FILTER (WHERE c < 0.055) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.055), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.055) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.055), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.055) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.055), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.055) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.055), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.055) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.055), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.055) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.055), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 5 AS n, 'c' AS col, '0.075' AS lit,
    count(*) FILTER (WHERE c < 0.075) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.075), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.075) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.075), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.075) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.075), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.075) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.075), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.075) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.075), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.075) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.075), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 6 AS n, 'c' AS col, '0.0649' AS lit,
    count(*) FILTER (WHERE c < 0.0649) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.0649), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.0649) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.0649), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.0649) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.0649), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.0649) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.0649), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.0649) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.0649), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.0649) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.0649), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 7 AS n, 'c' AS col, '0.0651' AS lit,
    count(*) FILTER (WHERE c < 0.0651) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.0651), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.0651) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.0651), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.0651) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.0651), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.0651) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.0651), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.0651) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.0651), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.0651) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.0651), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 8 AS n, 'c' AS col, '0.0000001' AS lit,
    count(*) FILTER (WHERE c < 0.0000001) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.0000001), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.0000001) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.0000001), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.0000001) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.0000001), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.0000001) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.0000001), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.0000001) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.0000001), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.0000001) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.0000001), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 9 AS n, 'c' AS col, '-0.0000001' AS lit,
    count(*) FILTER (WHERE c < -0.0000001) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -0.0000001), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -0.0000001) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -0.0000001), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -0.0000001) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -0.0000001), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -0.0000001) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -0.0000001), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -0.0000001) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -0.0000001), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -0.0000001) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -0.0000001), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 10 AS n, 'c' AS col, '0' AS lit,
    count(*) FILTER (WHERE c < 0) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 11 AS n, 'c' AS col, '1' AS lit,
    count(*) FILTER (WHERE c < 1) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 1), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 1) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 1), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 1) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 1), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 1) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 1), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 1) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 1), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 1) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 1), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 12 AS n, 'c' AS col, '-1' AS lit,
    count(*) FILTER (WHERE c < -1) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -1), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -1) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -1), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -1) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -1), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -1) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -1), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -1) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -1), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -1) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -1), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 13 AS n, 'c' AS col, '24' AS lit,
    count(*) FILTER (WHERE c < 24) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 24), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 24) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 24), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 24) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 24), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 24) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 24), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 24) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 24), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 24) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 24), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 14 AS n, 'c' AS col, '23.995' AS lit,
    count(*) FILTER (WHERE c < 23.995) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 23.995), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 23.995) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 23.995), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 23.995) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 23.995), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 23.995) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 23.995), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 23.995) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 23.995), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 23.995) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 23.995), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 15 AS n, 'c' AS col, '24.005' AS lit,
    count(*) FILTER (WHERE c < 24.005) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 24.005), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 24.005) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 24.005), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 24.005) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 24.005), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 24.005) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 24.005), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 24.005) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 24.005), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 24.005) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 24.005), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 16 AS n, 'c' AS col, '24.00' AS lit,
    count(*) FILTER (WHERE c < 24.00) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 24.00), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 24.00) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 24.00), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 24.00) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 24.00), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 24.00) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 24.00), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 24.00) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 24.00), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 24.00) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 24.00), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 17 AS n, 'c' AS col, '-0.065' AS lit,
    count(*) FILTER (WHERE c < -0.065) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -0.065), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -0.065) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -0.065), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -0.065) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -0.065), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -0.065) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -0.065), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -0.065) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -0.065), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -0.065) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -0.065), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 18 AS n, 'c' AS col, '-0.05' AS lit,
    count(*) FILTER (WHERE c < -0.05) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -0.05), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -0.05) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -0.05), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -0.05) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -0.05), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -0.05) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -0.05), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -0.05) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -0.05), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -0.05) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -0.05), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 19 AS n, 'c' AS col, '-24' AS lit,
    count(*) FILTER (WHERE c < -24) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -24), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -24) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -24), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -24) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -24), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -24) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -24), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -24) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -24), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -24) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -24), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 20 AS n, 'c' AS col, '-23.995' AS lit,
    count(*) FILTER (WHERE c < -23.995) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -23.995), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -23.995) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -23.995), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -23.995) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -23.995), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -23.995) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -23.995), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -23.995) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -23.995), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -23.995) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -23.995), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 21 AS n, 'c' AS col, '0.06 - 0.01' AS lit,
    count(*) FILTER (WHERE c < 0.06 - 0.01) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.06 - 0.01), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.06 - 0.01) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.06 - 0.01), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.06 - 0.01) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.06 - 0.01), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.06 - 0.01) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.06 - 0.01), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.06 - 0.01) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.06 - 0.01), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.06 - 0.01) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.06 - 0.01), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 22 AS n, 'c' AS col, '0.06 + 0.01' AS lit,
    count(*) FILTER (WHERE c < 0.06 + 0.01) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.06 + 0.01), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.06 + 0.01) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.06 + 0.01), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.06 + 0.01) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.06 + 0.01), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.06 + 0.01) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.06 + 0.01), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.06 + 0.01) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.06 + 0.01), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.06 + 0.01) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.06 + 0.01), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 23 AS n, 'c' AS col, '1 - 0.94' AS lit,
    count(*) FILTER (WHERE c < 1 - 0.94) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 1 - 0.94), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 1 - 0.94) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 1 - 0.94), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 1 - 0.94) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 1 - 0.94), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 1 - 0.94) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 1 - 0.94), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 1 - 0.94) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 1 - 0.94), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 1 - 0.94) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 1 - 0.94), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 24 AS n, 'c' AS col, '0.1 * 0.1 * 0.1' AS lit,
    count(*) FILTER (WHERE c < 0.1 * 0.1 * 0.1) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 0.1 * 0.1 * 0.1), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 0.1 * 0.1 * 0.1) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 0.1 * 0.1 * 0.1), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 0.1 * 0.1 * 0.1) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 0.1 * 0.1 * 0.1), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 0.1 * 0.1 * 0.1) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 0.1 * 0.1 * 0.1), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 0.1 * 0.1 * 0.1) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 0.1 * 0.1 * 0.1), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 0.1 * 0.1 * 0.1) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 0.1 * 0.1 * 0.1), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 25 AS n, 'c' AS col, '-0.06 + 0.01' AS lit,
    count(*) FILTER (WHERE c < -0.06 + 0.01) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -0.06 + 0.01), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -0.06 + 0.01) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -0.06 + 0.01), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -0.06 + 0.01) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -0.06 + 0.01), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -0.06 + 0.01) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -0.06 + 0.01), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -0.06 + 0.01) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -0.06 + 0.01), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -0.06 + 0.01) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -0.06 + 0.01), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 26 AS n, 'c' AS col, '100' AS lit,
    count(*) FILTER (WHERE c < 100) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 100), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 100) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 100), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 100) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 100), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 100) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 100), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 100) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 100), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 100) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 100), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 27 AS n, 'c' AS col, '99999999999999999.99' AS lit,
    count(*) FILTER (WHERE c < 99999999999999999.99) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 99999999999999999.99), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 99999999999999999.99) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 99999999999999999.99), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 99999999999999999.99) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 99999999999999999.99), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 99999999999999999.99) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 99999999999999999.99), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 99999999999999999.99) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 99999999999999999.99), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 99999999999999999.99) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 99999999999999999.99), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 28 AS n, 'c' AS col, '99999999999999999.995' AS lit,
    count(*) FILTER (WHERE c < 99999999999999999.995) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 99999999999999999.995), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 99999999999999999.995) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 99999999999999999.995), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 99999999999999999.995) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 99999999999999999.995), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 99999999999999999.995) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 99999999999999999.995), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 99999999999999999.995) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 99999999999999999.995), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 99999999999999999.995) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 99999999999999999.995), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 29 AS n, 'c' AS col, '-99999999999999999.995' AS lit,
    count(*) FILTER (WHERE c < -99999999999999999.995) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -99999999999999999.995), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -99999999999999999.995) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -99999999999999999.995), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -99999999999999999.995) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -99999999999999999.995), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -99999999999999999.995) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -99999999999999999.995), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -99999999999999999.995) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -99999999999999999.995), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -99999999999999999.995) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -99999999999999999.995), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 30 AS n, 'c' AS col, '92233720368547758.07' AS lit,
    count(*) FILTER (WHERE c < 92233720368547758.07) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 92233720368547758.07), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 92233720368547758.07) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 92233720368547758.07), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 92233720368547758.07) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 92233720368547758.07), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 92233720368547758.07) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 92233720368547758.07), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 92233720368547758.07) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 92233720368547758.07), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 92233720368547758.07) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 92233720368547758.07), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 31 AS n, 'c' AS col, '92233720368547758.075' AS lit,
    count(*) FILTER (WHERE c < 92233720368547758.075) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 92233720368547758.075), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 92233720368547758.075) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 92233720368547758.075), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 92233720368547758.075) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 92233720368547758.075), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 92233720368547758.075) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 92233720368547758.075), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 92233720368547758.075) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 92233720368547758.075), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 92233720368547758.075) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 92233720368547758.075), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 32 AS n, 'c' AS col, '92233720368547758.08' AS lit,
    count(*) FILTER (WHERE c < 92233720368547758.08) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 92233720368547758.08), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 92233720368547758.08) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 92233720368547758.08), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 92233720368547758.08) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 92233720368547758.08), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 92233720368547758.08) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 92233720368547758.08), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 92233720368547758.08) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 92233720368547758.08), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 92233720368547758.08) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 92233720368547758.08), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 33 AS n, 'c' AS col, '-92233720368547758.085' AS lit,
    count(*) FILTER (WHERE c < -92233720368547758.085) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < -92233720368547758.085), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= -92233720368547758.085) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= -92233720368547758.085), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > -92233720368547758.085) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > -92233720368547758.085), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= -92233720368547758.085) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= -92233720368547758.085), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = -92233720368547758.085) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = -92233720368547758.085), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> -92233720368547758.085) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> -92233720368547758.085), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 34 AS n, 'c' AS col, '9223372036854775807' AS lit,
    count(*) FILTER (WHERE c < 9223372036854775807) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 9223372036854775807), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 9223372036854775807) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 9223372036854775807), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 9223372036854775807) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 9223372036854775807), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 9223372036854775807) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 9223372036854775807), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 9223372036854775807) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 9223372036854775807), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 9223372036854775807) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 9223372036854775807), 0) AS BIGINT) AS ne_s
  FROM t
  UNION ALL
  SELECT 35 AS n, 'c' AS col, '9223372036854775808' AS lit,
    count(*) FILTER (WHERE c < 9223372036854775808) AS lt_n, CAST(coalesce(sum(id) FILTER (WHERE c < 9223372036854775808), 0) AS BIGINT) AS lt_s,
    count(*) FILTER (WHERE c <= 9223372036854775808) AS le_n, CAST(coalesce(sum(id) FILTER (WHERE c <= 9223372036854775808), 0) AS BIGINT) AS le_s,
    count(*) FILTER (WHERE c > 9223372036854775808) AS gt_n, CAST(coalesce(sum(id) FILTER (WHERE c > 9223372036854775808), 0) AS BIGINT) AS gt_s,
    count(*) FILTER (WHERE c >= 9223372036854775808) AS ge_n, CAST(coalesce(sum(id) FILTER (WHERE c >= 9223372036854775808), 0) AS BIGINT) AS ge_s,
    count(*) FILTER (WHERE c = 9223372036854775808) AS eq_n, CAST(coalesce(sum(id) FILTER (WHERE c = 9223372036854775808), 0) AS BIGINT) AS eq_s,
    count(*) FILTER (WHERE c <> 9223372036854775808) AS ne_n, CAST(coalesce(sum(id) FILTER (WHERE c <> 9223372036854775808), 0) AS BIGINT) AS ne_s
  FROM t
) AS q ORDER BY n
) TO 'compare_c.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
