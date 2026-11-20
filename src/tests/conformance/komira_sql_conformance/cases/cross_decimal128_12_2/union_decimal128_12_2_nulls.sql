-- order: rows
-- union over a DECIMAL(12,2) column, nulls rows
SELECT k, g, v FROM t_nulls UNION ALL SELECT k, g, v FROM t_nulls
