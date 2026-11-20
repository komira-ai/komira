-- order: rows
-- from the peer group start to the partition end
SELECT k, max(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS y FROM R
