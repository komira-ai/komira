-- order: rows
-- a frame entirely ahead of the current row, empty on the last row
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) AS y FROM F
