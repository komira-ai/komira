-- order: rows
SELECT k, CASE WHEN a > 3 THEN 'big' WHEN a > 0 THEN 'small' ELSE 'other' END AS z FROM T
