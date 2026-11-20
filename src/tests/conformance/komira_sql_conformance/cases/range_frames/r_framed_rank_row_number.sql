-- order: rows
-- a RANGE frame written on a ranking function is ignored
SELECT y FROM (SELECT k, row_number() OVER (PARTITION BY g ORDER BY o RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) AS y FROM R)
