-- order: rows
-- offset 0 preceding: exactly the peer group
SELECT k, max(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 0 PRECEDING AND CURRENT ROW) AS y FROM R
