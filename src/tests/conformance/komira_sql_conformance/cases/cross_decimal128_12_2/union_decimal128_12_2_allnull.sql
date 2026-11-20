-- order: rows
-- union over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull UNION ALL SELECT k, g, v FROM t_allnull
