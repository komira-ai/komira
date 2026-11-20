-- order: rows
-- pow(n, 2) inside a scalar subquery
SELECT k, (SELECT max(pow(n, 2)) FROM T) AS z FROM T
