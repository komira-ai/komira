-- order: rows
-- a two-row trailing window
SELECT k, min(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM F
