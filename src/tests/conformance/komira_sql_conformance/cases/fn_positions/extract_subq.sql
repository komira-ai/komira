-- order: rows
-- month(t) inside a scalar subquery
SELECT k, (SELECT max(month(t)) FROM T) AS z FROM T
