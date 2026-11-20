-- order: rows
-- RANGE frame over the DOUBLE key (width 1 ahead)
SELECT k, count(v) OVER (PARTITION BY g ORDER BY af RANGE BETWEEN CURRENT ROW AND 1 FOLLOWING) AS y FROM Q
