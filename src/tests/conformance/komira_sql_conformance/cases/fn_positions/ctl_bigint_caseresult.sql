-- order: rows
-- k in a case result
SELECT k, CASE WHEN k < 3 THEN k ELSE -1 END AS z FROM T
