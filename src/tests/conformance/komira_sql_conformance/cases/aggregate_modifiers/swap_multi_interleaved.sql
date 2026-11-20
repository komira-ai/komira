-- order: rows
SELECT count(*) AS c, g2 AS gk2, sum(v) AS s, g AS gk FROM T GROUP BY g, g2
