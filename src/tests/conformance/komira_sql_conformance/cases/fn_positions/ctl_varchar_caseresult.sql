-- order: rows
-- s in a case result
SELECT k, CASE WHEN k < 3 THEN s ELSE 'X' END AS z FROM T
