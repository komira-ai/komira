-- order: rows
SELECT k, a FROM T WHERE NULLIF(a, b) IS NOT NULL
