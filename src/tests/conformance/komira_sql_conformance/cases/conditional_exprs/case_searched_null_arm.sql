-- order: rows
SELECT k, CASE WHEN a > 3 THEN NULL ELSE 'x' END AS z FROM T
