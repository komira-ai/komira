-- order: rows
-- sign(i) inside a scalar subquery
SELECT k, (SELECT max(sign(i)) FROM T) AS z FROM T
