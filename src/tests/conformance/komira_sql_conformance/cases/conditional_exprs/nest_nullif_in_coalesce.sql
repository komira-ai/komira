-- order: rows
SELECT k, COALESCE(NULLIF(a, b), -7) AS z FROM T
