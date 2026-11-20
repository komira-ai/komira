-- order: rows
SELECT k, CASE WHEN a > 3 THEN 'na' ELSE CASE WHEN b > 2 THEN 'hi' ELSE 'lo' END END AS z FROM T
