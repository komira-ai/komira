-- order: rows
-- an offset larger than the gap between keys, so the frame reaches across the gap
SELECT k, count(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 9 PRECEDING AND CURRENT ROW) AS y FROM R
