-- order: rows
-- month(t) in a case condition
SELECT k, CASE WHEN month(t) > 5 THEN 'y' ELSE 'n' END AS z FROM T
