-- order: rows
SELECT g, count(DISTINCT n) AS c FROM T GROUP BY g
