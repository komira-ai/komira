-- order: rows
-- the single-bound shorthand, which must read as BETWEEN 2 PRECEDING AND CURRENT ROW
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o ROWS 2 PRECEDING) AS y FROM F
