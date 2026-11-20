-- order: query
-- limit over a TIMESTAMP column, nulls rows
SELECT k, g, v FROM t_nulls ORDER BY k ASC NULLS LAST LIMIT 3
