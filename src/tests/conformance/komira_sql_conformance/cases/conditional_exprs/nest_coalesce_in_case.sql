-- order: rows
SELECT k, CASE WHEN COALESCE(a, 0) > 2 THEN 'y' ELSE 'n' END AS z FROM T
