-- order: rows
-- RANGE frame over the DOUBLE key (width 1 each way)
SELECT k, avg(v) OVER (PARTITION BY g ORDER BY af RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS y FROM Q
