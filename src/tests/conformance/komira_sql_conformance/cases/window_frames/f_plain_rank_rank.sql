-- order: rows
-- the ranking function with no frame
SELECT k, rank() OVER (PARTITION BY g ORDER BY o) AS y FROM F
