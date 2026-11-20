-- order: rows
-- RANGE frame over the integer key (peer group only)
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY oi RANGE BETWEEN CURRENT ROW AND CURRENT ROW) AS y FROM Q
