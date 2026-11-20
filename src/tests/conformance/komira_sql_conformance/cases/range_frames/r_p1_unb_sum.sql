-- order: rows
-- offset start with an unbounded end
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 1 PRECEDING AND UNBOUNDED FOLLOWING) AS y FROM R
