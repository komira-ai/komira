-- order: rows
-- union over a TIMESTAMP column, empty rows
SELECT k, g, v FROM t_empty UNION ALL SELECT k, g, v FROM t_empty
