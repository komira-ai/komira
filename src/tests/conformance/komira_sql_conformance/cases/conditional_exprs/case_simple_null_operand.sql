-- order: rows
SELECT k, CASE a WHEN NULL THEN 'n' ELSE 'e' END AS z FROM T
