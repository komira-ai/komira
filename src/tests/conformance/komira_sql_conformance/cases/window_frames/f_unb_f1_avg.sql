-- order: rows
-- from the partition start to one row ahead
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING) AS y FROM F
