-- order: rows
-- the same frame with an ORDER BY added
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM R
