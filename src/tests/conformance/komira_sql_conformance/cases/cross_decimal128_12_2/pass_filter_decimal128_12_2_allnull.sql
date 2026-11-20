-- order: rows
-- pass filter over a DECIMAL(12,2) column, allnull rows
SELECT v FROM t_allnull WHERE k > 2
