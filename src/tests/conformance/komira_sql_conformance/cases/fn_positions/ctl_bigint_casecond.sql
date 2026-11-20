-- order: rows
-- k in a case condition
SELECT k, CASE WHEN k > 4 THEN 'y' ELSE 'n' END AS z FROM T
