-- order: rows
-- filter project over a DECIMAL(12,2) column, single rows
SELECT v FROM t_single WHERE v > CAST('30.75' AS DECIMAL(12,2))
