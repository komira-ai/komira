-- order: rows
-- single-bound shorthand, which must read as BETWEEN 2 PRECEDING AND CURRENT ROW
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o RANGE 2 PRECEDING) AS y FROM R
