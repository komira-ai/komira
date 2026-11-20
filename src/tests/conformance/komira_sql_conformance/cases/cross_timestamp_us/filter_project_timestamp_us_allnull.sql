-- order: rows
-- filter project over a TIMESTAMP column, allnull rows
SELECT v FROM t_allnull WHERE v > TIMESTAMP '2024-01-01 03:30:15.123456'
