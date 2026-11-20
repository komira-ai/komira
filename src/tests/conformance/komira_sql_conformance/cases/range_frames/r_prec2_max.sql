-- order: rows
-- a trailing value window of width 2 on the key
SELECT k, max(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 2 PRECEDING AND CURRENT ROW) AS y FROM R
