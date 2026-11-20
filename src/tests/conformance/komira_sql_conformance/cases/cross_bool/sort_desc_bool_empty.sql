-- order: query
-- sort desc over a BOOLEAN column, empty rows
SELECT k, g, v FROM t_empty ORDER BY v DESC
