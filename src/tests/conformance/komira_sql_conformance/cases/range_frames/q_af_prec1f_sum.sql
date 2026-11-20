-- order: rows
-- RANGE frame over the DOUBLE key (width 1 behind)
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY af RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM Q
