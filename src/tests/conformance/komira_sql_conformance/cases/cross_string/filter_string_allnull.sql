-- order: rows
-- filter over a VARCHAR column, allnull rows
SELECT k, g, v FROM t_allnull WHERE v > 'c'
