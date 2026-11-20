-- order: rows
-- month(t) in a case result
SELECT k, CASE WHEN k < 3 THEN month(t) ELSE -1 END AS z FROM T
