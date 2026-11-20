-- order: rows
SELECT k, CASE WHEN a > 3 THEN 'big' ELSE 'small' END AS z FROM T ORDER BY k
