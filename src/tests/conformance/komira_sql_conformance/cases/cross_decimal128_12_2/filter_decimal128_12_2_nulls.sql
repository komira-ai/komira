-- order: rows
-- filter over a DECIMAL(12,2) column, nulls rows
SELECT k, g, v FROM t_nulls WHERE v > CAST('30.75' AS DECIMAL(12,2))
