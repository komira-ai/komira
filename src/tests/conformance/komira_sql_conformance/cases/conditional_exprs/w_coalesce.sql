-- order: rows
SELECT k, a FROM T WHERE COALESCE(a, 0) > 2
