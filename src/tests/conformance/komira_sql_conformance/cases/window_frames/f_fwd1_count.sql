-- order: rows
-- the current row and the next one
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) AS y FROM F
