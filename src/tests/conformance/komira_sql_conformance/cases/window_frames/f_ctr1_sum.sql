-- order: rows
-- a centred three-row window
SELECT k, sum(v) OVER (PARTITION BY g ORDER BY o ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS y FROM F
