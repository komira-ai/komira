-- order: rows
-- join anti over a BIGINT column, nulls rows
SELECT k, g, v FROM t_nulls WHERE k NOT IN (SELECT g FROM t_nulls)
