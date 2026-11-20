-- order: rows
SELECT k, CASE WHEN a > 3 THEN 'gt' WHEN a <= 3 THEN 'le' ELSE 'neither' END AS z FROM T
