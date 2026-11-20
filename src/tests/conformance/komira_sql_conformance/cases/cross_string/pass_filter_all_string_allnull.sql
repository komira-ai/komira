-- order: rows
-- pass filter all over a VARCHAR column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k > 2
