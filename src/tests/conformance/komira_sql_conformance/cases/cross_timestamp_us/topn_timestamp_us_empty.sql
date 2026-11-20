-- order: query
-- topn over a TIMESTAMP column, empty rows
SELECT k, g, v FROM t_empty ORDER BY v DESC LIMIT 3
