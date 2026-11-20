-- order: rows
-- sqrt(g) in a case condition
SELECT k, CASE WHEN sqrt(g) > 2.0 THEN 'y' ELSE 'n' END AS z FROM T
