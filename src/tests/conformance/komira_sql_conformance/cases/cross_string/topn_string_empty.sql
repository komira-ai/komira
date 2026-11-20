-- order: query
-- topn over a VARCHAR column, empty rows
SELECT k, g, v FROM t_empty ORDER BY v DESC LIMIT 3
