-- order: rows
-- isnan(f) inside a scalar subquery
SELECT k, (SELECT max(isnan(f)) FROM T) AS z FROM T
