-- order: rows
-- filter over a BIGINT column, nulls rows
SELECT k, g, v FROM t_nulls WHERE v > 30
