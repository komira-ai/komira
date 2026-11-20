-- order: rows
-- filter over a BOOLEAN column, empty rows
SELECT k, g, v FROM t_empty WHERE v = TRUE
