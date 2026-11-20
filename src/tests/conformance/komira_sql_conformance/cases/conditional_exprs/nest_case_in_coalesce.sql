-- order: rows
SELECT k, COALESCE(CASE WHEN a > 3 THEN a END, -1) AS z FROM T
