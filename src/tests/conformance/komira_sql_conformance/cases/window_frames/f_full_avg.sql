-- order: rows
-- the whole partition on every row
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS y FROM F
