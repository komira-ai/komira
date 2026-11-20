-- order: rows
-- from the current row to the partition end
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS y FROM F
