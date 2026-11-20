-- order: rows
SELECT CASE WHEN a > 3 THEN 'big' ELSE 'small' END AS g, sum(COALESCE(b, 0)) AS n FROM T GROUP BY CASE WHEN a > 3 THEN 'big' ELSE 'small' END
