-- order: rows
SELECT k, CASE WHEN GREATEST(a, b) > 4 THEN 'g' ELSE 'l' END AS z FROM T
