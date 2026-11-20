-- order: rows
-- RANGE frame over the integer key (width 1 behind)
SELECT k, count(v) OVER (PARTITION BY g ORDER BY oi RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM Q
