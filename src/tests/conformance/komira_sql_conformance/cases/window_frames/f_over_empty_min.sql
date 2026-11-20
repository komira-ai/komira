-- order: rows
-- OVER () with no partition and no order: one partition holding every row
SELECT k, min(v) OVER () AS y FROM F
