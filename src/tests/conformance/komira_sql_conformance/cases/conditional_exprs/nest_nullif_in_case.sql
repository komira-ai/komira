-- order: rows
SELECT k, CASE WHEN NULLIF(a, b) IS NULL THEN 'eq_or_null' ELSE 'diff' END AS z FROM T
