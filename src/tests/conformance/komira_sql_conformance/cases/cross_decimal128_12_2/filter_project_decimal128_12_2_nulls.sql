-- order: rows
-- filter project over a DECIMAL(12,2) column, nulls rows
SELECT v FROM t_nulls WHERE v > CAST('30.75' AS DECIMAL(12,2))
