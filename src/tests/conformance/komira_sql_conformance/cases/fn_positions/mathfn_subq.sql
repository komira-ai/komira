-- order: rows
-- sqrt(g) inside a scalar subquery
SELECT k, (SELECT max(sqrt(g)) FROM T) AS z FROM T
