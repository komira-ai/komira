-- order: rows
-- a centred value window of width 1 each way
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS y FROM R
