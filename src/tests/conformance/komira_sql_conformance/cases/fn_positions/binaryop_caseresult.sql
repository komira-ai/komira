-- order: rows
-- multiply(k, 3) in a case result
SELECT k, CASE WHEN k < 3 THEN multiply(k, 3) ELSE -1 END AS z FROM T
