-- order: query
-- sort over a VARCHAR column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v
