-- order: rows
SELECT g AS gk, sum(v) AS total FROM T GROUP BY g HAVING total > 2
