-- order: rows
SELECT CASE WHEN a > 3 THEN 'big' ELSE 'small' END AS g, count(*) AS n FROM T GROUP BY CASE WHEN a > 3 THEN 'big' ELSE 'small' END
