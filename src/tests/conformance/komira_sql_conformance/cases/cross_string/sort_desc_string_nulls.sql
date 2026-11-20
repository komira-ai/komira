-- order: query
-- sort desc over a VARCHAR column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v DESC
