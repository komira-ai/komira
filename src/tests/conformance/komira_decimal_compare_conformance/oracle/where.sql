-- where.tsv: rows of t a WHERE text keeps, and the sum of their id. The text is the SQL
-- the test runs too.
COPY (
SELECT * FROM (
  SELECT 0 AS n, 'a between 0.06 - 0.01 and 0.06 + 0.01' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a between 0.06 - 0.01 and 0.06 + 0.01
  UNION ALL
  SELECT 1 AS n, 'a between 0.05 and 0.07' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a between 0.05 and 0.07
  UNION ALL
  SELECT 2 AS n, 'a between 0.055 and 0.065' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a between 0.055 and 0.065
  UNION ALL
  SELECT 3 AS n, 'a not between 0.055 and 0.065' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a not between 0.055 and 0.065
  UNION ALL
  SELECT 4 AS n, 'a >= 0.06 - 0.01 and a <= 0.06 + 0.01 and b < 24' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a >= 0.06 - 0.01 and a <= 0.06 + 0.01 and b < 24
  UNION ALL
  SELECT 5 AS n, 'a between 0.06 - 0.01 and 0.06 + 0.01 and b < 24 and c > -23.995' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a between 0.06 - 0.01 and 0.06 + 0.01 and b < 24 and c > -23.995
  UNION ALL
  SELECT 6 AS n, 'a between 0.06 - 0.01 and 0.06 + 0.01 and a < 24' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a between 0.06 - 0.01 and 0.06 + 0.01 and a < 24
  UNION ALL
  SELECT 7 AS n, 'b < 24 and c < 24.005' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE b < 24 and c < 24.005
  UNION ALL
  SELECT 8 AS n, 'a > 0.065 or b < -0.065' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a > 0.065 or b < -0.065
  UNION ALL
  SELECT 9 AS n, 'a = 0.065 or c = 0.07' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a = 0.065 or c = 0.07
  UNION ALL
  SELECT 10 AS n, 'not (a < 0.065)' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE not (a < 0.065)
  UNION ALL
  SELECT 11 AS n, 'not (a <= 0.065)' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE not (a <= 0.065)
  UNION ALL
  SELECT 12 AS n, 'not (a = 0.065)' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE not (a = 0.065)
  UNION ALL
  SELECT 13 AS n, '0.065 >= a' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE 0.065 >= a
  UNION ALL
  SELECT 14 AS n, '0.06 - 0.01 <= a and a <= 0.06 + 0.01' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE 0.06 - 0.01 <= a and a <= 0.06 + 0.01
  UNION ALL
  SELECT 15 AS n, '24 > b' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE 24 > b
  UNION ALL
  SELECT 16 AS n, 'a is null' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a is null
  UNION ALL
  SELECT 17 AS n, 'a is not null and a < 0.065' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a is not null and a < 0.065
  UNION ALL
  SELECT 18 AS n, 'a != 0.06' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a != 0.06
  UNION ALL
  SELECT 19 AS n, 'a < 0.06 + 0.005' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a < 0.06 + 0.005
  UNION ALL
  SELECT 20 AS n, 'a >= 0.06 - 0.005' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a >= 0.06 - 0.005
  UNION ALL
  SELECT 21 AS n, 'a = 0.06 + 0.005' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a = 0.06 + 0.005
  UNION ALL
  SELECT 22 AS n, 'b between -0.065 and -0.055' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE b between -0.065 and -0.055
  UNION ALL
  SELECT 23 AS n, 'c between 92233720368547758.07 and 92233720368547758.08' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE c between 92233720368547758.07 and 92233720368547758.08
  UNION ALL
  SELECT 24 AS n, 'c = 92233720368547758.075' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE c = 92233720368547758.075
  UNION ALL
  SELECT 25 AS n, 'a > - -0.5' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a > - -0.5
  UNION ALL
  SELECT 26 AS n, 'a > +0.5' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a > +0.5
  UNION ALL
  SELECT 27 AS n, 'a < - +0.5' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a < - +0.5
  UNION ALL
  SELECT 28 AS n, 'a < -(-0.5)' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a < -(-0.5)
  UNION ALL
  SELECT 29 AS n, '5. > a' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE 5. > a
  UNION ALL
  SELECT 30 AS n, '.5 > a' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE .5 > a
  UNION ALL
  SELECT 31 AS n, 'd < 0.065 and e >= 0.5' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE d < 0.065 and e >= 0.5
  UNION ALL
  SELECT 32 AS n, 'h >= 0.06 - 0.01 and h <= 0.06 + 0.01 and g < 24' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE h >= 0.06 - 0.01 and h <= 0.06 + 0.01 and g < 24
  UNION ALL
  SELECT 33 AS n, 'f > 0.00000000005 or m <= -0.055' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE f > 0.00000000005 or m <= -0.055
  UNION ALL
  SELECT 34 AS n, 'd between -0.065 and 99999999999999999999999999999999999' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE d between -0.065 and 99999999999999999999999999999999999
  UNION ALL
  SELECT 35 AS n, 'd not between 0.055 and 1000000000000000000000000000000000' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE d not between 0.055 and 1000000000000000000000000000000000
  UNION ALL
  SELECT 36 AS n, 'a < NULL' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a < NULL
  UNION ALL
  SELECT 37 AS n, 'a is null or a < NULL' AS pred, count(*) AS rows_kept, CAST(coalesce(sum(id), 0) AS BIGINT) AS id_sum FROM t WHERE a is null or a < NULL
) AS q ORDER BY n
) TO 'where.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
