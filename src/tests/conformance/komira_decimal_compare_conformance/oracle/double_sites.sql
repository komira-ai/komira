-- double_sites.tsv: DuckDB's DOUBLE for each query of the site tests (one row per group):
-- the query's name, its text, the group k and the answer printed (shortest text that reads
-- back exactly). Each query reaches one of the engine's DECIMAL-to-DOUBLE conversions:
-- a cast, a promotion beside a DOUBLE operand, a math function, AVG, and a sum() of an
-- integer column (DECIMAL(38, 0) here) in each of those. The engine's AVG over a DECIMAL is the
-- DOUBLE of the exact sum divided by the count, so the avg_* rows are DuckDB's
-- CAST(sum(col) AS DOUBLE) / count(*), not DuckDB's own avg(): that one divides in
-- extended precision and answers the last digit differently for sums past 2^64.
COPY (
SELECT name, query, k, x::VARCHAR AS dbl FROM (
  SELECT 0 AS n, 'sum_times_double' AS name, 'select k, sum(v) * 1e0 as x from pj group by k' AS query, k, x FROM (select k, sum(v) * 1e0 as x from pj group by k)
  UNION ALL
  SELECT 1 AS n, 'sum_over_double' AS name, 'select k, sum(v) / 1e0 as x from pj group by k' AS query, k, x FROM (select k, sum(v) / 1e0 as x from pj group by k)
  UNION ALL
  SELECT 2 AS n, 'sum_plus_double' AS name, 'select k, sum(v) + 0.5e0 as x from pj group by k' AS query, k, x FROM (select k, sum(v) + 0.5e0 as x from pj group by k)
  UNION ALL
  SELECT 3 AS n, 'sum_over_int' AS name, 'select k, sum(v) / 3 as x from pj group by k' AS query, k, x FROM (select k, sum(v) / 3 as x from pj group by k)
  UNION ALL
  SELECT 4 AS n, 'sum_over_count' AS name, 'select k, sum(v) / count(*) as x from pj group by k' AS query, k, x FROM (select k, sum(v) / count(*) as x from pj group by k)
  UNION ALL
  SELECT 5 AS n, 'sum_math' AS name, 'select k, cbrt(sum(v)) as x from pj group by k' AS query, k, x FROM (select k, cbrt(sum(v)) as x from pj group by k)
  UNION ALL
  SELECT 6 AS n, 'cast_s0' AS name, 'select k, cast(s0 as double) as x from pg' AS query, k, x FROM (select k, cast(s0 as double) as x from pg)
  UNION ALL
  SELECT 7 AS n, 'cast_s2' AS name, 'select k, cast(s2 as double) as x from pg' AS query, k, x FROM (select k, cast(s2 as double) as x from pg)
  UNION ALL
  SELECT 8 AS n, 'cast_s10' AS name, 'select k, cast(s10 as double) as x from pg' AS query, k, x FROM (select k, cast(s10 as double) as x from pg)
  UNION ALL
  SELECT 9 AS n, 'column_times_double' AS name, 'select k, s2 * 1e0 as x from pg' AS query, k, x FROM (select k, s2 * 1e0 as x from pg)
  UNION ALL
  SELECT 10 AS n, 'column_plus_double' AS name, 'select k, s10 + 0.5e0 as x from pg' AS query, k, x FROM (select k, s10 + 0.5e0 as x from pg)
  UNION ALL
  SELECT 11 AS n, 'column_math' AS name, 'select k, cbrt(s2) as x from pg' AS query, k, x FROM (select k, cbrt(s2) as x from pg)
  UNION ALL
  SELECT 12 AS n, 'avg_d0' AS name, 'select k, avg(d0) as x from pd group by k' AS query, k, x FROM (select k, cast(sum(d0) as double) / count(*) as x from pd group by k)
  UNION ALL
  SELECT 13 AS n, 'avg_d2' AS name, 'select k, avg(d2) as x from pd group by k' AS query, k, x FROM (select k, cast(sum(d2) as double) / count(*) as x from pd group by k)
  UNION ALL
  SELECT 14 AS n, 'avg_d10' AS name, 'select k, avg(d10) as x from pd group by k' AS query, k, x FROM (select k, cast(sum(d10) as double) / count(*) as x from pd group by k)
) AS q ORDER BY n, k
) TO 'double_sites.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
