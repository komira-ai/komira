-- order: rows
-- a forward value window of width 2
SELECT k, max(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN CURRENT ROW AND 2 FOLLOWING) AS y FROM R
