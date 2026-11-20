-- order: rows
-- pow(n, 2) in a case result
SELECT k, CASE WHEN k < 3 THEN pow(n, 2) ELSE -1.0 END AS z FROM T
