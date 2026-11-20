-- order: rows
SELECT k, a FROM T WHERE LEAST(a, b) <= 0
