-- order: rows
SELECT g AS gk, count(n) AS c, sum(n) AS s FROM T GROUP BY g
