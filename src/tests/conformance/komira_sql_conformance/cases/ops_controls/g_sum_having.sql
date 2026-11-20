-- order: rows
SELECT g, sum(v) AS sv FROM T GROUP BY g HAVING sum(v) > 50
