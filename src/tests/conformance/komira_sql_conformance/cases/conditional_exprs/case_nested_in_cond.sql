-- order: rows
SELECT k, CASE WHEN (CASE WHEN a > 3 THEN b ELSE a END) > 2 THEN 'y' ELSE 'n' END AS z FROM T
