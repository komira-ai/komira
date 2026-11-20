-- order: rows
-- a derived table carrying its own group by
SELECT g, c FROM (SELECT g, count(*) AS c FROM T GROUP BY g) t
