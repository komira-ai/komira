-- order: rows
-- limit over a BIGINT column, nulls rows
SELECT k, g, v FROM t_nulls LIMIT 3
