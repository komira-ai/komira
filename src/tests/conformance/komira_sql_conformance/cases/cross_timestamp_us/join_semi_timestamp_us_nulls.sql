-- order: rows
-- join semi over a TIMESTAMP column, nulls rows
SELECT k, g, v FROM t_nulls WHERE k IN (SELECT g FROM t_nulls)
