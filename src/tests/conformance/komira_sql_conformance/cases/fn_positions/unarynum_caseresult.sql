-- order: rows
-- sign(i) in a case result
SELECT k, CASE WHEN k < 3 THEN sign(i) ELSE -9 END AS z FROM T
