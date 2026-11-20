-- order: query
-- sort desc over a DECIMAL(12,2) column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v DESC
