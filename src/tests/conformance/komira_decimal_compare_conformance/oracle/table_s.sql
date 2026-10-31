-- The tables of the DECIMAL-to-DOUBLE site tests, built by the pinned DuckDB.
-- pj: BIGINT rows (k, v) in groups whose sums run past 2^64 and 2^70 on both
-- sides of zero (group 7 sums to -(2^64) - 2^11 - 1 and group 10 to
-- -(2^70) - 2^17 - 1, the sums at which a one-rounding 128-bit to double
-- conversion differs from DuckDB's). pd: the same rows as DECIMAL(38, 0),
-- DECIMAL(38, 2) and DECIMAL(38, 10). pg: the per-group sums of pd's columns,
-- stored (one row per group).
CREATE TABLE pj AS
SELECT k::BIGINT AS k, v::BIGINT AS v FROM (
  SELECT k, CASE WHEN k % 2 = 0 THEN -1 ELSE 1 END * (hash(k * 1000 + i) >> 2)::BIGINT AS v
  FROM range(1, 7) AS a(k), range(0, 40) AS b(i)
  UNION ALL SELECT 7, -9223372036854775807 - 1
  UNION ALL SELECT 7, -9223372036854775807 - 1
  UNION ALL SELECT 7, -2049
  UNION ALL SELECT 8, 9223372036854775807
  UNION ALL SELECT 8, 9223372036854775807
  UNION ALL SELECT 8, 2050
  UNION ALL SELECT 9, -9223372036854775807 - 1
  UNION ALL SELECT 9, -1
  UNION ALL SELECT 10, -9223372036854775807 - 1 FROM range(128)
  UNION ALL SELECT 10, -131073
  UNION ALL SELECT 11, 9223372036854775807 FROM range(128)
  UNION ALL SELECT 11, 131073
  UNION ALL SELECT 12, -9223372036854775807 - 1
  UNION ALL SELECT 12, -9223372036854775807 - 1
  UNION ALL SELECT 12, -1
  UNION ALL SELECT 13, -9223372036854775807 - 1
  UNION ALL SELECT 13, -9223372036854775807 - 1
);
CREATE TABLE pd AS
SELECT k, v::DECIMAL(38, 0) AS d0, v::DECIMAL(38, 2) AS d2, v::DECIMAL(38, 10) AS d10 FROM pj;
CREATE TABLE pg AS
SELECT k, sum(d0) AS s0, sum(d2) AS s2, sum(d10) AS s10 FROM pd GROUP BY k;
