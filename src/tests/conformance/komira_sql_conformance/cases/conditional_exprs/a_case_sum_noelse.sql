-- order: rows
SELECT sum(CASE WHEN a > 3 THEN a END) AS z FROM T
