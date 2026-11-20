-- order: query
-- topn over a BOOLEAN column, single rows
SELECT k, g, v FROM t_single ORDER BY v DESC LIMIT 3
