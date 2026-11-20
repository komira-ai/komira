-- order: rows
-- ROWS over the whole partition; equals the RANGE whole-partition answer
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS y FROM R
