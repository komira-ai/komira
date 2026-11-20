-- order: rows
-- filter over a BOOLEAN column, nulls rows
SELECT k, g, v FROM t_nulls WHERE v = TRUE
