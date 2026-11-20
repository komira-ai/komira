-- order: rows
-- limit over a TIMESTAMP column, nulls rows
SELECT k, g, v FROM t_nulls LIMIT 3
