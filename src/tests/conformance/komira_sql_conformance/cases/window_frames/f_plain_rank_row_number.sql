-- order: rows
-- the ranking function with no frame
SELECT k, row_number() OVER (PARTITION BY g ORDER BY o) AS y FROM F
