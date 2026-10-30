-- The table the oracles of the decimal compare tests read: `t`, built by the
-- pinned DuckDB. Nine nullable DECIMAL columns, each a permutation of the same
-- 249 values, in the steps its scale gives them:
--   a  DECIMAL(15, 2)   b  DECIMAL(18, 2) (the widest that fits an int64 unscaled
--   value)   c  DECIMAL(19, 2) (the narrowest that does not)
--   d  DECIMAL(38, 2)   e  DECIMAL(38, 0) (tenths of the values)   f  DECIMAL(38, 10)
--   (ten-billionths)   m  DECIMAL(30, 2)   g  DECIMAL(15, 0)   h  DECIMAL(15, 5)
-- The 249 values are, in hundredths: every step from -1.00 to 1.00 (the
-- neighbourhood of the 0.05 and 0.07 bounds, zero, and the sign change), 23.90
-- to 24.10 and its negative (the neighbourhood of 24), and 29.99, 30.00, 30.01
-- and their negatives; with NULLs on a fixed stride per column. Then extreme
-- rows: the column's largest and least values, one step inside them, and for c
-- the values at and just past the int64 limits of the unscaled integer
-- (92233720368547758.07 is 2^63 - 1 hundredths). The wide columns d, e and f
-- hold small values only: DuckDB compares a DECIMAL(38, s) column with a literal of
-- more scale by widening the column to DECIMAL(38, scale of the literal), which
-- raises when a stored value does not fit, so the rows that provoke that are in
-- `tx` (table_x.sql), where a column that raises is a column of its own.

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
            ELSE CAST(CAST(z.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(19, 2)) END AS c,
       CASE WHEN (x.i + 1) % 23 = 0 THEN NULL
            ELSE CAST(CAST(u.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(38, 2)) END AS d,
       CASE WHEN (x.i + 1) % 29 = 0 THEN NULL
            ELSE CAST(v.k // 10 AS DECIMAL(38, 0)) END AS e,
       CASE WHEN (x.i + 1) % 31 = 0 THEN NULL
            ELSE CAST(CAST(w.k AS DECIMAL(19, 0)) * 0.0000000001 AS DECIMAL(38, 10)) END AS f,
       CASE WHEN (x.i + 1) % 37 = 0 THEN NULL
            ELSE CAST(CAST(q.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(30, 2)) END AS m,
       CASE WHEN (x.i + 1) % 41 = 0 THEN NULL
            ELSE CAST(s.k // 10 AS DECIMAL(15, 0)) END AS g,
       CASE WHEN (x.i + 1) % 43 = 0 THEN NULL
            ELSE CAST(CAST(r.k AS DECIMAL(19, 0)) * 0.01 AS DECIMAL(15, 5)) END AS h
FROM ks AS x
JOIN ks AS y ON y.i = (x.i * 7) % 249
JOIN ks AS z ON z.i = (x.i * 11) % 249
JOIN ks AS u ON u.i = (x.i * 13) % 249
JOIN ks AS v ON v.i = (x.i * 17) % 249
JOIN ks AS w ON w.i = (x.i * 19) % 249
JOIN ks AS q ON q.i = (x.i * 23) % 249
JOIN ks AS s ON s.i = (x.i * 29) % 249
JOIN ks AS r ON r.i = (x.i * 31) % 249
UNION ALL
SELECT * FROM (VALUES
  (100001::BIGINT, 9999999999999.99::DECIMAL(15, 2), 9999999999999999.99::DECIMAL(18, 2), 99999999999999999.99::DECIMAL(19, 2), 99.99::DECIMAL(38, 2), 99::DECIMAL(38, 0), 0.0000009999::DECIMAL(38, 10), 1234567890123456789012345.67::DECIMAL(30, 2), 999999999999999::DECIMAL(15, 0), 9999999999.99999::DECIMAL(15, 5)),
  (100002::BIGINT, -9999999999999.99::DECIMAL(15, 2), -9999999999999999.99::DECIMAL(18, 2), -99999999999999999.99::DECIMAL(19, 2), -99.99::DECIMAL(38, 2), -99::DECIMAL(38, 0), -0.0000009999::DECIMAL(38, 10), -1234567890123456789012345.67::DECIMAL(30, 2), -999999999999999::DECIMAL(15, 0), -9999999999.99999::DECIMAL(15, 5)),
  (100003::BIGINT, 9999999999999.98::DECIMAL(15, 2), 9999999999999999.98::DECIMAL(18, 2), 99999999999999999.98::DECIMAL(19, 2), 99.98::DECIMAL(38, 2), 98::DECIMAL(38, 0), 0.0000009998::DECIMAL(38, 10), 1234567890123456789012345.66::DECIMAL(30, 2), 999999999999998::DECIMAL(15, 0), 9999999999.99998::DECIMAL(15, 5)),
  (100004::BIGINT, -9999999999999.98::DECIMAL(15, 2), -9999999999999999.98::DECIMAL(18, 2), -99999999999999999.98::DECIMAL(19, 2), -99.98::DECIMAL(38, 2), -98::DECIMAL(38, 0), -0.0000009998::DECIMAL(38, 10), -1234567890123456789012345.66::DECIMAL(30, 2), -999999999999998::DECIMAL(15, 0), -9999999999.99998::DECIMAL(15, 5)),
  (100005::BIGINT, 0.00::DECIMAL(15, 2), 0.00::DECIMAL(18, 2), 0.00::DECIMAL(19, 2), 0.00::DECIMAL(38, 2), 0::DECIMAL(38, 0), 0.0000000000::DECIMAL(38, 10), 0.00::DECIMAL(30, 2), 0::DECIMAL(15, 0), 0.00000::DECIMAL(15, 5)),
  (100006::BIGINT, 0.01::DECIMAL(15, 2), 0.01::DECIMAL(18, 2), 92233720368547758.07::DECIMAL(19, 2), 0.01::DECIMAL(38, 2), 1::DECIMAL(38, 0), 0.0000000001::DECIMAL(38, 10), 0.01::DECIMAL(30, 2), 1::DECIMAL(15, 0), 0.00001::DECIMAL(15, 5)),
  (100007::BIGINT, -0.01::DECIMAL(15, 2), -0.01::DECIMAL(18, 2), -92233720368547758.08::DECIMAL(19, 2), -0.01::DECIMAL(38, 2), -1::DECIMAL(38, 0), -0.0000000001::DECIMAL(38, 10), -0.01::DECIMAL(30, 2), -1::DECIMAL(15, 0), -0.00001::DECIMAL(15, 5)),
  (100008::BIGINT, 0.01::DECIMAL(15, 2), 0.01::DECIMAL(18, 2), 92233720368547758.08::DECIMAL(19, 2), 0.02::DECIMAL(38, 2), 1::DECIMAL(38, 0), 0.0000000002::DECIMAL(38, 10), 0.02::DECIMAL(30, 2), 1::DECIMAL(15, 0), 0.00002::DECIMAL(15, 5)),
  (100009::BIGINT, -0.01::DECIMAL(15, 2), -0.01::DECIMAL(18, 2), -92233720368547758.09::DECIMAL(19, 2), -0.02::DECIMAL(38, 2), -1::DECIMAL(38, 0), -0.0000000002::DECIMAL(38, 10), -0.02::DECIMAL(30, 2), -1::DECIMAL(15, 0), -0.00002::DECIMAL(15, 5)),
  (100010::BIGINT, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
) AS e(id, a, b, c, d, e, f, m, g, h);
