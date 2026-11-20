-- order: rows
-- strpos(s, 'b') in a case result
SELECT k, CASE WHEN k < 3 THEN strpos(s, 'b') ELSE -1 END AS z FROM T
