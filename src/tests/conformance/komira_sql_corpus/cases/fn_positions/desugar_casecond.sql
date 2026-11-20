-- order: rows
-- isnan(f) in a case condition
SELECT k, CASE WHEN isnan(f) THEN 'y' ELSE 'n' END AS z FROM T
