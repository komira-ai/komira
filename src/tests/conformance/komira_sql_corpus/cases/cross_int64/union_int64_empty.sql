-- order: rows
-- union over a BIGINT column, empty rows
SELECT k, g, v FROM t_empty UNION ALL SELECT k, g, v FROM t_empty
