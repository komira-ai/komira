-- order: rows
-- OVER () with no partition and no order: one partition holding every row
SELECT k, sum(v) OVER () AS y FROM F
