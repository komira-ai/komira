-- order: rows
SELECT sum(CASE WHEN a > 3 THEN 1 ELSE 0 END) AS z FROM T
