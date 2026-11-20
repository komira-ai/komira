-- order: rows
SELECT b1 AS g, count(*) AS c FROM T GROUP BY b1 HAVING count(*) > 1
