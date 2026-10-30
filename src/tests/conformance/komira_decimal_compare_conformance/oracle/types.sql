-- types.tsv: DuckDB's type and value for each constant expression a comparison folds.
COPY (
SELECT * FROM (
  SELECT 0 AS n, '0.06' AS expr, typeof(0.06) AS type, CAST(0.06 AS VARCHAR) AS value
  UNION ALL
  SELECT 1 AS n, '0.060' AS expr, typeof(0.060) AS type, CAST(0.060 AS VARCHAR) AS value
  UNION ALL
  SELECT 2 AS n, '1.5' AS expr, typeof(1.5) AS type, CAST(1.5 AS VARCHAR) AS value
  UNION ALL
  SELECT 3 AS n, '0.0' AS expr, typeof(0.0) AS type, CAST(0.0 AS VARCHAR) AS value
  UNION ALL
  SELECT 4 AS n, '100.00' AS expr, typeof(100.00) AS type, CAST(100.00 AS VARCHAR) AS value
  UNION ALL
  SELECT 5 AS n, '0.06 - 0.01' AS expr, typeof(0.06 - 0.01) AS type, CAST(0.06 - 0.01 AS VARCHAR) AS value
  UNION ALL
  SELECT 6 AS n, '0.06 + 0.01' AS expr, typeof(0.06 + 0.01) AS type, CAST(0.06 + 0.01 AS VARCHAR) AS value
  UNION ALL
  SELECT 7 AS n, '0.06 * 0.01' AS expr, typeof(0.06 * 0.01) AS type, CAST(0.06 * 0.01 AS VARCHAR) AS value
  UNION ALL
  SELECT 8 AS n, '0.5 * 0.1' AS expr, typeof(0.5 * 0.1) AS type, CAST(0.5 * 0.1 AS VARCHAR) AS value
  UNION ALL
  SELECT 9 AS n, '1 - 0.94' AS expr, typeof(1 - 0.94) AS type, CAST(1 - 0.94 AS VARCHAR) AS value
  UNION ALL
  SELECT 10 AS n, '2 * 0.025' AS expr, typeof(2 * 0.025) AS type, CAST(2 * 0.025 AS VARCHAR) AS value
  UNION ALL
  SELECT 11 AS n, '24 + 0.5' AS expr, typeof(24 + 0.5) AS type, CAST(24 + 0.5 AS VARCHAR) AS value
  UNION ALL
  SELECT 12 AS n, '0.1 * 0.1 * 0.1' AS expr, typeof(0.1 * 0.1 * 0.1) AS type, CAST(0.1 * 0.1 * 0.1 AS VARCHAR) AS value
  UNION ALL
  SELECT 13 AS n, '-0.06 + 0.01' AS expr, typeof(-0.06 + 0.01) AS type, CAST(-0.06 + 0.01 AS VARCHAR) AS value
  UNION ALL
  SELECT 14 AS n, '0.07 - 0.1' AS expr, typeof(0.07 - 0.1) AS type, CAST(0.07 - 0.1 AS VARCHAR) AS value
  UNION ALL
  SELECT 15 AS n, '99999999999999999.99 + 0.01' AS expr, typeof(99999999999999999.99 + 0.01) AS type, CAST(99999999999999999.99 + 0.01 AS VARCHAR) AS value
  UNION ALL
  SELECT 16 AS n, '1000000 * 0.5' AS expr, typeof(1000000 * 0.5) AS type, CAST(1000000 * 0.5 AS VARCHAR) AS value
  UNION ALL
  SELECT 17 AS n, '3000000000 * 0.5' AS expr, typeof(3000000000 * 0.5) AS type, CAST(3000000000 * 0.5 AS VARCHAR) AS value
) AS q ORDER BY n
) TO 'types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
