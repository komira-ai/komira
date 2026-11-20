-- order: rows
-- g inside a scalar subquery
SELECT k, (SELECT max(g) FROM T) AS z FROM T
