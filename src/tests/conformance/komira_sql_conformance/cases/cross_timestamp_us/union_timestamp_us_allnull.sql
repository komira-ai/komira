-- order: rows
-- union over a TIMESTAMP column, allnull rows
SELECT k, g, v FROM t_allnull UNION ALL SELECT k, g, v FROM t_allnull
