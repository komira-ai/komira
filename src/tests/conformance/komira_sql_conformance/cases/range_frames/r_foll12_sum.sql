-- order: rows
-- a value window ahead of the current row that excludes it
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 1 FOLLOWING AND 2 FOLLOWING) AS y FROM R
