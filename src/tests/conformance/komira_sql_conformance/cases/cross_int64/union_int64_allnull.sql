-- order: rows
-- union over a BIGINT column, allnull rows
SELECT k, g, v FROM t_allnull UNION ALL SELECT k, g, v FROM t_allnull
