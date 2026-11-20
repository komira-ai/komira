-- order: rows
SELECT k, COALESCE(a, -1) AS z FROM T ORDER BY k
