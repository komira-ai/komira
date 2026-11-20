-- order: rows
-- s inside a scalar subquery
SELECT k, (SELECT max(s) FROM T) AS z FROM T
