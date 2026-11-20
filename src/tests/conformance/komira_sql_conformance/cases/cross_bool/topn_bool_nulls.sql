-- order: query
-- topn over a BOOLEAN column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY v DESC LIMIT 3
