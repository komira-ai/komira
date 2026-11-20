-- order: rows
SELECT g2 AS gk2, count(*) AS c, min(v) AS mn, max(v) AS mx FROM T GROUP BY g2
