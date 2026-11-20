-- order: query
-- sort desc over a TIMESTAMP column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v DESC
