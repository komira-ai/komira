-- order: rows
-- OVER () with no partition and no order: one partition holding every row
SELECT k, count(v) OVER () AS y FROM F
