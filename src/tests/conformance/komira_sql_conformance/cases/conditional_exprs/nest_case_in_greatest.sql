-- order: rows
SELECT k, GREATEST(CASE WHEN a > 3 THEN a ELSE 0 END, b) AS z FROM T
