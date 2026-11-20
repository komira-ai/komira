-- order: rows
-- a frame written on a ranking function is ignored
SELECT k, rank() OVER (PARTITION BY g ORDER BY o ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM F
