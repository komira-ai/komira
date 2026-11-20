-- order: rows
-- filter over a BIGINT column, allnull rows
SELECT k, g, v FROM t_allnull WHERE v > 30
