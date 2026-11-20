-- order: rows
SELECT g AS gk, count(*) AS c FROM T GROUP BY g HAVING count(*) > 1 AND sum(v) > 2
