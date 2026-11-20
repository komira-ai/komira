-- order: rows
-- sqrt(g) on a group key in having
SELECT g AS z FROM T GROUP BY g HAVING sqrt(g) > 2.0
