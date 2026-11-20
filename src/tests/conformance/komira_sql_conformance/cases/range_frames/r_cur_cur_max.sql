-- order: rows
-- the peer group and nothing else
SELECT k, max(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN CURRENT ROW AND CURRENT ROW) AS y FROM R
