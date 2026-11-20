-- order: rows
-- the running frame from the partition start to the current row
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS y FROM F
