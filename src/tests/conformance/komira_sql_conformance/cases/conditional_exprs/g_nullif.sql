-- order: rows
SELECT NULLIF(a, b) AS g, count(*) AS n FROM T GROUP BY NULLIF(a, b)
