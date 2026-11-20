-- order: rows
-- scalar subquery in a projection, over a second table
SELECT k, (SELECT max(j) FROM U) AS m FROM T
