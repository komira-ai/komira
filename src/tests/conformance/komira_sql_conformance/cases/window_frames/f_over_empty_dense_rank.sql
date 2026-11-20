-- order: rows
-- OVER () with no partition and no order: one partition holding every row
SELECT k, dense_rank() OVER () AS y FROM F
