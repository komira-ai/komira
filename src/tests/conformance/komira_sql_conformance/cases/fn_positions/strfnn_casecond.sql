-- order: rows
-- strpos(s, 'b') in a case condition
SELECT k, CASE WHEN strpos(s, 'b') > 1 THEN 'y' ELSE 'n' END AS z FROM T
