-- order: rows
SELECT COALESCE(a, -1) AS g, count(*) AS n FROM T GROUP BY COALESCE(a, -1)
