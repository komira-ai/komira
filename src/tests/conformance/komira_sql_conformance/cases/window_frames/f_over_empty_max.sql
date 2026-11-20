-- order: rows
-- OVER () with no partition and no order: one partition holding every row
SELECT k, max(v) OVER () AS y FROM F
