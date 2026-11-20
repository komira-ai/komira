-- order: rows
SELECT k, a FROM T ORDER BY COALESCE(a, -1)
