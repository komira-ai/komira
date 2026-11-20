-- order: rows
SELECT CASE WHEN a > 3 THEN 'big' END AS g, count(*) AS n FROM T GROUP BY CASE WHEN a > 3 THEN 'big' END
