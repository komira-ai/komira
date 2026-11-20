-- order: rows
SELECT g AS gk, g2 AS gk2, count(*) AS c FROM T GROUP BY g, g2
