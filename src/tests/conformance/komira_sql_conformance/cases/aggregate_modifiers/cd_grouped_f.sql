-- order: rows
SELECT g AS gk, count(DISTINCT f) AS cd FROM T GROUP BY g
