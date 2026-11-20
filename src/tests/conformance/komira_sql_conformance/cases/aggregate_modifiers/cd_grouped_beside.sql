-- order: rows
SELECT g AS gk, count(DISTINCT v) AS cd, sum(v) AS s FROM T GROUP BY g
