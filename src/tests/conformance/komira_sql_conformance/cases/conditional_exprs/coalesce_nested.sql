-- order: rows
SELECT k, COALESCE(COALESCE(a, b), -1) AS z FROM T
