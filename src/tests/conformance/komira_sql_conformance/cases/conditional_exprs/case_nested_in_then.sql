-- order: rows
SELECT k, CASE WHEN a > 3 THEN CASE WHEN b > 2 THEN 'hi' ELSE 'lo' END ELSE 'na' END AS z FROM T
