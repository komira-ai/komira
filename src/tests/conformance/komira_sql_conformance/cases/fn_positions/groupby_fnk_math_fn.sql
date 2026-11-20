-- order: rows
-- sqrt(g) as the group key
SELECT sqrt(g) AS z, count(*) AS c FROM T GROUP BY sqrt(g)
