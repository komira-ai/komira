-- order: rows
-- RANGE frame over the integer key (width 1 ahead)
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY oi RANGE BETWEEN CURRENT ROW AND 1 FOLLOWING) AS y FROM Q
