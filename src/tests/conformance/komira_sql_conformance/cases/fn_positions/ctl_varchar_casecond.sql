-- order: rows
-- s in a case condition
SELECT k, CASE WHEN s = 'abc' THEN 'y' ELSE 'n' END AS z FROM T
