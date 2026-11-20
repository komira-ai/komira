-- order: rows
-- starts_with(s, 'a') inside a scalar subquery
SELECT k, (SELECT max(starts_with(s, 'a')) FROM T) AS z FROM T
