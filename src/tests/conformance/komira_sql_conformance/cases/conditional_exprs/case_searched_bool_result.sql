-- order: rows
SELECT k, CASE WHEN a > 3 THEN true ELSE false END AS z FROM T
