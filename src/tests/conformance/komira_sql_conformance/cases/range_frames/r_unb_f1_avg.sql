-- order: rows
-- unbounded start with an offset end
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING) AS y FROM R
