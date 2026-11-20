-- order: query
-- sort desc over a BIGINT column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v DESC
