-- order: rows
-- two order keys in ROWS units
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o, k ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM R
