-- order: query
-- sort over a BOOLEAN column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v
