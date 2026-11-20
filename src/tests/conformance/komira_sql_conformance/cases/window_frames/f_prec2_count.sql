-- order: rows
-- a three-row trailing window
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS y FROM F
