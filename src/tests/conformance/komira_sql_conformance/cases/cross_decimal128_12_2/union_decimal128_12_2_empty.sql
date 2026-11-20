-- order: rows
-- union over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty UNION ALL SELECT k, g, v FROM t_empty
