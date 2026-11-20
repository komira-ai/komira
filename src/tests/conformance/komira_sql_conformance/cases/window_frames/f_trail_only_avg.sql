-- order: rows
-- a frame behind the current row that excludes it, empty on the first row
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING) AS y FROM F
