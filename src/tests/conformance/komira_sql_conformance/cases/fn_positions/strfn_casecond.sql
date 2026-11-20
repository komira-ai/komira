-- order: rows
-- upper(s) in a case condition
SELECT k, CASE WHEN upper(s) = 'ABC' THEN 'y' ELSE 'n' END AS z FROM T
