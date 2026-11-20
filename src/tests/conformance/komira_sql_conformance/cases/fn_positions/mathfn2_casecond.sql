-- order: rows
-- pow(n, 2) in a case condition
SELECT k, CASE WHEN pow(n, 2) > 4.0 THEN 'y' ELSE 'n' END AS z FROM T
