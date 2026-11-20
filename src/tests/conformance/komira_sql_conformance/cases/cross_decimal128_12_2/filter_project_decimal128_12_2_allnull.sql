-- order: rows
-- filter project over a DECIMAL(12,2) column, allnull rows
SELECT v FROM t_allnull WHERE v > CAST('30.75' AS DECIMAL(12,2))
