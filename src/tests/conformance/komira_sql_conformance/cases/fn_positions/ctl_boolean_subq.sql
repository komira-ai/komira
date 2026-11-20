-- order: rows
-- bt inside a scalar subquery
SELECT k, (SELECT max(bt) FROM T) AS z FROM T
