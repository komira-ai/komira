-- order: rows
-- the peer group and nothing else
SELECT k, min(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN CURRENT ROW AND CURRENT ROW) AS y FROM R
