-- order: rows
SELECT g AS gk, count(DISTINCT v) AS cd FROM T GROUP BY g HAVING count(DISTINCT v) > 1
