-- order: rows
-- union over a BIGINT column, nulls rows
SELECT k, g, v FROM t_nulls UNION ALL SELECT k, g, v FROM t_nulls
