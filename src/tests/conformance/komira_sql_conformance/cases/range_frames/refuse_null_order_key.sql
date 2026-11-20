-- order: rows
-- a RANGE offset over an order key holding NULLs
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY onull RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM R
