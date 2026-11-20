-- order: rows
-- the ranking function with no frame
SELECT k, dense_rank() OVER (PARTITION BY g ORDER BY o) AS y FROM R
