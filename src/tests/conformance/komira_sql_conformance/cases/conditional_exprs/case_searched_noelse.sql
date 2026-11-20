-- order: rows
SELECT k, CASE WHEN a > 3 THEN 'big' END AS z FROM T
