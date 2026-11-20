-- order: query
-- sort desc over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty ORDER BY v DESC
