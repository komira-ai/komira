-- order: rows
-- filter over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull WHERE v > CAST('30.75' AS DECIMAL(12,2))
