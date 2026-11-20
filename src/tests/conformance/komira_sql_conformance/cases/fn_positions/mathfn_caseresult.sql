-- order: rows
-- sqrt(g) in a case result
SELECT k, CASE WHEN k < 3 THEN sqrt(g) ELSE -1.0 END AS z FROM T
