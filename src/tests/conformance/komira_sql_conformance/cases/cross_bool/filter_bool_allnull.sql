-- order: rows
-- filter over a BOOLEAN column, allnull rows
SELECT k, g, v FROM t_allnull WHERE v = TRUE
