-- order: rows
-- RANGE frame over the DOUBLE key (peer group only)
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY af RANGE BETWEEN CURRENT ROW AND CURRENT ROW) AS y FROM Q
