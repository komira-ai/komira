-- order: rows
-- pass filter all over a BIGINT column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k > 2
