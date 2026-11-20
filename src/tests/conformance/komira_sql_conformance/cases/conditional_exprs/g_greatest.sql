-- order: rows
SELECT GREATEST(a, b) AS g, count(*) AS n FROM T GROUP BY GREATEST(a, b)
