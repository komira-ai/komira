-- order: rows
SELECT k, a FROM T WHERE COALESCE(a, b) IS NULL
