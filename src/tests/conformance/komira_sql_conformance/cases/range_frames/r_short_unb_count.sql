-- order: rows
-- single-bound shorthand over an unbounded start
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o RANGE UNBOUNDED PRECEDING) AS y FROM R
