-- order: rows
-- multiply(k, 3) inside a scalar subquery
SELECT k, (SELECT max(multiply(k, 3)) FROM T) AS z FROM T
