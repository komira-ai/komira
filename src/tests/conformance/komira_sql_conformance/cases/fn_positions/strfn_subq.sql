-- order: rows
-- upper(s) inside a scalar subquery
SELECT k, (SELECT max(upper(s)) FROM T) AS z FROM T
