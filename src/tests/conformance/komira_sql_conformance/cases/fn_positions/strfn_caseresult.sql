-- order: rows
-- upper(s) in a case result
SELECT k, CASE WHEN k < 3 THEN upper(s) ELSE 'X' END AS z FROM T
