-- order: rows
SELECT count(CASE WHEN a > 3 THEN a END) AS z FROM T
