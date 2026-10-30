-- The table every oracle of the decimal compare tests reads: `t`, built by the
-- pinned DuckDB. Three nullable DECIMAL columns of scale 2: a is
-- DECIMAL(15, 2), b is DECIMAL(18, 2) (the widest that fits an int64 unscaled
-- value) and c is DECIMAL(19, 2) (the narrowest that does not).
--
-- Each column is a permutation of the same 249 values, in hundredths: every
-- step from -1.00 to 1.00 (the neighbourhood of the 0.05 and 0.07 bounds, zero,
-- and the sign change), 23.90 to 24.10 and its negative (the neighbourhood of
-- 24), and 29.99, 30.00, 30.01 and their negatives; with NULLs on a fixed
-- stride. Then extreme rows: the column's largest and least values, one step
-- inside them, and for c the values at and just past the int64 limits of the
-- unscaled integer (92233720368547758.07 is 2^63 - 1 hundredths).

CREATE TABLE ks AS
SELECT CAST(row_number() OVER (ORDER BY k) - 1 AS BIGINT) AS i, k
FROM (
  SELECT unnest(range(-100, 101)) AS k
  UNION ALL SELECT unnest(range(2390, 2411))
  UNION ALL SELECT unnest(range(-2410, -2389))
  UNION ALL SELECT unnest([2999, 3000, 3001, -2999, -3000, -3001])
) AS v;

CREATE TABLE t AS
SELECT x.i + 1 AS id,
       CASE WHEN (x.i + 1) % 13 = 0 THEN NULL
            ELSE CAST(CAST(x.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(15, 2)) END AS a,
       CASE WHEN (x.i + 1) % 17 = 0 THEN NULL
            ELSE CAST(CAST(y.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(18, 2)) END AS b,
       CASE WHEN (x.i + 1) % 19 = 0 THEN NULL
            ELSE CAST(CAST(z.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(19, 2)) END AS c
FROM ks AS x
JOIN ks AS y ON y.i = (x.i * 7) % 249
JOIN ks AS z ON z.i = (x.i * 11) % 249
UNION ALL
SELECT * FROM (VALUES
  (100001::BIGINT, 9999999999999.99::DECIMAL(15, 2), 9999999999999999.99::DECIMAL(18, 2), 99999999999999999.99::DECIMAL(19, 2)),
  (100002::BIGINT, -9999999999999.99::DECIMAL(15, 2), -9999999999999999.99::DECIMAL(18, 2), -99999999999999999.99::DECIMAL(19, 2)),
  (100003::BIGINT, 9999999999999.98::DECIMAL(15, 2), 9999999999999999.98::DECIMAL(18, 2), 99999999999999999.98::DECIMAL(19, 2)),
  (100004::BIGINT, -9999999999999.98::DECIMAL(15, 2), -9999999999999999.98::DECIMAL(18, 2), -99999999999999999.98::DECIMAL(19, 2)),
  (100005::BIGINT, 0.00::DECIMAL(15, 2), 0.00::DECIMAL(18, 2), 0.00::DECIMAL(19, 2)),
  (100006::BIGINT, 0.01::DECIMAL(15, 2), 0.01::DECIMAL(18, 2), 92233720368547758.07::DECIMAL(19, 2)),
  (100007::BIGINT, -0.01::DECIMAL(15, 2), -0.01::DECIMAL(18, 2), -92233720368547758.08::DECIMAL(19, 2)),
  (100008::BIGINT, 0.01::DECIMAL(15, 2), 0.01::DECIMAL(18, 2), 92233720368547758.08::DECIMAL(19, 2)),
  (100009::BIGINT, -0.01::DECIMAL(15, 2), -0.01::DECIMAL(18, 2), -92233720368547758.09::DECIMAL(19, 2)),
  (100010::BIGINT, NULL, NULL, NULL)
) AS e(id, a, b, c);
