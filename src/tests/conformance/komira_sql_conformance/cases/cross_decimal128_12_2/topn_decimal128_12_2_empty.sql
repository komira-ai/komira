-- order: query
-- topn over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty ORDER BY v DESC LIMIT 3
