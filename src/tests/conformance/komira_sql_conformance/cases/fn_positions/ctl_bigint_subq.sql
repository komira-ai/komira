-- order: rows
-- k inside a scalar subquery
SELECT k, (SELECT max(k) FROM T) AS z FROM T
