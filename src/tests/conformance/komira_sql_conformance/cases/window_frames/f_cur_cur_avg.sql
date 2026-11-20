-- order: rows
-- a one-row frame: each aggregate reproduces the row's own value
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS y FROM F
