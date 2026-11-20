-- order: rows
SELECT LEAST(a, b) AS g, count(*) AS n FROM T GROUP BY LEAST(a, b)
