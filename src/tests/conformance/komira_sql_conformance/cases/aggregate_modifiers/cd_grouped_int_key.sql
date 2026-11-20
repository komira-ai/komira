-- order: rows
SELECT g2 AS gk2, count(DISTINCT v) AS cd FROM T GROUP BY g2
