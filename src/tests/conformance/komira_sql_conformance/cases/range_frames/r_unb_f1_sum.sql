-- order: rows
-- unbounded start with an offset end
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING) AS y FROM R
