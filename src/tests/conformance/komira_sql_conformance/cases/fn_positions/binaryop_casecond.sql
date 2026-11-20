-- order: rows
-- multiply(k, 3) in a case condition
SELECT k, CASE WHEN multiply(k, 3) > 9 THEN 'y' ELSE 'n' END AS z FROM T
