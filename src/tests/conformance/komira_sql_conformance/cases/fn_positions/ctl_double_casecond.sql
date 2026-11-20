-- order: rows
-- g in a case condition
SELECT k, CASE WHEN g > 4.0 THEN 'y' ELSE 'n' END AS z FROM T
