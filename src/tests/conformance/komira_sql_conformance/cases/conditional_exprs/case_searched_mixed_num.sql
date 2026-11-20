-- order: rows
SELECT k, CASE WHEN a > 3 THEN a ELSE f END AS z FROM T
