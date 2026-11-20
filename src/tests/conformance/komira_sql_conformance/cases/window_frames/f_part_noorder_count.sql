-- order: rows
-- PARTITION BY without ORDER BY: the whole partition on every row
SELECT k, count(v) OVER (PARTITION BY g) AS y FROM F
