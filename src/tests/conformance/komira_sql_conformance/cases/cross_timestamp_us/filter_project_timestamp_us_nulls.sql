-- order: rows
-- filter project over a TIMESTAMP column, nulls rows
SELECT v FROM t_nulls WHERE v > TIMESTAMP '2024-01-01 03:30:15.123456'
