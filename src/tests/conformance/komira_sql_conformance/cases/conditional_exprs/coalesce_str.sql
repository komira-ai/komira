-- order: rows
SELECT k, COALESCE(s, u, 'D') AS z FROM T
