-- order: rows
-- pass filter all over a DECIMAL(12,2) column, allnull rows
SELECT k, g, v FROM t_allnull WHERE k > 2
