-- order: rows
-- the default ordered frame: start to the end of the peer group
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY o RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS y FROM R
