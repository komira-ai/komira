-- order: rows
-- limit over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty LIMIT 3
