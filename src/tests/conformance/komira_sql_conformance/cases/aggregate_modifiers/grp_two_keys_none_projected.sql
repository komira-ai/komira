-- order: rows
SELECT count(*) AS c, sum(v) AS s FROM T GROUP BY g, g2
