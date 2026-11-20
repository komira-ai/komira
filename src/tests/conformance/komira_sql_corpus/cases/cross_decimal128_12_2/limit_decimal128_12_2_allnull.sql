-- order: rows
-- limit over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull LIMIT 3
