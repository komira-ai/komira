-- order: rows
-- RANGE frame over the integer key (width 1 each way)
SELECT k, count(v) OVER (PARTITION BY g ORDER BY oi RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS y FROM Q
